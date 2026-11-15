// Starting a chat on another machine, and the folders one can start in there. Every start is an
// explicit action of yours: the New chat sheet's Start on another machine calls it (the ⌘K palette
// only opens that sheet). A start whose answer never came back (the SSH call timed out) is reported
// as not confirmed rather than failed, because the chat may be running there anyway.
//
// Every call goes over SSH with remote monitoring's strict options to a fixed Python script, the
// request travelling as base64 JSON on stdin, so no folder, prompt or name reaches a remote shell.
// Folders: `remote_folders.py` lists candidates (Claude's projects with their trust flag, Codex and
// recent Claude working folders, git facts read from files) and validates a typed path; results are
// remembered in that machine's host.json.
// Codex: after the folder validates, the same `thread/start` + `turn/start` as a local launch, over
// `codex app-server proxy` on that machine; the chat keeps running in its daemon.
// Claude: `remote_launch.py` checks trust (read-only; Burro never trusts a folder for you), starts
// `claude --bg` through the login shell detached from the SSH channel, and returns the same evidence
// the local start check reads. `ClaudeLaunch.startCheck` and `pendingPrompt` then decide, so a remote
// start counts only when its transcript exists, exactly as on this Mac.
import Foundation

public struct RemoteFolder: Codable, Sendable, Equatable, Identifiable {
    public struct Git: Codable, Sendable, Equatable {
        public var root: String
        public var branch: String?
        /// A linked worktree (its `.git` file points into another repository's `worktrees/`).
        public var worktree: Bool
    }
    public var path: String
    public var exists: Bool
    /// Claude has been trusted here (or in a folder above it).
    public var trusted: Bool
    /// Where it was found: "claude" (projects in ~/.claude.json), "codex", "claudeSession".
    public var sources: [String]
    public var lastUsed: Date?
    public var git: Git?
    public var id: String { path }
}

public struct RemoteFolderList: Codable, Sendable, Equatable {
    public var folders: [RemoteFolder]
    public var truncated: Bool
    public var warnings: [String]
    public var listedAt: Date
}

/// A typed folder that passed validation on that machine.
public struct RemoteFolderCheck: Sendable, Equatable {
    /// The real path (links resolved).
    public var path: String
    public var trusted: Bool
    public var git: RemoteFolder.Git?
}

public struct RemoteLaunchResult: Sendable, Equatable {
    public var launch: LaunchResult
    public var hostID: UUID
    /// The id the Chats page opens: "remote:<host id>:codex:<thread>" or "…:claude:<session>".
    public var chatID: String
}

public enum RemoteLaunchError: Error, Equatable, LocalizedError {
    case unreachable(host: String)
    case claudeNotInstalled(host: String)
    case codexNotInstalled(host: String)
    case codexNotStandalone(host: String, detail: String)
    case untrusted(host: String, folder: String)
    case folder(host: String, reason: String)
    /// Registered but stopped at a terminal prompt before its first turn; Burro removed it.
    case blocked(host: String, folder: String, reason: String)
    /// Claude printed a background id but the session never confirmed; Burro removed it.
    case unconfirmed(host: String, handle: String?)
    /// The machine didn't answer a call in time.
    case timedOut(host: String)
    /// A start was sent but its answer never came back; the chat may have started anyway.
    case notConfirmed(host: String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let host): "Couldn't reach \(host) over SSH."
        case .claudeNotInstalled(let host): "Claude Code isn't installed on \(host)."
        case .codexNotInstalled(let host): "Codex isn't installed on \(host)."
        case .codexNotStandalone(_, let detail): detail
        case .untrusted(let host, let folder):
            "Claude hasn't been trusted in \(Self.name(folder)) on \(host) yet. Run claude there once in Terminal and accept the prompt, then try again."
        case .folder(let host, let reason): "\(reason.hasSuffix(".") ? String(reason.dropLast()) : reason) (\(host))."
        case .blocked(let host, let folder, let reason):
            "The chat did not start. Claude Code stopped at a prompt in \(Self.name(folder)) on \(host) before its first turn: \(reason). "
                + "Burro removed that stuck session. Run claude in that folder once in Terminal on \(host), answer the prompt, then start the chat again."
        case .unconfirmed(let host, let handle):
            "The chat did not start on \(host). Claude Code printed a background id\(handle.map { " (\($0))" } ?? "") but the session never wrote a transcript within 20 seconds, so Burro removed it."
        case .timedOut(let host): "\(host) didn't answer in time."
        case .notConfirmed(let host):
            "Burro asked \(host) to start the chat but didn't hear back in time. It may have started anyway; if it did, it appears at the next check."
        case .failed(let message): message
        }
    }
    private static func name(_ folder: String) -> String { URL(fileURLWithPath: folder).lastPathComponent }
}

