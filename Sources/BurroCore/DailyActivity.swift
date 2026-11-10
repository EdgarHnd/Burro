// One day of agent activity (from the Rust history worker), plus the small rollups the Today
// page shows, including each hour's main category from Burro's own activity tracker. Nothing
// here is persisted.
import Foundation

struct DailyActivityRequest: Encodable, Sendable, Equatable {
    let codexRoots: [String]
    let claudeRoots: [String]
    let since: Double
    let until: Double
    let now: Double
    let previews: Bool
}

struct DailyActivityBatch: Decodable, Sendable {
    struct Session: Decodable, Sendable {
        let provider: String
        let id: String
        let cwd: String?
        let turns, replies, questions: Int
        let lastAt: Double
        let title: String?
        let preview: String?
    }
    let turnsByHour: [Int]
    let repliesByHour: [Int]
    let questions: Int
    let firstTurn: Double?
    let lastTurn: Double?
    let sessions: [Session]
    let partial: Bool
    let reads, cacheHits, visited: Int

    func valid(for request: DailyActivityRequest) -> Bool {
        let hours = Int(((request.until - request.since) / 3600).rounded(.up))
        guard turnsByHour.count == hours, repliesByHour.count == hours, sessions.count <= 500,
              (turnsByHour + repliesByHour + [questions]).allSatisfy({ $0 >= 0 }),
              (0...20_000).contains(visited), reads >= 0, cacheHits >= 0, reads + cacheHits <= visited else { return false }
        let inDay = { (t: Double) in t >= request.since && t < request.until }
        if let firstTurn, !inDay(firstTurn) { return false }
        if let lastTurn, !inDay(lastTurn) { return false }
        var ids = Set<String>()
        for session in sessions {
            guard ["codex", "claude"].contains(session.provider), UUID(uuidString: session.id) != nil,
                  ids.insert(session.provider + session.id).inserted, session.cwd.map(UsageLogProjectBucket.validFolder) ?? true,
                  [session.turns, session.replies, session.questions].allSatisfy({ $0 >= 0 }), inDay(session.lastAt),
                  (session.preview?.count ?? 0) <= 160, (session.title?.count ?? 0) <= 120,
                  request.previews || session.preview == nil else { return false }
        }
        return true
    }
}

public struct DailyActivity: Sendable, Equatable {
    public struct Chat: Sendable, Equatable, Identifiable {
        /// Matches `AgentSession.id` ("codex:<thread>" / "claude:<session>").
        public var id: String
        public var provider: AgentProvider
        public var folder: String?
        public var turns: Int
        public var replies: Int
        public var questions: Int
        public var lastAt: Date
        public var title: String?
        public var preview: String?
    }
    public var day: Date
    public var turnsByHour: [Int]
    public var repliesByHour: [Int]
    public var questions: Int
    public var firstTurn: Date?
    public var lastTurn: Date?
    public var chats: [Chat]
    public var partial: Bool
    public var turns: Int { turnsByHour.reduce(0, +) }
    public var replies: Int { repliesByHour.reduce(0, +) }
    /// From your first to your last message of the day.
    public var span: TimeInterval? { firstTurn.flatMap { first in lastTurn.map { $0.timeIntervalSince(first) } } }
}

public enum DailyActivityScanner {
    /// Scans Codex and Claude logs for the calendar day containing `day`. Nil without the worker.
    public static func scan(day: Date, previews: Bool, profiles: [UsageProvider: String] = [:], now: Date = Date(),
                            calendar: Calendar = .current) -> DailyActivity? {
        scan(day: day, previews: previews, profiles: profiles, now: now, calendar: calendar, worker: .usage)
    }
    static func scan(day: Date, previews: Bool, profiles: [UsageProvider: String], now: Date,
                     calendar: Calendar, worker: AgentLogWorker?) -> DailyActivity? {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start), let worker else { return nil }
        let request = DailyActivityRequest(
            codexRoots: LocalUsageScanner.roots(provider: .codex, profile: profiles[.codex]).map(\.path),
            claudeRoots: LocalUsageScanner.roots(provider: .claude, profile: profiles[.claude]).map(\.path),
            since: start.timeIntervalSince1970, until: end.timeIntervalSince1970, now: now.timeIntervalSince1970, previews: previews)
        guard let batch = worker.exchange([], activity: request)?.activity else { return nil }
        return DailyActivity(
            day: start, turnsByHour: batch.turnsByHour, repliesByHour: batch.repliesByHour, questions: batch.questions,
            firstTurn: batch.firstTurn.map(Date.init(timeIntervalSince1970:)), lastTurn: batch.lastTurn.map(Date.init(timeIntervalSince1970:)),
            chats: batch.sessions.map { s in
                DailyActivity.Chat(id: "\(s.provider):\(s.id)", provider: s.provider == "codex" ? .codex : .claude, folder: s.cwd,
                                   turns: s.turns, replies: s.replies, questions: s.questions,
                                   lastAt: Date(timeIntervalSince1970: s.lastAt), title: s.title, preview: s.preview)
            },
            partial: batch.partial)
    }
}

// MARK: Today rollups

public struct TodayHour: Sendable, Equatable {
    public var hour: Int
    public var turns: Int
    public var replies: Int
    /// The tracked category with the most time in this hour, if any.
    public var category: ActivityCategory?
}

public enum TodaySummary {
    /// Up to 24 cells (DST days can have 23 or 25 hours), combining agent turns with tracked categories.
    public static func hours(activity: DailyActivity?, tracked: ActivityDay?) -> [TodayHour] {
        let count = activity?.turnsByHour.count ?? tracked?.hourly.count ?? 24
        return (0..<count).map { index in
            TodayHour(hour: index, turns: activity?.turnsByHour[index] ?? 0, replies: activity?.repliesByHour[index] ?? 0,
                      category: tracked.flatMap { index < $0.hourly.count ? $0.hourly[index] : nil })
        }
    }

    /// Questions agents asked today vs those still waiting on you right now.
    public static func decisions(asked: Int, waitingNow: Int) -> (asked: Int, answered: Int, share: Double?) {
        let total = max(asked, waitingNow)
        let answered = max(0, total - waitingNow)
        return (total, answered, total > 0 ? Double(answered) / Double(total) : nil)
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}
