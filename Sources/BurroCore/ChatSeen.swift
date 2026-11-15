// "Seen in Burro": opening a chat on Burro's Chats page (or "Mark as read here") records the
// chat's activity time. A finished chat with an unread result that you have seen at or after its
// latest activity stops counting as ready to read in Burro (the Chats list, its badge, Home and
// the notch). Only Burro's own copy of the session changes: the providers' unread markers are
// never written. New activity makes it unread again. Saved in Burro's preferences (`chats.seen`),
// at most 2,000 chats, a damaged value reads as empty. A chat is marked seen only while you are
// there: the Chats page shows it in Burro's key window and Burro is the active app (`marks`).
// "Seen" changes only what Burro shows as unread: notifications and triage judge the sessions as
// sampled (`copies`), so a chat that finishes while Burro merely sits on screen still alerts.
import Foundation

public struct ChatSeen: Codable, Sendable, Equatable {
    public var seen: [String: Date] = [:]
    public init() {}
    static let limit = 2000

    public func isSeen(_ session: AgentSession) -> Bool { seen[session.id].map { $0 >= session.updatedAt } ?? false }

    /// Records the chat as seen at its current activity time. False when nothing changed.
    @discardableResult
    public mutating func mark(_ session: AgentSession) -> Bool {
        if let current = seen[session.id], current >= session.updatedAt { return false }
        seen[session.id] = session.updatedAt
        if seen.count > Self.limit {
            seen = Dictionary(uniqueKeysWithValues: seen.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(Self.limit).map { ($0.key, $0.value) })
        }
        return true
    }

    /// Burro's copy of each session, with results you've seen here no longer unread.
    public func applying(_ sessions: [AgentSession]) -> [AgentSession] {
        guard !seen.isEmpty else { return sessions }
        return sessions.map { session in
            guard session.hasUnreadResult == true, isSeen(session) else { return session }
            var value = session; value.hasUnreadResult = false; return value
        }
    }

    /// Whether a chat on screen counts as seen now: only on the Chats page, in a window that is
    /// visible and key, while Burro is the active app.
    public static func marks(onChatsPage: Bool, windowVisible: Bool, windowKey: Bool, appActive: Bool) -> Bool {
        onChatsPage && windowVisible && windowKey && appActive
    }

    /// Burro's two copies of the sampled sessions, both with Burro-only titles: `display` with
    /// results seen here no longer unread (lists, badges, Home, the notch), `attention` with every
    /// result as sampled (notifications and triage).
    public func copies(_ sessions: [AgentSession], manage: ChatManage) -> (display: [AgentSession], attention: [AgentSession]) {
        (manage.applyingTitles(applying(sessions)), manage.applyingTitles(sessions))
    }

    public static func decode(_ data: Data?) -> ChatSeen {
        guard let data else { return ChatSeen() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(ChatSeen.self, from: data)) ?? ChatSeen()
    }
    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(self)
    }
}
