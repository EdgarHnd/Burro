// Reply to an existing chat from Burro, with the same choices the Codex and Claude apps offer:
// model, reasoning effort and how much it may do without asking. Only on an explicit Send.
// Attached files (chats on this Mac): Codex gets images as `localImage` input items and other
// files as paths in the text; Claude gets every path in the text. Stop and steer: ChatSteering.swift.
//
// Codex: Codex's app-server daemon resumes the thread and starts (or steers) a turn. On another
// machine the same JSON-RPC runs over SSH through `codex app-server proxy` there.
// Claude: `claude --bg --resume <id>` continues the session in the background under the same id,
// locally or over SSH through a fixed script; approvals then wait in `claude attach`. A session
// that is still open would fork into a copy instead, so Burro refuses those, except an idle
// background session when the Send asks for it (`stopIdleBackground`): then that one session is
// stopped first and the reply goes only once `claude agents` confirms it stopped
// (ClaudeContinue.swift). Interactive sessions (the Claude app, a terminal) are never stopped.
import Foundation

public enum ReplyAccess: String, CaseIterable, Identifiable, Sendable {
    case keep, ask, approveForMe, edit, readOnly
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .keep: "Current access"
        case .ask: "Ask me"
        case .approveForMe: "Approve for me"
        case .edit: "Edit freely"
        case .readOnly: "Read only"
        }
    }
    public var detail: String {
        switch self {
        case .keep: "Keep this chat's settings"
        case .ask: "Asks before anything outside the workspace"
        case .approveForMe: "Codex reviews its own approval requests"
        case .edit: "No approval prompts"
        case .readOnly: "Reads and plans, changes nothing"
        }
    }
    public var symbol: String {
        switch self {
        case .keep: "slider.horizontal.3"
        case .ask: "hand.raised"
        case .approveForMe: "checkmark.shield"
        case .edit: "pencil"
        case .readOnly: "eye"
        }
    }
    public static func options(for provider: AgentProvider) -> [ReplyAccess] {
        provider == .codex ? allCases : [.keep, .ask, .edit, .readOnly]
    }
}

