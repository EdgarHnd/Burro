// The Orchestrator's conversations, one per local day: the first question of a day starts a fresh
// Claude session (so context never grows without bound), later questions that day resume it, and
// earlier days stay listed so their conversations can be read back. "New conversation" replaces the
// day's session with a fresh one; the replaced one stays listed under the same day. Kept as a small
// JSON list in Burro's preferences, newest last, for 30 days.
import Foundation

public struct OrchestratorDaySession: Codable, Sendable, Equatable, Identifiable {
    /// The local day, `yyyy-MM-dd`; empty for a conversation from before sessions were kept per day.
    public var day: String
    public var sessionID: String
    public var startedAt: Date?
    public var id: String { sessionID }
    public init(day: String, sessionID: String, startedAt: Date? = nil) {
        self.day = day; self.sessionID = sessionID; self.startedAt = startedAt
    }
}

public enum OrchestratorSessions {
    public static let keepDays = 30

    /// The session for a question asked on `day`: today's latest (resumed) or, on a new day or when
    /// `fresh` (you started a new conversation), a new one added to the list.
    public static func session(for day: String, in sessions: [OrchestratorDaySession], fresh: Bool = false,
                               newID: () -> String = { UUID().uuidString.lowercased() },
                               now: Date = Date()) -> (sessionID: String, resume: Bool, sessions: [OrchestratorDaySession]) {
        if !fresh, let current = sessions.last(where: { $0.day == day }) { return (current.sessionID, true, sessions) }
        let fresh = OrchestratorDaySession(day: day, sessionID: newID(), startedAt: now)
        return (fresh.sessionID, false, prune(sessions + [fresh], today: day))
    }

    /// Today's conversation, if one was started.
    public static func current(_ sessions: [OrchestratorDaySession], day: String) -> OrchestratorDaySession? {
        sessions.last { $0.day == day }
    }

    /// Replaces the id Claude reported for a session (it can differ from the one asked for).
    public static func rename(_ old: String, to new: String, in sessions: [OrchestratorDaySession]) -> [OrchestratorDaySession] {
        sessions.map { var copy = $0; if copy.sessionID == old { copy.sessionID = new }; return copy }
    }

    /// Drops a session (it was lost, or you started over); the next question starts a fresh one.
    public static func drop(_ id: String, from sessions: [OrchestratorDaySession]) -> [OrchestratorDaySession] {
        sessions.filter { $0.sessionID != id }
    }

    /// Keeps the last 30 days (and the conversation from before daily sessions, until it ages out).
    public static func prune(_ sessions: [OrchestratorDaySession], today: String) -> [OrchestratorDaySession] {
        let all = Array(sessions.suffix(200))
        let days = Array(Set(all.map(\.day).filter { !$0.isEmpty && $0 <= today })).sorted().suffix(keepDays)
        let undated = all.filter { $0.day.isEmpty }
        return (all.count > keepDays ? undated.suffix(1) : undated) + all.filter { days.contains($0.day) }
    }

    /// Earlier conversations to read back (every one but today's current), newest first.
    public static func earlier(_ sessions: [OrchestratorDaySession], today: String) -> [OrchestratorDaySession] {
        let current = self.current(sessions, day: today)?.sessionID
        return sessions.filter { $0.sessionID != current }.reversed()
    }

    /// Moves the single session Burro used to resume forever into the list, as an undated entry.
    public static func migrate(legacy: String?, into sessions: [OrchestratorDaySession]) -> [OrchestratorDaySession] {
        guard let legacy, !legacy.isEmpty, !sessions.contains(where: { $0.sessionID == legacy }) else { return sessions }
        return [OrchestratorDaySession(day: "", sessionID: legacy)] + sessions
    }

    /// "Today", "Yesterday", "Tue 12 Nov", or "Before daily conversations" for the undated one.
    public static func title(day: String, today: Date = Date(), calendar: Calendar = .current) -> String {
        guard !day.isEmpty else { return "Before daily conversations" }
        if day == TodoDay.key(today, calendar: calendar) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == TodoDay.key(yesterday, calendar: calendar) { return "Yesterday" }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = calendar
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return day }
        parser.dateFormat = "EEE d MMM"
        return parser.string(from: date)
    }

    public static func encode(_ sessions: [OrchestratorDaySession]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(sessions)
    }
    public static func decode(_ data: Data?) -> [OrchestratorDaySession] {
        guard let data else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([OrchestratorDaySession].self, from: data)) ?? []
    }
}
