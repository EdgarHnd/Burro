// Reply to an existing chat from Burro, with the same choices the Codex and Claude apps offer:
// model, reasoning effort and how much it may do without asking. Only on an explicit Send.
//
// Codex: Codex's app-server daemon resumes the thread and starts (or steers) a turn. On another
// machine the same JSON-RPC runs over SSH through `codex app-server proxy` there.
// Claude: `claude --bg --resume <id>` continues the session in the background under the same id,
// locally or over SSH through a fixed script; approvals then wait in `claude attach`.
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
    public init(text: String, model: String? = nil, effort: String? = nil, access: ReplyAccess = .keep) {
        self.text = text; self.model = model; self.effort = effort; self.access = access
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

    /// Sends the message; returns a short confirmation.
    public static func send(_ request: ReplyRequest, to session: AgentSession, host: RemoteHost?) throws -> String {
        guard !request.trimmed.isEmpty else { throw LaunchError.failed("Write a message first.") }
        guard request.trimmed.count <= 100_000 else { throw LaunchError.failed("That message is too long.") }
        if let reason = unavailable(session, host: host) { throw LaunchError.failed(reason) }
        guard let (provider, id) = ChatTranscripts.identity(of: session) else { throw LaunchError.failed("Burro can't reply to this kind of chat.") }
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
        let output: String
        if let host {
            output = try remoteClaude(["args": arguments, "cwd": session.cwd], host: host)
        } else {
            guard let claude = ClaudeLaunch.executable() else { throw LaunchError.notInstalled(.claude) }
            let folder = FileManager.default.fileExists(atPath: session.cwd) ? session.cwd : NSHomeDirectory()
            // A session that is still open would fork into a copy; Burro never stops it for you.
            if let problem = claudePlan(claudeLive(id, claude: claude)).problem { throw LaunchError.failed(problem) }
            let result = try LaunchShell.run(claude, arguments, folder: folder, timeout: 60)
            guard result.code == 0 else { throw LaunchError.failed(lastLine(result.text).map { "Claude didn't continue: \($0)" } ?? "Claude didn't continue.") }
            output = result.text
        }
        if output.localizedCaseInsensitiveContains("copy") { return "Sent, but Claude started a copy of this chat because it was open elsewhere." }
        return "Sent. Claude is continuing in the background."
    }

    static func codexTurnParams(threadID: String, _ request: ReplyRequest) -> [String: Any] {
        var params: [String: Any] = ["threadId": threadID, "input": [["type": "text", "text": request.trimmed]]]
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
        return args + ["--", request.trimmed]
    }

    /// Whether a Claude chat can take a reply from Burro. Claude continues a session only when
    /// nothing has it open; otherwise it would fork a copy. Slow: call off the main thread.
    public struct ClaudeCheck: Sendable, Equatable {
        public var problem: String?
        /// An open background session's short id, for "Attach in Terminal".
        public var attach: String?
    }
    public static func claudeCheck(_ session: AgentSession, host: RemoteHost?) -> ClaudeCheck {
        guard session.provider == .claude, let (_, id) = ChatTranscripts.identity(of: session) else { return ClaudeCheck() }
        if let host {
            do { _ = try remoteClaude(["check": id], host: host); return ClaudeCheck() }
            catch { return ClaudeCheck(problem: (error as? LocalizedError)?.errorDescription) }
        }
        guard let claude = ClaudeLaunch.executable() else { return ClaudeCheck(problem: LaunchError.notInstalled(.claude).errorDescription) }
        return claudePlan(claudeLive(id, claude: claude))
    }

    struct ClaudeLive: Equatable { var handle: String?; var background: Bool; var busy: Bool }

    static func claudeLive(_ id: String, claude: String) -> ClaudeLive? {
        guard let result = try? LaunchShell.run(claude, ["agents", "--json", "--all"], folder: NSHomeDirectory(), timeout: 20) else { return nil }
        return claudeLive(id, rows: Data(result.text.utf8))
    }
    static func claudeLive(_ id: String, rows: Data) -> ClaudeLive? {
        guard let rows = try? JSONSerialization.jsonObject(with: rows) as? [[String: Any]],
              let row = rows.first(where: { ($0["sessionId"] as? String)?.lowercased() == id.lowercased() }) else { return nil }
        let handle = (row["id"] as? String).flatMap { $0.range(of: #"^[0-9a-f]{6,36}$"#, options: .regularExpression) != nil ? $0 : nil }
        return ClaudeLive(handle: handle, background: row["kind"] as? String == "background", busy: row["status"] as? String == "busy")
    }
    static func claudePlan(_ live: ClaudeLive?) -> ClaudeCheck {
        guard let live else { return ClaudeCheck() }
        if live.busy { return ClaudeCheck(problem: "Claude is working on this chat. You can reply when it's done.", attach: live.background ? live.handle : nil) }
        if live.background {
            return ClaudeCheck(problem: "This chat is still open as a background session. Attach to it to reply there.", attach: live.handle)
        }
        return ClaudeCheck(problem: "This chat is open in Claude Code (a terminal or the Claude app). Reply there: a reply from Burro would start a separate copy.")
    }

    /// Model and effort names are plain identifiers; anything else is dropped.
    static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 80 && value.allSatisfy { $0.isLetter || $0.isNumber || "._-[]".contains($0) }
    }

    static func remoteClaude(_ request: [String: Any], host: RemoteHost) throws -> String {
        let result = try RemoteScript.run("remote_reply", request: request, host: host, timeout: 90)
        guard let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any] else {
            throw LaunchError.failed("\(host.name) didn't answer as expected.")
        }
        guard object["ok"] as? Bool == true else { throw LaunchError.failed((object["error"] as? String) ?? "Claude didn't continue on \(host.name).") }
        return object["output"] as? String ?? ""
    }

    /// Codex models on a machine, for the reply composer.
    public static func codexModels(host: RemoteHost?) throws -> [LaunchModel] {
        guard let host else { return try CodexLaunch.listModels() }
        let server = try CodexAppServer.remote(host)
        defer { server.close() }
        return CodexLaunch.models(from: try server.request("model/list", ["limit": 100]))
    }

    private static func lastLine(_ text: String) -> String? {
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
