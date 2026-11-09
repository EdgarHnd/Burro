// Read a chat's conversation for the in-app chat view: this Mac through the Rust history worker,
// other machines through a fixed read-only script over SSH. Messages are held in memory for
// display only; nothing is cached or written.
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
    public init(id: Int, kind: Kind, text: String, tool: String? = nil, output: String? = nil, at: Date? = nil,
                note: String? = nil, plan: [ChatPlanItem]? = nil) {
        self.id = id; self.kind = kind; self.text = text; self.tool = tool; self.output = output; self.at = at
        self.note = note; self.plan = plan
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

    func valid(for limit: Int) -> Bool {
        let messages = messages ?? []
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

    /// Loads a chat by its Burro id, finding the machine among `hosts` for remote chats.
    public static func load(chatID: String, hosts: [RemoteHost], profiles: [UsageProvider: String] = [:], limit: Int = 300) throws -> ChatTranscript {
        guard let (hostID, provider, id) = identity(chatID: chatID) else { throw LoadError.unsupported }
        if let hostID {
            guard let host = hosts.first(where: { $0.id == hostID }) else { throw LoadError.unavailable("That machine isn't configured any more.") }
            return try remote(provider: provider, id: id, host: host, limit: limit)
        }
        return try local(provider: provider, id: id, profiles: profiles, limit: limit, worker: .usage)
    }

    /// Loads the latest `limit` messages. `host` is the remote machine for remote sessions.
    public static func load(_ session: AgentSession, host: RemoteHost?, profiles: [UsageProvider: String] = [:],
                            limit: Int = 300) throws -> ChatTranscript {
        guard let (provider, id) = identity(of: session) else { throw LoadError.unsupported }
        if session.remote != nil {
            guard let host else { throw LoadError.unavailable("That machine isn't configured any more.") }
            return try remote(provider: provider, id: id, host: host, limit: limit)
        }
        return try local(provider: provider, id: id, profiles: profiles, limit: limit, worker: .usage)
    }

    static func local(provider: String, id: String, profiles: [UsageProvider: String], limit: Int, worker: AgentLogWorker?) throws -> ChatTranscript {
        guard let worker else { throw LoadError.unavailable("Burro's log reader isn't available in this build.") }
        let roots = LocalUsageScanner.roots(provider: provider == "codex" ? .codex : .claude,
                                            profile: profiles[provider == "codex" ? .codex : .claude]).map(\.path)
        guard let batch = worker.exchange([], transcript: TranscriptRequest(provider: provider, id: id, roots: roots, limit: limit))?.transcript else {
            throw LoadError.unavailable("Couldn't read the transcript right now.")
        }
        guard let transcript = batch.transcript else { throw LoadError.notFound }
        return transcript
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
