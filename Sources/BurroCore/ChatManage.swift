// Managing chats from Burro: rename, archive or hide, pin to top. Codex chats are renamed and
// archived in Codex itself (`thread/name/set`, `thread/archive`, both in its app-server schema);
// Claude has no command for either, so a Claude chat gets a Burro-only title and "Hide in Burro".
// Pins are Burro-only for both. A hidden chat comes back by itself when it has new activity.
// Saved in Burro's preferences (`chats.manage`); every list is capped and a damaged value reads
// as empty.
import Foundation

public struct ChatManage: Codable, Sendable, Equatable {
    /// Burro-only titles by chat id.
    public var titles: [String: String] = [:]
    /// Pinned chats and when they were pinned (earlier pins stay higher).
    public var pinned: [String: Date] = [:]
    /// Hidden chats and the activity time they had when hidden.
    public var hidden: [String: Date] = [:]
    public init() {}

    static let limit = 500, titleLimit = 200

    public func title(for id: String) -> String? { titles[id] }
    public func isPinned(_ id: String) -> Bool { pinned[id] != nil }
    /// Hidden until the chat moves on: anything newer than when you hid it shows it again.
    public func isHidden(_ session: AgentSession) -> Bool { hidden[session.id].map { session.updatedAt <= $0 } ?? false }

    /// Sets or (when empty) clears the Burro-only title.
    public mutating func rename(_ id: String, to title: String) {
        let clean = title.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        titles[id] = clean.isEmpty ? nil : String(clean.prefix(Self.titleLimit))
        titles = Self.capped(titles)
    }
    public mutating func setPinned(_ id: String, _ value: Bool, now: Date) {
        pinned[id] = value ? (pinned[id] ?? now) : nil
        pinned = Self.capped(pinned)
    }
    public mutating func hide(_ session: AgentSession) {
        hidden[session.id] = session.updatedAt
        pinned[session.id] = nil
        hidden = Self.capped(hidden)
    }
    public mutating func unhide(_ id: String) { hidden[id] = nil }

    /// Burro-only titles applied to chats.
    public func applyingTitles(_ sessions: [AgentSession]) -> [AgentSession] {
        guard !titles.isEmpty else { return sessions }
        return sessions.map { session in
            guard let title = titles[session.id] else { return session }
            var value = session; value.title = title; return value
        }
    }

    /// For a chat list: hidden chats left out, pinned chats first (in pin order), the rest as given.
    public func arrange(_ sessions: [AgentSession]) -> [AgentSession] {
        let visible = sessions.filter { !isHidden($0) }
        let pins = visible.filter { pinned[$0.id] != nil }.sorted { (pinned[$0.id]!, $0.id) < (pinned[$1.id]!, $1.id) }
        return pins + visible.filter { pinned[$0.id] == nil }
    }

    static func capped<V>(_ values: [String: V]) -> [String: V] {
        values.count <= limit ? values : Dictionary(uniqueKeysWithValues: values.sorted { $0.key < $1.key }.suffix(limit).map { ($0.key, $0.value) })
    }

    public static func decode(_ data: Data?) -> ChatManage {
        guard let data else { return ChatManage() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(ChatManage.self, from: data)) ?? ChatManage()
    }
    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(self)
    }
}

/// The provider side of managing: Codex only, built as plain requests and run on an explicit click.
public enum ChatProviderManage {
    static func codexRenameParams(threadID: String, name: String) -> [String: Any]? {
        let clean = name.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean.count <= ChatManage.titleLimit else { return nil }
        return ["threadId": threadID, "name": clean]
    }
    static func codexArchiveParams(threadID: String) -> [String: Any] { ["threadId": threadID] }

    /// Codex's own thread id for a Codex chat Burro can reach, else nil.
    public static func codexThread(_ session: AgentSession) -> String? {
        guard session.provider == .codex, let (provider, id) = ChatTranscripts.identity(of: session), provider == "codex" else { return nil }
        return id
    }

    /// Renames the thread in Codex (it shows there and in Burro).
    public static func rename(_ session: AgentSession, to name: String, host: RemoteHost?) throws {
        guard let id = codexThread(session) else { throw LaunchError.failed("Only Codex chats can be renamed in their app.") }
        guard let params = codexRenameParams(threadID: id, name: name) else { throw LaunchError.failed("Enter a name of up to \(ChatManage.titleLimit) characters.") }
        if session.remote != nil && host == nil { throw LaunchError.failed("That machine isn't configured in Burro any more.") }
        let server = try ChatReply.codexServer(host)
        defer { server.close() }
        _ = try server.request("thread/name/set", params)
    }

    /// Archives the thread in Codex (Codex can unarchive it).
    public static func archive(_ session: AgentSession, host: RemoteHost?) throws {
        guard let id = codexThread(session) else { throw LaunchError.failed("Only Codex chats can be archived in their app.") }
        if session.remote != nil && host == nil { throw LaunchError.failed("That machine isn't configured in Burro any more.") }
        let server = try ChatReply.codexServer(host)
        defer { server.close() }
        _ = try server.request("thread/archive", codexArchiveParams(threadID: id))
    }
}
