// Read a chat's conversation for the in-app chat view: this Mac through the Rust worker's
// transcript child, other machines through a fixed read-only script over SSH, and a transcript
// file inside an allowed folder (Burro's cache of remote chats) through the same Rust parser.
// The worker keeps the parsed messages of the last few chats in memory and answers "unchanged"
// for a revision the caller already holds; nothing is written.
import Foundation

public struct ChatMessage: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Decodable { case user, assistant, tool }
    public var id: Int
    public var kind: Kind
    public var text: String
    public var tool: String?
    public var output: String?
    public var at: Date?
    /// A tool call's own one-line description (Claude's Bash and Agent write one).
    public var note: String?
    /// For a plan update: the whole plan as it stood after it.
    public var plan: [ChatPlanItem]?
    /// A reply you just sent from Burro that the chat's log doesn't show yet (see `ChatEchoes`).
    public var sending: Bool
    public init(id: Int, kind: Kind, text: String, tool: String? = nil, output: String? = nil, at: Date? = nil,
                note: String? = nil, plan: [ChatPlanItem]? = nil, sending: Bool = false) {
        self.id = id; self.kind = kind; self.text = text; self.tool = tool; self.output = output; self.at = at
        self.note = note; self.plan = plan; self.sending = sending
    }
}

public struct ChatPlanItem: Sendable, Equatable, Decodable {
    public enum Status: String, Sendable, Decodable { case pending, inProgress = "in_progress", completed }
    public var text: String
    public var status: Status
    public init(text: String, status: Status) { self.text = text; self.status = status }
}

public struct ChatTranscript: Sendable, Equatable {
    public var messages: [ChatMessage]
    /// Older messages exist that aren't shown.
    public var truncated: Bool
    public var title: String?
    public var folder: String?
    public var modified: Date?
    /// Tokens the latest turn had in context, and the model's window when the log records it (Codex does).
    public var contextTokens: Int?
    public var contextWindow: Int?
    public init(messages: [ChatMessage], truncated: Bool = false, title: String? = nil, folder: String? = nil, modified: Date? = nil,
                contextTokens: Int? = nil, contextWindow: Int? = nil) {
        self.messages = messages; self.truncated = truncated; self.title = title; self.folder = folder; self.modified = modified
        self.contextTokens = contextTokens; self.contextWindow = contextWindow
    }
}

struct TranscriptRequest: Encodable, Sendable {
    let provider: String
    let id: String
    let roots: [String]
    let limit: Int
    /// The revision the caller holds; the worker answers `unchanged` while the chat is still at it.
    var known: UInt64? = nil
}

/// A transcript file at `path`, which must lie inside `root` (see `ChatTranscripts.read(file:)`).
struct TranscriptFileRequest: Encodable, Sendable {
    let provider: String
    let path: String
    let root: String
    let limit: Int
    var known: UInt64? = nil
}

/// What a read found: the chat is still at the revision you hold, or its current messages.
public enum ChatTranscriptRead: Sendable, Equatable {
    case unchanged
    /// `revision` comes from the worker for chats on this Mac and cached files; nil for SSH reads.
    case loaded(ChatTranscript, revision: UInt64?)

    public var transcript: ChatTranscript? {
        if case .loaded(let transcript, _) = self { return transcript }
        return nil
    }
}

struct TranscriptBatch: Decodable, Sendable {
    struct Message: Decodable, Sendable {
        let kind: ChatMessage.Kind
        let text: String
        let tool: String?
        let output: String?
        let at: Double?
        let note: String?
        let plan: [ChatPlanItem]?
    }
    let found: Bool
    let messages: [Message]?
    let truncated: Bool?
    let title: String?
    let cwd: String?
    let modified: Double?
    let contextTokens: Int?
    let contextWindow: Int?
    /// Set by the worker (not the SSH script): identifies the parse state these messages came from.
    var revision: UInt64? = nil
    /// The chat is still at the revision the request named; no messages were sent.
    var unchanged: Bool? = nil

    func valid(for limit: Int) -> Bool {
        let messages = messages ?? []
        if unchanged == true && (!found || !messages.isEmpty || revision == nil) { return false }
        return messages.count <= limit && messages.allSatisfy {
            $0.text.count <= 12_001 && ($0.tool?.count ?? 0) <= 81 && ($0.output?.count ?? 0) <= 601 && ($0.at.map { $0.isFinite } ?? true)
                && ($0.note?.count ?? 0) <= 121 && ($0.plan?.count ?? 0) <= 30 && ($0.plan ?? []).allSatisfy { $0.text.count <= 201 }
        } && (title?.count ?? 0) <= 121 && (contextTokens ?? 0) >= 0 && (contextWindow ?? 0) >= 0
    }
    var transcript: ChatTranscript? {
        guard found else { return nil }
        return ChatTranscript(
            messages: (messages ?? []).enumerated().map { index, m in
                ChatMessage(id: index, kind: m.kind, text: m.text, tool: m.tool, output: m.output, at: m.at.map(Date.init(timeIntervalSince1970:)),
                            note: m.note, plan: m.plan)
            },
            truncated: truncated ?? false, title: title, folder: cwd, modified: modified.map(Date.init(timeIntervalSince1970:)),
            contextTokens: contextTokens, contextWindow: contextWindow)
    }
}

