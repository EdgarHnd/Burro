// Starting a new Codex or Claude chat from Burro. Every launch is an explicit user action.
// Codex runs in its shared app-server daemon (the same one the Codex app uses), so the chat
// keeps running after Burro disconnects; Claude runs as a `claude --bg` background session.
// Both then appear in Burro's normal agent feed.
import Foundation

public enum LaunchProvider: String, CaseIterable, Identifiable, Sendable {
    case codex, claude
    public var id: String { rawValue }
    public var title: String { self == .codex ? "Codex" : "Claude Code" }
}

/// One choice that maps onto each tool's own sandbox/permission settings.
public enum LaunchAccess: String, CaseIterable, Identifiable, Sendable {
    case ask, edit, readOnly
    public var id: String { rawValue }
    public var title: String {
        switch self { case .ask: "Ask before acting"; case .edit: "Edit files freely"; case .readOnly: "Read only" }
    }
    public var detail: String {
        switch self {
        case .ask: "Edits the workspace; asks you before anything outside it. Waiting chats show in your inbox."
        case .edit: "Edits files without asking. Commands stay inside the workspace sandbox."
        case .readOnly: "Reads and plans; changes nothing."
        }
    }
    var codexSandbox: String { self == .readOnly ? "read-only" : "workspace-write" }
    var codexApproval: String { self == .edit ? "never" : "on-request" }
    var claudeMode: String {
        switch self { case .ask: "manual"; case .edit: "acceptEdits"; case .readOnly: "plan" }
    }
}

public struct LaunchModel: Identifiable, Sendable, Equatable, Hashable {
    public var id: String
    public var title: String
    public var efforts: [String]
    public var defaultEffort: String?
    public var isDefault: Bool
    public init(id: String, title: String, efforts: [String], defaultEffort: String? = nil, isDefault: Bool = false) {
        self.id = id; self.title = title; self.efforts = efforts; self.defaultEffort = defaultEffort; self.isDefault = isDefault
    }
    /// Claude Code's current models; `claude --effort` takes the same levels for each.
    public static let claude: [LaunchModel] = [
        LaunchModel(id: "claude-opus-5-5", title: "Opus 5.5", efforts: claudeEfforts, defaultEffort: "high", isDefault: true),
        LaunchModel(id: "claude-sonnet-5-5", title: "Sonnet 5.5", efforts: claudeEfforts, defaultEffort: "medium"),
        LaunchModel(id: "claude-haiku-5-5", title: "Haiku 5.5", efforts: claudeEfforts, defaultEffort: "medium"),
        LaunchModel(id: "claude-fable-5-1", title: "Fable 5.1", efforts: claudeEfforts, defaultEffort: "high"),
    ]
    public static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
}

public struct LaunchRequest: Sendable, Equatable {
    public var provider: LaunchProvider
    public var prompt: String
    public var folder: String
    public var model: String?
    public var effort: String?
    public var access: LaunchAccess
    public init(provider: LaunchProvider, prompt: String, folder: String, model: String? = nil, effort: String? = nil,
                access: LaunchAccess = .ask) {
        self.provider = provider; self.prompt = prompt; self.folder = folder; self.model = model; self.effort = effort; self.access = access
    }
    public var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public struct LaunchResult: Sendable, Equatable {
    public var provider: LaunchProvider
    /// Codex thread UUID, or Claude's full session UUID when it could be resolved.
    public var sessionID: String
    /// Claude's short background id (what `claude attach` takes).
    public var handle: String?
    public var folder: String
    public init(provider: LaunchProvider, sessionID: String, handle: String?, folder: String) {
        self.provider = provider; self.sessionID = sessionID; self.handle = handle; self.folder = folder
    }
    public var chatURL: URL? {
        provider == .codex ? URL(string: "codex://threads/\(sessionID)") : nil
    }
}

public enum LaunchError: Error, Equatable, LocalizedError {
    case notInstalled(LaunchProvider)
    case emptyPrompt
    case missingFolder
    case untrusted(String)
    /// The session registered but stopped at a terminal prompt before its first turn
    /// (for example approving a new project MCP server), so it never started working.
    case blocked(folder: String, reason: String)
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .notInstalled(let provider): "\(provider.title) isn't installed on this Mac."
        case .emptyPrompt: "Write what the agent should do."
        case .missingFolder: "That project folder no longer exists."
        case .untrusted(let folder): "Claude hasn't been trusted in \(URL(fileURLWithPath: folder).lastPathComponent) yet. Run claude there once in Terminal and accept the prompt, then try again."
        case .blocked(let folder, let reason):
            "The chat did not start. Claude Code stopped at a prompt in \(URL(fileURLWithPath: folder).lastPathComponent) before its first turn: \(reason). "
                + "Burro removed that stuck session. Run claude in that folder once in Terminal, answer the prompt, then start the chat again."
        case .failed(let message): message
        }
    }
}

