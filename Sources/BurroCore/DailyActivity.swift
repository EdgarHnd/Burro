// One day of agent activity (from the Rust history worker) and Dayflow's timeline (from its own
// read-only CLI), plus the small rollups the Today page shows. Nothing here is persisted.
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

// MARK: Dayflow

/// Dayflow's timeline through its own read-only CLI (`dayflow timeline <date> --json`), which
/// works even when Dayflow isn't running. Burro never records the screen itself.
public struct DayflowDay: Sendable, Equatable {
    public struct Card: Sendable, Equatable, Identifiable {
        public var id: String
        public var start: Date
        public var end: Date
        public var minutes: Int
        public var category: String
        public var subcategory: String?
        public var title: String
        public var apps: [String]
    }
    public var date: String
    public var cards: [Card]
    public var pendingBatches: Int?
    public var failedBatches: Int?
    public static let idleCategories: Set<String> = ["Idle", "Distraction"]
    /// Minutes outside Idle and Distraction.
    public var focusedMinutes: Int { cards.filter { !Self.idleCategories.contains($0.category) }.reduce(0) { $0 + $1.minutes } }
    public var minutesByCategory: [(category: String, minutes: Int)] {
        Dictionary(grouping: cards, by: \.category).map { (category: $0.key, minutes: $0.value.reduce(0) { $0 + $1.minutes }) }
            .sorted { $0.minutes > $1.minutes }
    }
}

public enum Dayflow {
    public static func executable(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                                  exists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        ["/Applications/Dayflow.app/Contents/Helpers/dayflow", home + "/Applications/Dayflow.app/Contents/Helpers/dayflow"].first(where: exists)
    }

    public static func day(_ date: Date, calendar: Calendar = .current, executable: String? = executable()) -> DayflowDay? {
        guard let executable else { return nil }
        let key = TodoDay.key(date, calendar: calendar)
        let timeline = CommandRunner().run(executable, ["timeline", key, "--json"], timeout: 12)
        guard timeline.succeeded, var day = parseTimeline(Data(timeline.output.utf8)) else { return nil }
        let status = CommandRunner().run(executable, ["status", "--json"], timeout: 8)
        if status.succeeded, let object = try? JSONSerialization.jsonObject(with: Data(status.output.utf8)) as? [String: Any] {
            day.pendingBatches = object["pending_batches"] as? Int
            day.failedBatches = object["failed_batches"] as? Int
        }
        return day
    }

    static func parseTimeline(_ data: Data) -> DayflowDay? {
        guard data.count <= 8 * 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil, (object["schema_version"] as? Int) == 1,
              let date = object["date"] as? String, let rows = object["cards"] as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        let cards: [DayflowDay.Card] = rows.prefix(2000).compactMap { row in
            guard let start = (row["start"] as? String).flatMap(iso.date), let end = (row["end"] as? String).flatMap(iso.date),
                  end >= start, let title = row["title"] as? String, let category = row["category"] as? String else { return nil }
            let id = (row["record_id"] as? Int).map(String.init) ?? (row["record_id"] as? String) ?? "\(start.timeIntervalSince1970)"
            let minutes = (row["duration_minutes"] as? Int) ?? Int(end.timeIntervalSince(start) / 60)
            return DayflowDay.Card(id: id, start: start, end: end, minutes: max(0, minutes), category: String(category.prefix(80)),
                                   subcategory: (row["subcategory"] as? String).map { String($0.prefix(120)) },
                                   title: String(title.prefix(200)), apps: Array((row["apps"] as? [String] ?? []).prefix(8)))
        }
        return DayflowDay(date: date, cards: cards.sorted { $0.start < $1.start })
    }
}

// MARK: Today rollups

public struct TodayHour: Sendable, Equatable {
    public var hour: Int
    public var turns: Int
    public var replies: Int
    /// Dayflow's category with the most minutes in this hour, if any.
    public var category: String?
}

public enum TodaySummary {
    /// Up to 24 cells (DST days can have 23 or 25 hours), combining agent turns with Dayflow categories.
    public static func hours(activity: DailyActivity?, dayflow: DayflowDay?, day: Date, calendar: Calendar = .current) -> [TodayHour] {
        let start = calendar.startOfDay(for: day)
        let count = activity?.turnsByHour.count ?? 24
        return (0..<count).map { index in
            let from = start.addingTimeInterval(Double(index) * 3600), to = from.addingTimeInterval(3600)
            var minutes: [String: Double] = [:]
            for card in dayflow?.cards ?? [] {
                let overlap = min(card.end, to).timeIntervalSince(max(card.start, from))
                if overlap > 0 { minutes[card.category, default: 0] += overlap }
            }
            return TodayHour(hour: index, turns: activity?.turnsByHour[index] ?? 0, replies: activity?.repliesByHour[index] ?? 0,
                             category: minutes.max { $0.value < $1.value }?.key)
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