public enum ChatTranscripts {
    public enum LoadError: Error, Equatable, LocalizedError {
        case unsupported, notFound, unavailable(String)
        public var errorDescription: String? {
            switch self {
            case .unsupported: "This chat's transcript isn't something Burro can read."
            case .notFound: "Couldn't find this chat's transcript. It may have been archived or deleted."
            case .unavailable(let reason): reason
            }
        }
    }

    /// "codex:<uuid>", "claude:<uuid>", or either behind "remote:<host>:".
    public static func identity(of session: AgentSession) -> (provider: String, id: String)? {
        guard let parsed = identity(chatID: session.id), parsed.host == session.remote?.hostID else { return nil }
        return (parsed.provider, parsed.id)
    }
    public static func identity(chatID: String) -> (host: UUID?, provider: String, id: String)? {
        var id = chatID, host: UUID?
        if id.hasPrefix("remote:") {
            let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let hostID = UUID(uuidString: String(parts[1])) else { return nil }
            host = hostID; id = String(parts[2])
        }
        for provider in ["codex", "claude"] where id.hasPrefix(provider + ":") {
            let uuid = String(id.dropFirst(provider.count + 1)).lowercased()
            return UUID(uuidString: uuid) != nil ? (host, provider, uuid) : nil
        }
        return nil
    }

    /// The worker child that reads transcripts on this Mac. It is its own process, so reading a
    /// chat never waits behind a usage history scan, and its parse state survives between reads.
    static var worker: AgentLogWorker? { .transcripts }

    /// Loads a chat by its Burro id, finding the machine among `hosts` for remote chats.
    public static func load(chatID: String, hosts: [RemoteHost], profiles: [UsageProvider: String] = [:], limit: Int = 300) throws -> ChatTranscript {
        guard let (hostID, provider, id) = identity(chatID: chatID) else { throw LoadError.unsupported }
        if let hostID {
            guard let host = hosts.first(where: { $0.id == hostID }) else { throw LoadError.unavailable("That machine isn't configured any more.") }
            return try remote(provider: provider, id: id, host: host, limit: limit)
        }
        return try local(provider: provider, id: id, profiles: profiles, limit: limit, worker: worker)
    }

    /// Loads the latest `limit` messages. `host` is the remote machine for remote sessions.
    public static func load(_ session: AgentSession, host: RemoteHost?, profiles: [UsageProvider: String] = [:],
                            limit: Int = 300) throws -> ChatTranscript {
        guard let transcript = try read(session, host: host, profiles: profiles, limit: limit, after: nil).transcript else { throw LoadError.notFound }
        return transcript
    }

    /// Like `load`, for a view that refreshes: pass the revision of what you show and an untouched
    /// chat on this Mac answers `.unchanged` without sending its messages again. Remote chats are
    /// fetched in full each time (compare the result with what you show before assigning it).
    public static func read(_ session: AgentSession, host: RemoteHost?, profiles: [UsageProvider: String] = [:],
                            limit: Int = 300, after revision: UInt64?) throws -> ChatTranscriptRead {
        guard let (provider, id) = identity(of: session) else { throw LoadError.unsupported }
        if session.remote != nil {
            guard let host else { throw LoadError.unavailable("That machine isn't configured any more.") }
            return .loaded(try remote(provider: provider, id: id, host: host, limit: limit), revision: nil)
        }
        return try local(provider: provider, id: id, profiles: profiles, limit: limit, after: revision, worker: worker)
    }

    /// Reads a transcript file Burro keeps (a cached copy of a remote chat) with the same parser and
    /// limits as chats on this Mac. `path` must be an absolute path to a `.jsonl` file below `root`
    /// (at most eight folders down, no `.`/`..`), and `root`, every folder between and the file must
    /// belong to this user and none of them may be a symlink. `provider` picks the log format.
    /// Throws `.unsupported` for a path outside `root`, `.notFound` when the file is missing or
    /// refused (a symlink, someone else's, not a regular file) and `.unavailable` when the worker
    /// can't run. Replace a cached file by renaming a new one over it, or only append to it:
    /// the worker re-reads only what was added to a file it has seen.
    public static func read(file path: String, provider: AgentProvider, root: String, limit: Int = 300,
                            after revision: UInt64? = nil) throws -> ChatTranscriptRead {
        try read(file: path, provider: provider, root: root, limit: limit, after: revision, worker: worker)
    }