// MARK: Claude

public enum ClaudeLaunch {
    public static func executable(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                                  exists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].first(where: exists)
    }
    /// `claude --bg …` arguments. The prompt follows `--` so it can never be read as a flag.
    public static func arguments(for request: LaunchRequest) -> [String] {
        var args = ["--bg", "--permission-mode", request.access.claudeMode]
        if let model = request.model, !model.isEmpty { args += ["--model", model] }
        if let effort = request.effort, !effort.isEmpty { args += ["--effort", effort] }
        return args + ["--", request.trimmedPrompt]
    }
    /// The short id from `claude attach <id>` in `--bg` output.
    public static func handle(fromOutput output: String) -> String? {
        guard let range = output.range(of: #"claude attach ([0-9a-f]{6,36})"#, options: .regularExpression) else { return nil }
        return output[range].split(separator: " ").last.map(String.init)
    }
    /// Finds the full session id for a background handle in `claude agents --json --all`.
    public static func sessionID(handle: String, agentsJSON: Data) -> String? {
        guard let rows = try? JSONSerialization.jsonObject(with: agentsJSON) as? [[String: Any]] else { return nil }
        let row = rows.first { ($0["id"] as? String) == handle } ?? rows.first { ($0["sessionId"] as? String)?.hasPrefix(handle) == true }
        return row?["sessionId"] as? String
    }

    /// Runs `claude --bg` in the project folder through a login shell, so the session gets your
    /// usual PATH (git, node, toolchains). Arguments are passed as positional parameters, never
    /// interpolated into the shell script.
    ///
    /// `claude --bg` prints its attach line as soon as the daemon claims a session, before that
    /// session has done anything; it can then sit at a terminal prompt (a new project MCP server
    /// to approve, say) and never write a transcript, while `claude agents` may still list it as
    /// "working". So a launch only counts once the session's transcript exists. A session stuck at a
    /// prompt, gone, or silent past the bounded wait is removed and reported as an error, never as started.
    public static func start(_ request: LaunchRequest, executable: String? = executable()) throws -> LaunchResult {
        try start(request, executable: executable, host: .live)
    }

    static func start(_ request: LaunchRequest, executable: String?, host: ClaudeLaunchHost) throws -> LaunchResult {
        guard let executable else { throw LaunchError.notInstalled(.claude) }
        guard host.fileExists(request.folder) else { throw LaunchError.missingFolder }
        let result = try host.run(executable, arguments(for: request), request.folder, 60)
        let output = result.text
        if output.contains("Workspace not trusted") { throw LaunchError.untrusted(request.folder) }
        guard result.code == 0, let handle = handle(fromOutput: output) else {
            let line = output.split(whereSeparator: \.isNewline).map(String.init).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            throw LaunchError.failed(line.map { "Claude didn't start: \($0)" } ?? "Claude didn't start.")
        }
        let deadline = host.now().addingTimeInterval(host.verifyTimeout)
        var check = StartCheck.pending(state: nil, sessionID: nil)
        while true {
            let agents = try? host.run(executable, ["agents", "--json", "--all"], request.folder, 20)
            let job = host.readFile(host.configDirectory + "/jobs/\(handle)/state.json")
            check = startCheck(handle: handle, folder: request.folder, agentsJSON: agents.map { Data($0.text.utf8) }, jobJSON: job) { cwd, session in
                host.fileExists(host.configDirectory + "/projects/" + ClaudeTranscriptTail.projectFolder(cwd) + "/\(session).jsonl")
            }
            switch check {
            case .started(let session):
                return LaunchResult(provider: .claude, sessionID: session, handle: handle, folder: request.folder)
            case .blocked(let reason):
                discard(handle, executable: executable, folder: request.folder, host: host)
                throw LaunchError.blocked(folder: request.folder, reason: reason)
            case .ended(let state):
                discard(handle, executable: executable, folder: request.folder, host: host)
                throw LaunchError.failed("The chat did not start. Claude Code's background session \(handle) ended (\(state)) before its first turn. Run `claude logs \(handle)` in Terminal to see why.")
            case .pending(let state, _):
                guard host.now() < deadline else {
                    // The daemon's state can lag: a session sitting at the MCP approval prompt has been seen
                    // listed as "working / starting…". Its terminal output says what it is waiting for.
                    let screen = try? host.run(executable, ["logs", handle], request.folder, 20)
                    discard(handle, executable: executable, folder: request.folder, host: host)
                    if let prompt = screen.flatMap({ pendingPrompt(inLogs: $0.text) }) {
                        throw LaunchError.blocked(folder: request.folder, reason: prompt)
                    }
                    let seconds = Int(host.verifyTimeout.rounded())
                    throw LaunchError.failed(state.map {
                        "The chat did not start. Claude Code's background session \(handle) was still \"\($0)\" after \(seconds) seconds and never wrote a transcript, so Burro removed it."
                    } ?? "The chat did not start. Claude Code printed a background id (\(handle)) but no such session appeared in `claude agents` within \(seconds) seconds.")
                }
                host.sleep(host.pollInterval)
            }
        }
    }

    /// What a just-launched background session looks like right now.
    enum StartCheck: Equatable {
        /// Its transcript exists: the chat really started.
        case started(sessionID: String)
        /// It stopped at a terminal prompt before writing anything.
        case blocked(String)
        /// It exited before writing anything.
        case ended(String)
        /// Not listed yet, or listed but hasn't written its first line.
        case pending(state: String?, sessionID: String?)
    }

    /// Reads `claude agents --json --all`, the daemon's job record (`<config>/jobs/<handle>/state.json`)
    /// and whether the transcript exists. A transcript wins: a session that started and then asks for
    /// a permission is a normal chat that needs you.
    static func startCheck(handle: String, folder: String, agentsJSON: Data?, jobJSON: Data?,
                           transcriptExists: (_ cwd: String, _ sessionID: String) -> Bool) -> StartCheck {
        let rows = agentsJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        let row = rows.first { ($0["id"] as? String) == handle } ?? rows.first { ($0["sessionId"] as? String)?.hasPrefix(handle) == true }
        let job = jobJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard row != nil || job != nil else { return .pending(state: nil, sessionID: nil) }
        let session = [row?["sessionId"], job?["sessionId"]].compactMap { $0 as? String }
            .first { UUID(uuidString: $0) != nil }?.lowercased()
        let cwd = row?["cwd"] as? String ?? job?["cwd"] as? String ?? folder
        if let session, transcriptExists(cwd, session) { return .started(sessionID: session) }
        let state = (row?["state"] as? String ?? job?["state"] as? String)?.lowercased()
        let detail = [job?["needs"], job?["detail"]].compactMap { $0 as? String }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        switch state ?? "" {
        case "blocked":
            // "approve 1 new project MCP server (x) — attach to respond": Burro removes the session, so drop the attach hint.
            let reason = detail.map { $0.components(separatedBy: " — ").first ?? $0 }?.trimmingCharacters(in: .whitespaces)
            return .blocked(reason.flatMap { $0.isEmpty ? nil : $0 } ?? "it is waiting for an answer in the terminal")
        case let ended where ["done", "failed", "error", "errored", "exited", "killed", "stopped", "completed"].contains(ended):
            return .ended(detail.map { "\(ended): \($0)" } ?? ended)
        default:
            return .pending(state: state, sessionID: session)
        }
    }

    /// The startup prompt a background session's screen (`claude logs <id>`) is showing, if one is known.
    static func pendingPrompt(inLogs logs: String) -> String? {
        // Cursor moves stand in for spaces on that screen: turn every escape sequence into a space.
        let plain = logs.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[A-Za-z]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        if let range = plain.range(of: #"New MCP servers? found in this project: [^\n]+"#, options: .regularExpression) {
            let names = plain[range].components(separatedBy: ": ").dropFirst().joined(separator: ": ").trimmingCharacters(in: .whitespaces)
            return "approve the new project MCP server \(names)"
        }
        if plain.range(of: "Do you trust the files in this folder", options: .caseInsensitive) != nil { return "trust this folder" }
        return nil
    }

    /// Stops and deletes a background session that never started, so retries don't pile up stuck copies.
    private static func discard(_ handle: String, executable: String, folder: String, host: ClaudeLaunchHost) {
        _ = try? host.run(executable, ["stop", handle], folder, 20)
        _ = try? host.run(executable, ["rm", handle], folder, 20)
    }
}

