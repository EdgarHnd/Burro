// Home's three chat sections, decided in one place so nothing is listed twice:
// - Needs you: every chat waiting on you (newest first; sub-agents never, they are answered
//   through their parent chat), each with the Brief's open Needs-you
//   item for it when triage read it (its question and maybe a drafted reply), then Brief items
//   for chats that ended a turn on a question without waiting (newest reading first). A chat listed here is not also
//   listed under Ready to read.
// - Working: chats working now (subagents left out; they belong to their parent), each with the
//   Brief's Stuck item for it when StuckWatch flagged it.
// - Ready to read: unread results with a one-line outcome: the Brief's Finished headline for that
//   chat, else the already-scanned preview, else nothing. Never a new transcript read.
// Also the greeting's one summary sentence, a machine's one-line status, and when each working
// chat's current turn began as far as Burro saw it (`TurnClock`). Pure and in-memory.
import Foundation

public struct HomeBoard: Sendable, Equatable {
    public struct NeedsYou: Sendable, Equatable, Identifiable {
        /// The chat's id, or the Brief item's id when the chat isn't in the feed.
        public var id: String
        public var session: AgentSession?
        public var item: BriefItem?
        /// When it started waiting (the chat's last update) or when triage read it.
        public var since: Date
        /// The chat is waiting on an input request (as opposed to a question triage found).
        public var waiting: Bool { session?.state == .waiting }
        public var title: String { session?.title ?? item?.chatTitle ?? "A chat" }
    }
    public struct Working: Sendable, Equatable, Identifiable {
        public var session: AgentSession
        public var stuck: BriefItem?
        public var id: String { session.id }
    }
    public struct ToRead: Sendable, Equatable, Identifiable {
        public var session: AgentSession
        public var outcome: String?
        public var id: String { session.id }
    }

    public var needsYou: [NeedsYou] = []
    public var working: [Working] = []
    public var toRead: [ToRead] = []
    public var isEmpty: Bool { needsYou.isEmpty && working.isEmpty && toRead.isEmpty }

    public init(needsYou: [NeedsYou] = [], working: [Working] = [], toRead: [ToRead] = []) {
        self.needsYou = needsYou; self.working = working; self.toRead = toRead
    }

    /// `waiting`, `running` and `unread` as HomeSummary sorts them; `briefNeeds`, `briefFinished`
    /// and `briefStuck` the Brief's open items; `all` every chat Burro can show (to find the chat a
    /// Brief item names); `previews` one-line previews by chat id from a scan Burro already ran.
    public static func build(waiting: [AgentSession], running: [AgentSession], unread: [AgentSession],
                             briefNeeds: [BriefItem] = [], briefFinished: [BriefItem] = [], briefStuck: [BriefItem] = [],
                             all: [AgentSession] = [], previews: [String: String] = [:]) -> HomeBoard {
        func key(_ id: String?) -> String? { id?.lowercased() }
        func firstByChat(_ items: [BriefItem]) -> [String: BriefItem] {
            var result: [String: BriefItem] = [:]
            for item in items { if let id = key(item.chatID), result[id] == nil { result[id] = item } }
            return result
        }
        let needsByChat = firstByChat(briefNeeds), finishedByChat = firstByChat(briefFinished), stuckByChat = firstByChat(briefStuck)
        var byID: [String: AgentSession] = [:]
        for session in all + waiting + running + unread where byID[session.id.lowercased()] == nil { byID[session.id.lowercased()] = session }

        var needs: [NeedsYou] = []
        var listed: Set<String> = []
        // Sub-agents never get a card: they are answered through their parent chat.
        for session in waiting where session.isSubagent != true && listed.insert(session.id.lowercased()).inserted {
            needs.append(NeedsYou(id: session.id, session: session, item: needsByChat[session.id.lowercased()], since: session.updatedAt))
        }
        let workingIDs = Set(running.map { $0.id.lowercased() })
        var asked: [NeedsYou] = []
        for item in briefNeeds {
            let chat = key(item.chatID)
            if let chat, listed.contains(chat) || workingIDs.contains(chat) { continue }
            let session = chat.flatMap { byID[$0] }
            if session?.isSubagent == true { continue }
            if let chat { listed.insert(chat) }
            asked.append(NeedsYou(id: session?.id ?? item.id, session: session, item: item, since: item.updatedAt))
        }
        needs += asked.sorted { $0.since != $1.since ? $0.since > $1.since : $0.id < $1.id }

        let working = running.filter { $0.isSubagent != true }
            .map { Working(session: $0, stuck: stuckByChat[$0.id.lowercased()]) }
        let toRead = unread.filter { !listed.contains($0.id.lowercased()) }.map { session in
            ToRead(session: session, outcome: clean(finishedByChat[session.id.lowercased()]?.headline) ?? clean(previews[session.id]))
        }
        return HomeBoard(needsYou: needs, working: working, toRead: toRead)
    }

