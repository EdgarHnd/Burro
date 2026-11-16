// Replying to a Claude chat whose background session is still open (how `claude --bg`, and so
// Burro, leaves every session after its turn). `claude --bg --resume <id>` on a running session
// starts a copy, so a reply first stops that session: only a background-kind session, only when
// its process is idle (not working, not asking anything), only the session being replied to, only
// when nothing attached to it in a terminal, and only when the Send asks for it. `claude stop
// <short id>` keeps the conversation; Burro then reads `claude agents` until the session is no
// longer running (a few seconds at most) and only then resumes it with the message. If the stop
// fails, or it can't be confirmed, nothing is sent and the reason is shown.
//
// `claude agents --json --all` (Claude Code 2.1.x) lists running sessions and, with --all,
// finished background ones: a background row has `pid` and `status` (idle | waiting | busy)
// while its process runs and `state` (working | blocked | done | failed | stopped). A finished
// row (no pid, no status, done/failed/stopped) is not running and doesn't block a reply.
// The same rules run on other machines in `remote_reply.py`'s `continue` operation.
// A refusal because the chat is working or waiting for an answer is typed (`ReplyRefusal`), so the
// reply queue can keep a message and try again when the chat is next idle. A resume that ran
// but didn't finish in time is `ReplyNotConfirmed`: Claude may have taken the message.
import Foundation

/// A reply refused because the chat is in the middle of something: Claude is working on it, or a
/// background session waits for an answer or an approval. Other refusals stay `LaunchError`s.
public struct ReplyRefusal: Error, LocalizedError, Equatable, Sendable {
    public enum Reason: String, Sendable { case working, waiting }
    public var reason: Reason
    public var message: String
    public init(_ reason: Reason, message: String) { self.reason = reason; self.message = message }
    public var errorDescription: String? { message }

    /// The typed refusal for a running `claude agents` row, when it is working or waiting.
    static func of(_ live: ChatReply.ClaudeLive?, message: String) -> ReplyRefusal? {
        guard let live else { return nil }
        if live.busy { return ReplyRefusal(.working, message: message) }
        if live.background && live.waiting { return ReplyRefusal(.waiting, message: message) }
        return nil
    }

    /// The same from `remote_reply.py`'s `live` field on a refusal.
    static func remote(_ live: Any?, message: String) -> ReplyRefusal? {
        guard let live = live as? [String: Any] else { return nil }
        if live["busy"] as? Bool == true { return ReplyRefusal(.working, message: message) }
        if live["kind"] as? String == "background" && live["waiting"] as? Bool == true { return ReplyRefusal(.waiting, message: message) }
        return nil
    }
}

/// How Burro runs `claude` and reads the process list; tests swap in fakes.
struct ClaudeCommands: Sendable {
    /// Runs `claude <arguments>` in a folder; output and exit code.
    var run: @Sendable (_ arguments: [String], _ folder: String, _ timeout: TimeInterval) throws -> (code: Int32, text: String)
    /// Every process's command line (`ps -A -ww -o args=`), or nil when it can't be read.
    var processes: @Sendable () -> String?
    var sleep: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var now: @Sendable () -> Date = { Date() }

    static func local(_ claude: String) -> ClaudeCommands {
        ClaudeCommands(run: { arguments, folder, timeout in
            let result = try LaunchShell.run(claude, arguments, folder: folder, timeout: timeout)
            return (result.code, result.text)
        }, processes: {
            guard let result = try? LaunchShell.run("/bin/ps", ["-A", "-ww", "-o", "args="], timeout: 10), result.code == 0 else { return nil }
            return result.text
        })
    }
}

/// One Claude reply per chat at a time from this app.
final class ClaudeReplyGate: @unchecked Sendable {
    static let shared = ClaudeReplyGate()
    private let lock = NSLock()
    private var active: Set<String> = []
    func enter(_ id: String) -> Bool { lock.withLock { active.insert(id.lowercased()).inserted } }
    func leave(_ id: String) { _ = lock.withLock { active.remove(id.lowercased()) } }
}

extension ChatReply {
    /// What `claude agents` says about one session: unreadable, or its running row (nil: not running).
    enum ClaudeLookup: Equatable { case unreadable, found(ClaudeLive?) }

    /// What a reply does with this session.
    enum ClaudeRoute: Equatable {
        /// Nothing has it open: `claude --bg --resume` continues it under the same id.
        case resume
        /// An idle background session: stop it, confirm, then resume.
        case stopThenResume(handle: String)
        case refuse(String)
    }

    static let handlePattern = #"^[0-9a-f]{6,36}$"#
    /// How long Burro waits for a stopped session to leave `claude agents`, and how often it looks.
    static let stopWait: TimeInterval = 8, stopPoll: TimeInterval = 0.4

    static func claudeLookup(_ id: String, commands: ClaudeCommands) -> ClaudeLookup {
        guard let result = try? commands.run(["agents", "--json", "--all"], NSHomeDirectory(), 20), result.code == 0 else { return .unreadable }
        return claudeLookup(id, rows: Data(result.text.utf8))
    }

