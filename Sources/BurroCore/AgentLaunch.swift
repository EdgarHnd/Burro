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
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .notInstalled(let provider): "\(provider.title) isn't installed on this Mac."
        case .emptyPrompt: "Write what the agent should do."
        case .missingFolder: "That project folder no longer exists."
        case .untrusted(let folder): "Claude hasn't been trusted in \(URL(fileURLWithPath: folder).lastPathComponent) yet. Run claude there once in Terminal and accept the prompt, then try again."
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
    public static func start(_ request: LaunchRequest, executable: String? = executable()) throws -> LaunchResult {
        guard let executable else { throw LaunchError.notInstalled(.claude) }
        guard FileManager.default.fileExists(atPath: request.folder) else { throw LaunchError.missingFolder }
        let result = try LaunchShell.run(executable, arguments(for: request), folder: request.folder, timeout: 60)
        let output = result.text
        if output.contains("Workspace not trusted") { throw LaunchError.untrusted(request.folder) }
        guard result.code == 0, let handle = handle(fromOutput: output) else {
            let line = output.split(whereSeparator: \.isNewline).map(String.init).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            throw LaunchError.failed(line.map { "Claude didn't start: \($0)" } ?? "Claude didn't start.")
        }
        let agents = try? LaunchShell.run(executable, ["agents", "--json", "--all"], folder: request.folder, timeout: 20)
        let session = agents.flatMap { sessionID(handle: handle, agentsJSON: Data($0.text.utf8)) } ?? handle
        return LaunchResult(provider: .claude, sessionID: session, handle: handle, folder: request.folder)
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