    private static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? nil : line
    }

    // MARK: Sentence

    /// "2 chats need you, 3 are working, and 4 pull requests shipped today." Ready-to-read results
    /// join only when nothing needs you and nothing works (their section shows the count). A low
    /// usage limit follows as its own sentence.
    public static func sentence(needsYou: Int, working: Int, toRead: Int, shipped: Int? = nil, usageLine: String? = nil) -> String {
        var parts: [String] = []
        var chatsNamed = false
        func subject(_ count: Int) -> String {
            defer { chatsNamed = true }
            return chatsNamed ? "\(count)" : "\(count) chat\(count == 1 ? "" : "s")"
        }
        if needsYou > 0 { parts.append("\(subject(needsYou)) need\(needsYou == 1 ? "s" : "") you") }
        if working > 0 { parts.append("\(subject(working)) \(working == 1 ? "is" : "are") working") }
        if needsYou == 0 && working == 0 && toRead > 0 {
            parts.append("\(toRead) result\(toRead == 1 ? " is" : "s are") ready to read")
        }
        if let shipped, shipped > 0 { parts.append("\(shipped) pull request\(shipped == 1 ? "" : "s") shipped today") }
        var text: String
        switch parts.count {
        case 0: text = "All quiet. Nothing needs you and no agents are working."
        case 1: text = parts[0] + "."
        case 2: text = parts[0] + " and " + parts[1] + "."
        default: text = parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1] + "."
        }
        if needsYou == 0 && working == 0 && toRead == 0 && parts.count == 1 { text = "Nothing needs you and no agents are working. " + text }
        if let usageLine, !usageLine.isEmpty { text += " " + usageLine }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The usage sentence the old summary used: the tightest current limit, only when it is low.
    public static func usageLine(_ providers: [ProviderUsage], now: Date) -> String? { HomeSentence.usageLine(providers, now: now) }

    // MARK: Stop on a working card

    /// What a working card offers, by the same decision as the Chats header's Stop
    /// (`ChatReply.composerPlan(...).stop` with the cached Claude open-session check): `stop` when
    /// Burro can stop it (a Codex turn, a Claude background session); `openInProvider` when only the
    /// app that owns it can (the Claude app, or a terminal when the chat has a link); `elsewhere` when
    /// it runs interactively somewhere Burro can't open (a terminal): the card says to stop it there;
    /// `none` while the Claude check hasn't answered, or when Burro can't reach the chat (machine
    /// gone or not answering, unknown kind). `host`: the chat's configured machine (nil on this Mac).
    public enum StopOffer: Equatable, Sendable { case stop, openInProvider, elsewhere, none }

    public static func stopOffer(_ session: AgentSession, host: RemoteHost?, check: ChatReply.ClaudeCheck?) -> StopOffer {
        let open: StopOffer = session.chatURL != nil ? .openInProvider : .none
        guard ChatTranscripts.identity(of: session) != nil else { return open }
        if let remote = session.remote, host == nil || remote.stale { return .none }
        if session.provider == .claude && session.remote == nil && session.claudeDesktopSessionID != nil { return open }
        // Like the header: no Stop for a Claude chat until its open-session check has answered.
        if session.provider == .claude && check == nil { return .none }
        let plan = ChatReply.composerPlan(session, host: host, check: check, setupProblem: nil, queued: false, hasURL: session.chatURL != nil)
        switch plan.stop {
        case .codex?, .claudeBackground?, .claudeRemote?: return .stop
        case .elsewhere?: return session.chatURL != nil ? .openInProvider : .elsewhere
        case nil: return .none
        }
    }

    /// What a Stop failure note belongs to: the chat's state and the turn Burro saw begin. The note
    /// is shown only while this stays the same, so it goes when the turn changes.
    public static func turnKey(_ session: AgentSession, turnStart: Date?) -> String {
        "\(session.state.rawValue)|\(turnStart.map { String($0.timeIntervalSince1970) } ?? "-")"
    }

    // MARK: Machines and times

    /// One line for a machine on Home: "2 working · 1 needs you", "1 working · checked 8 s ago", or
    /// the machine's own status line when it isn't connected ("Unreachable since 14:02 · retrying in 30 s").
    /// `status` is RemoteStatusLine's text for another machine, nil for this Mac.
    public static func machineLine(counts: HomeCounts, status: String?) -> String {
        var parts: [String] = []
        if counts.running > 0 { parts.append("\(counts.running) working") }
        if counts.waiting > 0 { parts.append("\(counts.waiting) need\(counts.waiting == 1 ? "s" : "") you") }
        guard let status else { return parts.isEmpty ? "Quiet" : parts.joined(separator: " · ") }
        let connected = "Connected · "
        guard status.hasPrefix(connected) else { return status }
        parts.append(String(status.dropFirst(connected.count)))
        return parts.joined(separator: " · ")
    }

    /// "turn 18 min", "turn 1 h 05 min", "turn under 1 min".
    public static func turnText(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "turn under 1 min" }
        if minutes < 60 { return "turn \(minutes) min" }
        return "turn \(minutes / 60) h " + String(format: "%02d", minutes % 60) + " min"
    }

    /// "active just now", "active 4 min ago": the chat's last output, when the turn's start is unknown.
    public static func activeText(_ updatedAt: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(updatedAt)) / 60)
        if minutes < 1 { return "active just now" }
        if minutes < 60 { return "active \(minutes) min ago" }
        return "active \(minutes / 60) h ago"
    }

    /// The shortest form of a working card's time, for a footer with no room left beside its
    /// action: "18m", "1h 05m", "<1m", "now", "4m ago", "2h ago".
    public static func compactTime(_ text: String) -> String {
        var rest = text
        for lead in ["turn ", "active "] where rest.hasPrefix(lead) { rest.removeFirst(lead.count) }
        if rest == "just now" { return "now" }
        return rest.replacingOccurrences(of: "under 1 min", with: "<1m")
            .replacingOccurrences(of: " min", with: "m").replacingOccurrences(of: " h", with: "h")
    }

    /// "asked 4 min ago" (a question triage found) or "waiting 1 min" (an input request).
    public static func waitText(_ since: Date, waiting: Bool, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(since)) / 60)
        let span = minutes < 1 ? "under 1 min" : minutes < 60 ? "\(minutes) min" : minutes < 1440 ? "\(minutes / 60) h" : "\(minutes / 1440) d"
        if waiting { return "waiting " + span }
        return minutes < 1 ? "asked just now" : "asked \(span) ago"
    }
}