/// The two Codex app-server calls a launch needs; `CodexAppServer` in the app, a recorder in tests.
protocol CodexRPC: AnyObject {
    func request(_ method: String, _ params: [String: Any]) throws -> [String: Any]
    func close()
}
extension CodexAppServer: CodexRPC {}

public enum RemoteLaunch {
    /// Runs a fixed script on the machine and returns its stdout.
    typealias Runner = (_ script: String, _ request: [String: Any], _ timeout: Double) throws -> Data

    // MARK: SSH

    /// What runs for a script call: `/usr/bin/ssh` with remote monitoring's strict arguments (ending in
    /// the fixed remote command `python3 -`) and, on stdin, the request line followed by the script.
    static func invocation(_ script: String, request: [String: Any], host: RemoteHost) throws -> (arguments: [String], input: Data) {
        guard let url = RemoteScript.url(script), let body = try? Data(contentsOf: url) else {
            throw RemoteLaunchError.failed("This build of Burro is missing \(script).py.")
        }
        let encoded = try JSONSerialization.data(withJSONObject: request).base64EncodedString()
        var input = Data("REQUEST_B64 = \"\(encoded)\"\n".utf8)
        input.append(body)
        return (RemoteAgentMonitor.arguments(for: host), input)
    }
    static func runner(_ host: RemoteHost) -> Runner {
        { script, request, timeout in
            guard host.enabled, host.validationError == nil else { throw RemoteLaunchError.unreachable(host: host.name) }
            let call = try invocation(script, request: request, host: host)
            let result = CommandRunner().run("/usr/bin/ssh", call.arguments, timeout: timeout, input: call.input)
            if result.timedOut { throw RemoteLaunchError.timedOut(host: host.name) }
            if result.code == 255 { throw RemoteLaunchError.unreachable(host: host.name) }
            guard result.code == 0 else {
                let line = result.error.split(whereSeparator: \.isNewline).last.map { String($0.prefix(300)) }
                throw RemoteLaunchError.failed(line ?? "\(host.name) refused the request.")
            }
            return Data(result.output.utf8)
        }
    }
    static func object(_ data: Data, host: RemoteHost) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteLaunchError.failed("\(host.name) didn't answer as expected. Python 3 is required there.")
        }
        return object
    }
    /// A script's refusal as an error value.
    static func refusal(_ object: [String: Any], host: RemoteHost, folder: String) -> RemoteLaunchError {
        let message = (object["error"] as? String).map { String($0.prefix(400)) } ?? "\(host.name) refused the request."
        switch object["code"] as? String {
        case "notInstalled": return .claudeNotInstalled(host: host.name)
        case "untrusted": return .untrusted(host: host.name, folder: object["folder"] as? String ?? folder)
        case "folder", "missing", "notDirectory", "notOwned": return .folder(host: host.name, reason: message)
        case "invalid": return .failed("Burro sent a request \(host.name) won't run.")
        default: return .failed(message)
        }
    }
    public static func chatID(hostID: UUID, provider: LaunchProvider, sessionID: String) -> String {
        "remote:\(hostID.uuidString):\(provider.rawValue):\(sessionID)"
    }

    // MARK: Folders

    /// Folders a chat can start in on that machine (slow: call off the main thread). Remembered in host.json.
    public static func folders(host: RemoteHost, cache: RemoteCache = .shared) throws -> RemoteFolderList {
        try folders(host: host, cache: cache, now: Date(), run: runner(host))
    }
    static func folders(host: RemoteHost, cache: RemoteCache, now: Date, run: Runner) throws -> RemoteFolderList {
        let data = try run("remote_folders", ["op": "list"], 20)
        let object = try object(data, host: host)
        guard object["ok"] as? Bool == true else { throw refusal(object, host: host, folder: "") }
        struct Response: Decodable { var version: Int; var folders: [RemoteFolder]; var truncated: Bool; var warnings: [String] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        guard let response = try? decoder.decode(Response.self, from: data), response.version == 1 else {
            throw RemoteLaunchError.failed("\(host.name) didn't answer as expected.")
        }
        let list = RemoteFolderList(folders: Array(response.folders.prefix(300)), truncated: response.truncated,
                                    warnings: Array(response.warnings.prefix(20)), listedAt: now)
        try? cache.update(host, now: now) { $0.folders = list }
        return list
    }
    /// The folder list remembered from the last listing, if any.
    public static func cachedFolders(host: RemoteHost, cache: RemoteCache = .shared) -> RemoteFolderList? {
        cache.load(host)?.folders
    }

    /// Checks a typed folder on that machine: absolute, a real directory after resolving links, owned
    /// by you. Also reports Claude's trust flag. A valid folder is added to the remembered list.
    public static func validate(host: RemoteHost, path: String, cache: RemoteCache = .shared) throws -> RemoteFolderCheck {
        try validate(host: host, path: path, cache: cache, now: Date(), run: runner(host))
    }
    static func validate(host: RemoteHost, path: String, cache: RemoteCache, now: Date, run: Runner) throws -> RemoteFolderCheck {
        guard path.hasPrefix("/") else { throw RemoteLaunchError.folder(host: host.name, reason: "Enter an absolute folder path.") }
        let data = try run("remote_folders", ["op": "validate", "path": path], 20)
        let object = try object(data, host: host)
        guard object["ok"] as? Bool == true else { throw refusal(object, host: host, folder: path) }
        struct Response: Decodable { var path: String; var trusted: Bool; var git: RemoteFolder.Git? }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), response.path.hasPrefix("/") else {
            throw RemoteLaunchError.failed("\(host.name) didn't answer as expected.")
        }
        let check = RemoteFolderCheck(path: response.path, trusted: response.trusted, git: response.git)
        try? cache.update(host, now: now) { value in
            var list = value.folders ?? RemoteFolderList(folders: [], truncated: false, warnings: [], listedAt: now)
            list.folders.removeAll { $0.path == check.path }
            list.folders.insert(RemoteFolder(path: check.path, exists: true, trusted: check.trusted, sources: ["typed"],
                                             lastUsed: now, git: check.git), at: 0)
            list.folders = Array(list.folders.prefix(300))
            value.folders = list
        }
        return check
    }

    // MARK: Claude

    /// Whether a Claude chat could start in `folder` on that machine (installed, real folder you own,
    /// trusted). Launches nothing.
    public static func checkClaude(folder: String, host: RemoteHost) throws -> RemoteFolderCheck {
        try checkClaude(folder: folder, host: host, run: runner(host))
    }
    static func checkClaude(folder: String, host: RemoteHost, run: Runner) throws -> RemoteFolderCheck {
        let object = try object(try run("remote_launch", ["op": "check", "folder": folder, "args": [String]()], 30), host: host)
        guard object["ok"] as? Bool == true, let path = object["folder"] as? String else { throw refusal(object, host: host, folder: folder) }
        return RemoteFolderCheck(path: path, trusted: object["trusted"] as? Bool == true, git: nil)
    }

    /// Starts `claude --bg` in the request's folder on that machine (slow: call off the main thread; the
    /// script's own bounds — 60 s launch, 20 s verify, 20 s per cleanup call — fit inside the 180 s wait).
    public static func startClaude(_ request: LaunchRequest, host: RemoteHost) throws -> RemoteLaunchResult {
        try startClaude(request, host: host, run: runner(host))
    }
    static func startClaude(_ request: LaunchRequest, host: RemoteHost, run: Runner) throws -> RemoteLaunchResult {
        guard request.provider == .claude else { throw RemoteLaunchError.failed("Not a Claude Code request.") }
        guard !request.trimmedPrompt.isEmpty else { throw LaunchError.emptyPrompt }
        guard request.trimmedPrompt.count <= 100_000 else { throw RemoteLaunchError.failed("That prompt is too long.") }
        guard request.folder.hasPrefix("/") else { throw RemoteLaunchError.folder(host: host.name, reason: "Choose a folder on \(host.name).") }
        for value in [request.model, request.effort].compactMap({ $0 }) where !value.isEmpty && !ChatReply.valid(value) {
            throw RemoteLaunchError.failed("“\(value.prefix(40))” isn't a model or effort name Burro can send.")
        }
        let data: Data
        do {
            data = try run("remote_launch", ["op": "start", "folder": request.folder, "args": ClaudeLaunch.arguments(for: request)], 180)
        } catch RemoteLaunchError.timedOut(let name) {
            throw RemoteLaunchError.notConfirmed(host: name)
        }
        return try decide(try object(data, host: host), request: request, host: host)
    }

    /// Turns the launch script's evidence into a result, through the same checks as a local start.
    static func decide(_ evidence: [String: Any], request: LaunchRequest, host: RemoteHost) throws -> RemoteLaunchResult {
        guard evidence["ok"] as? Bool == true else { throw refusal(evidence, host: host, folder: request.folder) }
        let folder = evidence["folder"] as? String ?? request.folder
        guard let handle = evidence["handle"] as? String, handle.range(of: #"^[0-9a-f]{6,36}$"#, options: .regularExpression) != nil else {
            throw RemoteLaunchError.unconfirmed(host: host.name, handle: nil)
        }
        let facts = (evidence["transcripts"] as? [[String: Any]] ?? []).compactMap { row -> (cwd: String, session: String)? in
            guard row["exists"] as? Bool == true, let cwd = row["cwd"] as? String, let session = row["session"] as? String else { return nil }
            return (cwd, session.lowercased())
        }
        let check = ClaudeLaunch.startCheck(handle: handle, folder: folder,
                                            agentsJSON: (evidence["agents"] as? String).map { Data($0.utf8) },
                                            jobJSON: (evidence["job"] as? String).map { Data($0.utf8) }) { cwd, session in
            facts.contains { $0.cwd == cwd && $0.session == session }
        }
        switch check {
        case .started(let session):
            // The script removes anything it didn't see start; a disagreement is never reported as started.
            guard evidence["discarded"] as? Bool != true else { throw RemoteLaunchError.unconfirmed(host: host.name, handle: handle) }
            let launch = LaunchResult(provider: .claude, sessionID: session, handle: handle, folder: folder)
            return RemoteLaunchResult(launch: launch, hostID: host.id, chatID: chatID(hostID: host.id, provider: .claude, sessionID: session))
        case .blocked(let reason):
            throw RemoteLaunchError.blocked(host: host.name, folder: folder, reason: reason)
        case .ended(let state):
            throw RemoteLaunchError.failed("The chat did not start on \(host.name). Claude Code's background session \(handle) ended (\(state)) before its first turn, so Burro removed it.")
        case .pending:
            if let prompt = ClaudeLaunch.pendingPrompt(inLogs: evidence["logs"] as? String ?? "") {
                throw RemoteLaunchError.blocked(host: host.name, folder: folder, reason: prompt)
            }
            throw RemoteLaunchError.unconfirmed(host: host.name, handle: handle)
        }
    }

    // MARK: Codex

    /// Starts a Codex chat in its daemon on that machine (slow: call off the main thread).
    public static func startCodex(_ request: LaunchRequest, host: RemoteHost) throws -> RemoteLaunchResult {
        let run = runner(host)
        return try startCodex(request, host: host,
                              validate: { try validate(host: host, path: $0, cache: .shared, now: Date(), run: run) },
                              connect: { try CodexAppServer.remote($0) })
    }
    static func startCodex(_ request: LaunchRequest, host: RemoteHost, validate: (String) throws -> RemoteFolderCheck,
                           connect: (RemoteHost) throws -> CodexRPC) throws -> RemoteLaunchResult {
        guard request.provider == .codex else { throw RemoteLaunchError.failed("Not a Codex request.") }
        guard !request.trimmedPrompt.isEmpty else { throw LaunchError.emptyPrompt }
        guard request.trimmedPrompt.count <= 100_000 else { throw RemoteLaunchError.failed("That prompt is too long.") }
        var request = request
        request.folder = try validate(request.folder).path
        let server: CodexRPC
        do { server = try connect(host) } catch { throw codexProblem(error, host: host) }
        defer { server.close() }
        let thread = try server.request("thread/start", CodexLaunch.threadParams(for: request))
        guard let id = (thread["thread"] as? [String: Any])?["id"] as? String, UUID(uuidString: id) != nil else {
            throw RemoteLaunchError.failed("Codex on \(host.name) didn't create a thread.")
        }
        _ = try server.request("turn/start", CodexLaunch.turnParams(threadID: id, for: request))
        let launch = LaunchResult(provider: .codex, sessionID: id, handle: nil, folder: request.folder)
        return RemoteLaunchResult(launch: launch, hostID: host.id, chatID: chatID(hostID: host.id, provider: .codex, sessionID: id))
    }
    /// Codex's connection problem (worded by `CodexAppServer.remoteProblem`) as an error value.
    static func codexProblem(_ error: Error, host: RemoteHost) -> RemoteLaunchError {
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        if message.contains("over SSH") || message.contains("can't be reached from Burro") { return .unreachable(host: host.name) }
        if message.contains("isn't installed") { return .codexNotInstalled(host: host.name) }
        if message.contains("standalone") { return .codexNotStandalone(host: host.name, detail: message) }
        return .failed(message)
    }

    /// Codex models on that machine, remembered in host.json for when it is asleep.
    public static func codexModels(host: RemoteHost, cache: RemoteCache = .shared) throws -> [LaunchModel] {
        let models = try ChatReply.codexModels(host: host)
        try? cache.update(host) { $0.codexModels = models.map(RemoteCodexModel.init) }
        return models
    }
    public static func cachedCodexModels(host: RemoteHost, cache: RemoteCache = .shared) -> [LaunchModel]? {
        cache.load(host)?.codexModels?.map(\.launchModel)
    }
}