public struct ReplyRequest: Sendable, Equatable {
    public var text: String
    public var model: String?
    public var effort: String?
    public var access: ReplyAccess
    /// Absolute paths of files to attach (chats on this Mac only).
    public var attachments: [String] = []
    public init(text: String, model: String? = nil, effort: String? = nil, access: ReplyAccess = .keep, attachments: [String] = []) {
        self.text = text; self.model = model; self.effort = effort; self.access = access; self.attachments = attachments
    }
    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public enum ChatReply {
    /// Why this chat can't take a reply right now, or nil when it can.
    public static func unavailable(_ session: AgentSession, host: RemoteHost?) -> String? {
        guard ChatTranscripts.identity(of: session) != nil else { return "Burro can't reply to this kind of chat." }
        if session.remote != nil && host == nil { return "That machine isn't configured in Burro any more." }
        if session.remote?.stale == true { return "\(session.remote?.hostName ?? "That machine") isn't answering right now." }
        if session.provider == .claude && session.state == .working {
            return "Claude is working on this chat. You can reply when it's done, or attach in Terminal."
        }
        return nil
    }

    /// Sends the message; returns a short confirmation. `stopIdleBackground`: the owner's Send says
    /// so (the composer's "Stops the idle background session…", or a message they queued): an idle
    /// Claude background session of this chat is stopped and then continued with the message.
    /// Without it such a session is refused as before.
    public static func send(_ request: ReplyRequest, to session: AgentSession, host: RemoteHost?, stopIdleBackground: Bool = false) throws -> String {
        guard !request.trimmed.isEmpty else { throw LaunchError.failed("Write a message first.") }
        guard request.trimmed.count <= 100_000 else { throw LaunchError.failed("That message is too long.") }
        if let reason = unavailable(session, host: host) { throw LaunchError.failed(reason) }
        guard let (provider, id) = ChatTranscripts.identity(of: session) else { throw LaunchError.failed("Burro can't reply to this kind of chat.") }
        if session.remote != nil && !request.attachments.isEmpty { throw LaunchError.failed(ChatAttachments.localOnly) }
        if provider == "codex" {
            let server = try host.map { try CodexAppServer.remote($0) }
                ?? CodexAppServer.connect(executable: CodexUsageReader.executable() ?? { throw LaunchError.notInstalled(.codex) }())
            defer { server.close() }
            // Loads the thread into the daemon if it isn't already; a running turn is steered.
            _ = try? server.request("thread/resume", ["threadId": id, "excludeTurns": true])
            _ = try server.request("turn/start", codexTurnParams(threadID: id, request))
            return session.state == .working ? "Sent. Codex will take it into account in this turn." : "Sent. Codex is on it."
        }
        let arguments = claudeArguments(sessionID: id, request)
        // One Claude reply per chat at a time from this app (a Send and a queued message racing
        // could otherwise both find the session stopped and resume it twice).
        guard ClaudeReplyGate.shared.enter(id) else { throw LaunchError.failed("A reply to this chat is already on its way.") }
        defer { ClaudeReplyGate.shared.leave(id) }
        let output: String
        if let host {
            let operation = stopIdleBackground ? "continue" : "args"
            output = try remoteClaude([operation: arguments, "cwd": session.cwd], host: host)
        } else {
            guard let claude = ClaudeLaunch.executable() else { throw LaunchError.notInstalled(.claude) }
            let folder = FileManager.default.fileExists(atPath: session.cwd) ? session.cwd : NSHomeDirectory()
            // A session that is still open would fork into a copy: refused, or (idle background,
            // when asked) stopped and confirmed stopped first.
            output = try continueClaude(id, arguments: arguments, folder: folder, stopIdleBackground: stopIdleBackground, commands: .local(claude))
        }
        if output.localizedCaseInsensitiveContains("copy") { return "Sent, but Claude started a copy of this chat because it was open elsewhere." }
        return "Sent. Claude is continuing in the background."
    }

    static func codexTurnParams(threadID: String, _ request: ReplyRequest) -> [String: Any] {
        var params: [String: Any] = ["threadId": threadID, "input": ChatAttachments.codexInput(text: request.trimmed, paths: request.attachments)]
        if let model = request.model, !model.isEmpty { params["model"] = model }
        if let effort = request.effort, !effort.isEmpty { params["effort"] = effort }
        switch request.access {
        case .keep: break
        case .ask: params["approvalPolicy"] = "on-request"; params["approvalsReviewer"] = "user"
        case .approveForMe: params["approvalPolicy"] = "on-request"; params["approvalsReviewer"] = "auto_review"
        case .edit: params["approvalPolicy"] = "never"
        case .readOnly: params["approvalPolicy"] = "on-request"; params["sandboxPolicy"] = ["type": "readOnly"]
        }
        return params
    }

    /// `claude --bg --resume <id> …`; the message follows `--` so it is never read as a flag.
    static func claudeArguments(sessionID: String, _ request: ReplyRequest) -> [String] {
        var args = ["--bg", "--resume", sessionID]
        switch request.access {
        case .ask: args += ["--permission-mode", "manual"]
        case .edit: args += ["--permission-mode", "acceptEdits"]
        case .readOnly: args += ["--permission-mode", "plan"]
        case .keep, .approveForMe: break
        }
        if let model = request.model, valid(model) { args += ["--model", model] }
        if let effort = request.effort, valid(effort) { args += ["--effort", effort] }
        return args + ["--", ChatAttachments.claudeText(text: request.trimmed, paths: request.attachments)]
    }

    /// Whether a Claude chat can take a reply from Burro. Claude continues a session only when
    /// nothing has it open; otherwise it would fork a copy. Slow: call off the main thread.
    public struct ClaudeCheck: Sendable, Equatable {
        public var problem: String?
        /// An open background session's short id, for "Attach in Terminal".
        public var attach: String?
        /// Something has the session open; as a background session; working right now.
        public var open = false
        public var background = false
        public var busy = false
        /// An idle background session of this chat: a Send stops it and continues it with the
        /// message (nothing else has it open).
        public var continues = false
    }
    public static func claudeCheck(_ session: AgentSession, host: RemoteHost?) -> ClaudeCheck {
        guard session.provider == .claude, let (_, id) = ChatTranscripts.identity(of: session) else { return ClaudeCheck() }
        if let host { return remoteClaudeCheck(id, host: host) }
        guard let claude = ClaudeLaunch.executable() else { return ClaudeCheck(problem: LaunchError.notInstalled(.claude).errorDescription) }
        let commands = ClaudeCommands.local(claude)
        let live = claudeLive(id, claude: claude)
        let attached = live.map { $0.background && $0.idle && $0.handle != nil } == true
            && attachedInTerminal(commands.processes(), handle: live?.handle ?? "", sessionID: id)
        return claudePlan(live, attached: attached)
    }

    /// A session `claude agents --json --all` lists as running (finished background sessions are
    /// left out). `idle`: its process waits for a message; `waiting`: it asks for an answer or an
    /// approval; `busy`: working, or running without a status.
    struct ClaudeLive: Equatable {
        var handle: String?; var background: Bool; var busy: Bool
        var idle = false
        var waiting = false
    }

    static func claudeLive(_ id: String, claude: String) -> ClaudeLive? {
        guard case .found(let live) = claudeLookup(id, commands: .local(claude)) else { return nil }
        return live
    }
    static func claudeLive(_ id: String, rows: Data) -> ClaudeLive? {
        guard case .found(let live) = claudeLookup(id, rows: rows) else { return nil }
        return live
    }
    static let stillOpen = "This chat is still open as a background session. Attach to it to reply there."
    /// `attached`: a `claude attach` for this session runs in a terminal (only looked at for an
    /// idle background session).
    static func claudePlan(_ live: ClaudeLive?, attached: Bool = false) -> ClaudeCheck {
        guard let live else { return ClaudeCheck() }
        if live.busy {
            return ClaudeCheck(problem: "Claude is working on this chat. You can reply when it's done.", attach: live.background ? live.handle : nil,
                               open: true, background: live.background, busy: true)
        }
        if live.background {
            if live.waiting {
                return ClaudeCheck(problem: "Claude is waiting for you in this chat (a question or an approval). Attach to it to answer.",
                                   attach: live.handle, open: true, background: true)
            }
            if live.idle, live.handle != nil, attached {
                return ClaudeCheck(problem: "This chat is attached in a terminal. Reply there, or close that terminal first.", open: true, background: true)
            }
            if live.idle, let handle = live.handle {
                return ClaudeCheck(attach: handle, open: true, background: true, continues: true)
            }
            return ClaudeCheck(problem: stillOpen, attach: live.handle, open: true, background: true)
        }
        return ClaudeCheck(problem: "This chat is open in Claude Code (a terminal or the Claude app). Reply there: a reply from Burro would start a separate copy.",
                           open: true)
    }

    /// Model and effort names are plain identifiers; anything else is dropped.
    static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 80 && value.allSatisfy { $0.isLetter || $0.isNumber || "._-[]".contains($0) }
    }