    /// This session's running row. When several rows match (a finished background row and a
    /// terminal that reopened it, say), the most restrictive wins: interactive, busy, waiting, idle.
    static func claudeLookup(_ id: String, rows data: Data) -> ClaudeLookup {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return .unreadable }
        let live = rows.compactMap { $0 as? [String: Any] }
            .filter { ($0["sessionId"] as? String)?.lowercased() == id.lowercased() }
            .compactMap(runningRow)
        func rank(_ row: ClaudeLive) -> Int { !row.background ? 0 : row.busy ? 1 : row.waiting ? 2 : row.idle ? 4 : 3 }
        return .found(live.min { rank($0) < rank($1) })
    }

    static func runningRow(_ row: [String: Any]) -> ClaudeLive? {
        let background = row["kind"] as? String == "background"
        let status = row["status"] as? String, state = row["state"] as? String
        let running = !background || row["pid"] != nil || status != nil || state == "working" || state == "blocked"
        guard running else { return nil }
        let handle = (row["id"] as? String).flatMap { $0.range(of: handlePattern, options: .regularExpression) != nil ? $0 : nil }
        let waiting = status == "waiting" || state == "blocked"
        let busy = status == "busy" || (background && status == nil && !waiting)
        return ClaudeLive(handle: handle, background: background, busy: busy, idle: status == "idle" && !waiting, waiting: waiting)
    }

    /// Whether a `claude attach` for this session runs: one naming its short id or session id, or
    /// a Claude attach by name or without a target (which could be this one). An unreadable
    /// process list counts as attached.
    static func attachedInTerminal(_ processes: String?, handle: String, sessionID: String) -> Bool {
        guard let processes else { return true }
        let mine = Set([handle.lowercased(), sessionID.lowercased()].filter { !$0.isEmpty })
        let other = #"^([0-9a-f]{6,36}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$"#
        for line in processes.split(whereSeparator: \.isNewline) {
            let tokens = line.split(whereSeparator: \.isWhitespace).map { String($0) }
            for (index, token) in tokens.enumerated() where token == "attach" && index > 0 {
                let target = index + 1 < tokens.count ? tokens[index + 1].lowercased() : nil
                if let target, mine.contains(target) { return true }
                let claude = tokens[..<index].contains { $0.lowercased().contains("claude") }
                if claude && (target.map { $0.range(of: other, options: .regularExpression) == nil } ?? true) { return true }
            }
        }
        return false
    }

    static func claudeRoute(_ live: ClaudeLive?, stopIdleBackground: Bool, attached: Bool) -> ClaudeRoute {
        let check = claudePlan(live, attached: attached)
        if check.continues, let handle = check.attach { return stopIdleBackground ? .stopThenResume(handle: handle) : .refuse(stillOpen) }
        if let problem = check.problem { return .refuse(problem) }
        return .resume
    }

    /// Reads `claude agents` until the session is no longer running. True only when confirmed;
    /// an unreadable listing never counts as stopped.
    static func waitUntilStopped(_ id: String, commands: ClaudeCommands, limit: TimeInterval = stopWait, poll: TimeInterval = stopPoll) -> Bool {
        let deadline = commands.now().addingTimeInterval(limit)
        while true {
            if claudeLookup(id, commands: commands) == .found(nil) { return true }
            if commands.now() >= deadline { return false }
            commands.sleep(poll)
        }
    }

    /// The local reply: decides the route from a fresh `claude agents` read, stops and confirms
    /// when that is the route, then runs the resume argv. Returns Claude's output.
    static func continueClaude(_ id: String, arguments: [String], folder: String, stopIdleBackground: Bool, commands: ClaudeCommands) throws -> String {
        // An unreadable listing resumes directly, as replies always have; only a confirmed idle
        // background session is ever stopped.
        let live: ClaudeLive? = if case .found(let row) = claudeLookup(id, commands: commands) { row } else { nil }
        let attached = live.map { $0.background && $0.idle && $0.handle != nil } == true
            && attachedInTerminal(commands.processes(), handle: live?.handle ?? "", sessionID: id)
        var stopped = false
        switch claudeRoute(live, stopIdleBackground: stopIdleBackground, attached: attached) {
        case .refuse(let reason):
            if let refusal = ReplyRefusal.of(live, message: reason) { throw refusal }
            throw LaunchError.failed(reason)
        case .resume: break
        case .stopThenResume(let handle):
            guard let stop = claudeStopArguments(handle: handle) else { throw LaunchError.failed("Claude gave this session an unexpected id.") }
            let result: (code: Int32, text: String)
            // The stop step sends nothing: a stop that didn't finish is a plain failure.
            do { result = try commands.run(stop, NSHomeDirectory(), 30) }
            catch is ProcessTimedOut { throw LaunchError.failed("Claude didn't stop the background session in time, so nothing was sent.") }
            guard result.code == 0 else {
                throw LaunchError.failed("Claude didn't stop the background session, so nothing was sent" + (lastLine(result.text).map { ": \($0)" } ?? "."))
            }
            guard waitUntilStopped(id, commands: commands) else {
                throw LaunchError.failed("The background session was still running after Burro stopped it, so nothing was sent. Try again in a moment.")
            }
            stopped = true
        }
        // The resume ran but never finished: Claude may have taken the message.
        let result: (code: Int32, text: String)
        do { result = try commands.run(arguments, folder, 60) }
        catch is ProcessTimedOut { throw ReplyNotConfirmed("Claude didn't finish continuing the chat in time") }
        guard result.code == 0 else {
            let reason = lastLine(result.text).map { "Claude didn't continue: \($0)" } ?? "Claude didn't continue."
            throw LaunchError.failed(stopped ? "Burro stopped the idle background session, but \(reason) The conversation is kept." : reason)
        }
        return result.text
    }
}