    /// `read(file:)` without a revision: the file's latest `limit` messages.
    public static func load(file path: String, provider: AgentProvider, root: String, limit: Int = 300) throws -> ChatTranscript {
        guard let transcript = try read(file: path, provider: provider, root: root, limit: limit, after: nil).transcript else { throw LoadError.notFound }
        return transcript
    }

    static func read(file path: String, provider: AgentProvider, root: String, limit: Int, after revision: UInt64?,
                     worker: AgentLogWorker?) throws -> ChatTranscriptRead {
        guard let worker else { throw LoadError.unavailable("Burro's log reader isn't available in this build.") }
        guard inside(path, root: root) else { throw LoadError.unsupported }
        let request = TranscriptFileRequest(provider: provider == .codex ? "codex" : "claude", path: path, root: root,
                                            limit: max(1, min(500, limit)), known: revision)
        guard let batch = worker.exchange([], transcriptFile: request)?.transcript else {
            throw LoadError.unavailable("Couldn't read the transcript right now.")
        }
        return try result(batch)
    }

    static func local(provider: String, id: String, profiles: [UsageProvider: String], limit: Int, worker: AgentLogWorker?) throws -> ChatTranscript {
        guard let transcript = try local(provider: provider, id: id, profiles: profiles, limit: limit, after: nil, worker: worker).transcript else {
            throw LoadError.notFound
        }
        return transcript
    }

    static func local(provider: String, id: String, profiles: [UsageProvider: String], limit: Int, after revision: UInt64?,
                      worker: AgentLogWorker?) throws -> ChatTranscriptRead {
        guard let worker else { throw LoadError.unavailable("Burro's log reader isn't available in this build.") }
        let roots = LocalUsageScanner.roots(provider: provider == "codex" ? .codex : .claude,
                                            profile: profiles[provider == "codex" ? .codex : .claude]).map(\.path)
        let request = TranscriptRequest(provider: provider, id: id, roots: roots, limit: limit, known: revision)
        guard let batch = worker.exchange([], transcript: request)?.transcript else {
            throw LoadError.unavailable("Couldn't read the transcript right now.")
        }
        return try result(batch)
    }

    /// `path` names a `.jsonl` file below `root` without `.`/`..` or empty parts (the worker checks
    /// the folders and the file themselves). Checked here so a bad path never reaches the worker.
    static func inside(_ path: String, root: String) -> Bool {
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard base.hasPrefix("/"), base.count > 1, path.hasPrefix(base + "/"), path.hasSuffix(".jsonl"),
              path.utf8.count <= 4096, base.utf8.count <= 4096, !path.contains("\0") else { return false }
        let names = path.dropFirst(base.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        return (1...9).contains(names.count) && names.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            && (names.last?.count ?? 0) > 6
    }

    private static func result(_ batch: TranscriptBatch) throws -> ChatTranscriptRead {
        if batch.unchanged == true { return .unchanged }
        guard let transcript = batch.transcript else { throw LoadError.notFound }
        return .loaded(transcript, revision: batch.revision)
    }

    static func remote(provider: String, id: String, host: RemoteHost, limit: Int) throws -> ChatTranscript {
        guard host.enabled, host.validationError == nil,
              let url = Bundle.module.url(forResource: "remote_transcript", withExtension: "py"),
              let body = try? String(contentsOf: url, encoding: .utf8) else { throw LoadError.unavailable("That machine can't be reached from Burro.") }
        // Only validated values reach the script: a provider name, a UUID and a number.
        let request = try JSONEncoder().encode(["provider": provider, "id": id])
        let line = "REQUEST = " + String(decoding: request, as: UTF8.self).dropLast() + ", \"limit\": \(max(1, min(500, limit)))}\n"
        let result = CommandRunner().run("/usr/bin/ssh", RemoteAgentMonitor.arguments(for: host), timeout: 25, input: Data((line + body).utf8))
        guard result.succeeded else {
            throw LoadError.unavailable(result.timedOut ? "\(host.name) didn't answer in time." : "Couldn't reach \(host.name) over SSH.")
        }
        guard let batch = try? JSONDecoder().decode(TranscriptBatch.self, from: Data(result.output.utf8)), batch.valid(for: limit) else {
            throw LoadError.unavailable("\(host.name) sent a transcript Burro doesn't understand.")
        }
        guard let transcript = batch.transcript else { throw LoadError.notFound }
        return transcript
    }
}