    /// How long Burro waits for `remote_reply.py`: stop-and-continue runs bounded steps there that
    /// add up to under two minutes (lookups, the stop, its confirmation, the resume); others 90 s.
    static func remoteTimeout(_ request: [String: Any]) -> TimeInterval { request["continue"] != nil ? 150 : 90 }

    static func remoteClaude(_ request: [String: Any], host: RemoteHost) throws -> String {
        let result = try RemoteScript.run("remote_reply", request: request, host: host, timeout: remoteTimeout(request))
        guard let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any] else {
            throw LaunchError.failed("\(host.name) didn't answer as expected.")
        }
        guard object["ok"] as? Bool == true else {
            let message = (object["error"] as? String) ?? "Claude didn't continue on \(host.name)."
            if let refusal = ReplyRefusal.remote(object["live"], message: message) { throw refusal }
            throw LaunchError.failed(message)
        }
        return object["output"] as? String ?? ""
    }

    /// Codex models on a machine, for the reply composer.
    public static func codexModels(host: RemoteHost?) throws -> [LaunchModel] {
        guard let host else { return try CodexLaunch.listModels() }
        let server = try CodexAppServer.remote(host)
        defer { server.close() }
        return CodexLaunch.models(from: try server.request("model/list", ["limit": 100]))
    }

    static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).map(String.init).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// Runs one of Burro's fixed Python scripts on a configured machine: the request travels as a
/// base64 line in front of the script on stdin, so nothing user-written reaches a shell.
enum RemoteScript {
    static func url(_ name: String) -> URL? { Bundle.module.url(forResource: name, withExtension: "py") }
    static func run(_ name: String, request: [String: Any], host: RemoteHost, timeout: TimeInterval, output: URL? = nil) throws -> Data {
        guard host.enabled, host.validationError == nil else { throw LaunchError.failed("\(host.name) can't be reached from Burro.") }
        guard let url = url(name), let body = try? Data(contentsOf: url) else {
            throw LaunchError.failed("This build of Burro is missing \(name).py.")
        }
        let encoded = try JSONSerialization.data(withJSONObject: request).base64EncodedString()
        var input = Data("REQUEST_B64 = \"\(encoded)\"\n".utf8)
        input.append(body)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = RemoteAgentMonitor.arguments(for: host)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let outURL = output ?? folder.appendingPathComponent("out"), errURL = folder.appendingPathComponent("err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        let pipe = Pipe()
        process.standardInput = pipe; process.standardOutput = out; process.standardError = err
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        pipe.fileHandleForWriting.write(input)
        try? pipe.fileHandleForWriting.close()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw LaunchError.failed("\(host.name) didn't answer in time.")
        }
        let status = process.terminationStatus
        if status != 0 {
            let message = (try? String(contentsOf: errURL, encoding: .utf8))?.split(whereSeparator: \.isNewline).last.map(String.init)
            throw LaunchError.failed(status == 255 ? "Couldn't reach \(host.name) over SSH." : (message ?? "\(host.name) refused the request."))
        }
        return output == nil ? ((try? Data(contentsOf: outURL)) ?? Data()) : Data()
    }
}