/// When each working chat's current turn began, as far as Burro saw it: a chat seen not working
/// and then working started its turn at that sample; a chat first seen working started at its
/// own start time when that falls after Burro's previous sample (a new chat); anything already
/// working when Burro started, or first seen mid-turn, is unknown (nil) rather than guessed.
public struct TurnClock: Sendable, Equatable {
    public private(set) var starts: [String: Date] = [:]
    private var working: Set<String> = []
    private var known: Set<String> = []
    private var lastSample: Date?

    public init() {}

    public mutating func update(_ sessions: [AgentSession], now: Date) {
        var nextWorking: Set<String> = [], nextStarts: [String: Date] = [:]
        for session in sessions where session.state == .working {
            let id = session.id
            guard nextWorking.insert(id).inserted else { continue }
            if working.contains(id) {
                if let start = starts[id] { nextStarts[id] = start }
            } else if let last = lastSample {
                if known.contains(id) {
                    nextStarts[id] = now
                } else if let started = session.startedAt, started >= last.addingTimeInterval(-120), started <= now {
                    nextStarts[id] = started
                }
            }
        }
        known = Set(sessions.map(\.id)); working = nextWorking; starts = nextStarts; lastSample = now
    }

    /// How long the chat's current turn has run, when Burro knows when it began.
    public func turn(_ id: String, now: Date) -> TimeInterval? { starts[id].map { max(0, now.timeIntervalSince($0)) } }

    /// The notch's compact form: "45s", "2m 14s" under ten minutes, "41m" under an hour, then "1h 05m".
    public static func text(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 10 { return "\(minutes)m \(String(format: "%02d", total % 60))s" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }
}