/// Everything `ClaudeLaunch.start` touches outside itself; swapped in tests.
struct ClaudeLaunchHost {
    var run: (_ executable: String, _ arguments: [String], _ folder: String, _ timeout: TimeInterval) throws -> LaunchShell.Output
    /// Claude Code's config folder (`~/.claude`, or `$CLAUDE_CONFIG_DIR`): holds `jobs/` and `projects/`.
    var configDirectory: String
    var fileExists: (String) -> Bool
    var readFile: (String) -> Data?
    var now: () -> Date
    var sleep: (TimeInterval) -> Void
    var verifyTimeout: TimeInterval = 20
    var pollInterval: TimeInterval = 0.5

    static var live: ClaudeLaunchHost {
        let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        return ClaudeLaunchHost(
            run: { try LaunchShell.run($0, $1, folder: $2, timeout: $3) },
            configDirectory: custom ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path,
            fileExists: FileManager.default.fileExists(atPath:),
            readFile: { FileManager.default.contents(atPath: $0) },
            now: Date.init,
            sleep: { Thread.sleep(forTimeInterval: $0) })
    }
}

// MARK: Codex

public enum CodexLaunch {
    public static func threadParams(for request: LaunchRequest) -> [String: Any] {
        var params: [String: Any] = ["cwd": request.folder, "sandbox": request.access.codexSandbox,
                                     "approvalPolicy": request.access.codexApproval, "serviceName": "burro"]
        if let model = request.model, !model.isEmpty { params["model"] = model }
        return params
    }
    public static func turnParams(threadID: String, for request: LaunchRequest) -> [String: Any] {
        var params: [String: Any] = ["threadId": threadID, "input": [["type": "text", "text": request.trimmedPrompt]]]
        if let model = request.model, !model.isEmpty { params["model"] = model }
        if let effort = request.effort, !effort.isEmpty { params["effort"] = effort }
        return params
    }
    /// `model/list` → visible models with their supported reasoning efforts.
    public static func models(from result: [String: Any]) -> [LaunchModel] {
        (result["data"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["id"] as? String ?? row["model"] as? String, row["hidden"] as? Bool != true else { return nil }
            let efforts = (row["supportedReasoningEfforts"] as? [Any] ?? []).compactMap { effort -> String? in
                (effort as? [String: Any])?["reasoningEffort"] as? String ?? effort as? String
            }
            return LaunchModel(id: id, title: row["displayName"] as? String ?? id, efforts: efforts,
                               defaultEffort: row["defaultReasoningEffort"] as? String, isDefault: row["isDefault"] as? Bool == true)
        }
    }

    public static func start(_ request: LaunchRequest, executable: String? = CodexUsageReader.executable()) throws -> LaunchResult {
        guard let executable else { throw LaunchError.notInstalled(.codex) }
        guard FileManager.default.fileExists(atPath: request.folder) else { throw LaunchError.missingFolder }
        let server = try CodexAppServer.connect(executable: executable)
        defer { server.close() }
        let thread = try server.request("thread/start", threadParams(for: request))
        guard let id = (thread["thread"] as? [String: Any])?["id"] as? String else { throw LaunchError.failed("Codex didn't create a thread.") }
        _ = try server.request("turn/start", turnParams(threadID: id, for: request))
        return LaunchResult(provider: .codex, sessionID: id, handle: nil, folder: request.folder)
    }
    public static func listModels(executable: String? = CodexUsageReader.executable()) throws -> [LaunchModel] {
        guard let executable else { throw LaunchError.notInstalled(.codex) }
        let server = try CodexAppServer.connect(executable: executable)
        defer { server.close() }
        return models(from: try server.request("model/list", ["limit": 100]))
    }
}
