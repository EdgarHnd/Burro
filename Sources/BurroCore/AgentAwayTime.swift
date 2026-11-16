// How much agents worked while you were away: the Today page's "While you were away" card, the
// fact in its headline, the ribbon's away marks and lit agent stretches, and the number Home shows.
// Pure and computed in the app from data it already holds (each chat's active stretches from the
// day scan, and the day Burro tracked); nothing here is logged, stored or sent to a worker or the
// Orchestrator.
// You count as present while the tracker recorded you (its entries, with gaps under 5 minutes
// bridged, the same join the timeline uses). Away is time Burro was recording and you weren't
// there: the gaps of 5 minutes or more between your presence, minus every stretch Burro wasn't
// recording (closed, paused or tracking off, ActivityDay.notRecorded). Time Burro can't vouch for
// never reads as away: on a day without a coverage record (older days, imported days) only the gaps
// between the day's first and last tracked entry count, never the time before the first entry or
// after the last; on the day coverage began, the same holds for the part before its first
// recording interval. Away ends when the tracked day was read, not at the later `now`. The total is wall-clock time (several chats working at once count once); each
// chat's own share is listed too, so the shares can add up to more than the total. When the scan
// was partial or some chat's stretches are unknown, the summary says so (`partial`) and the total
// is worded "about". Without a tracked day (tracking off, or nothing recorded and no coverage
// record) or without any chat's stretches (an older worker) it makes no claim and returns nil.
import Foundation

public enum AgentAwayTime {
    /// Gaps in your tracked time shorter than this are still you, at the Mac.
    public static let minimumAway: TimeInterval = 300

    public struct Chat: Sendable, Equatable, Identifiable {
        /// Matches `DailyActivity.Chat.id`.
        public var id: String
        /// The chat's active time inside your away periods.
        public var seconds: TimeInterval
        /// Those stretches, in order.
        public var intervals: [DateInterval]
    }

    public struct Summary: Sendable, Equatable {
        /// Wall-clock time any agent was active while you were away.
        public var total: TimeInterval
        /// Chats with any such time, longest first.
        public var chats: [Chat]
        /// From the first to the last moment of agent work while you were away.
        public var span: DateInterval?
        /// The day's away periods up to now (Burro recording, you not there), in order. The ribbon's
        /// away marks and lit agent stretches use exactly these.
        public var away: [DateInterval]
        /// The scan was partial or some chat's stretches are unknown: the total is approximate.
        public var partial = false
        /// "3h 35m", or "about 3h 35m" when partial.
        public var totalText: String { AgentAwayTime.phrase(total, partial: partial) }
    }

    /// "3h 35m", or "about 3h 35m" when some chats couldn't be read (it may be more or less).
    public static func phrase(_ seconds: TimeInterval, partial: Bool) -> String {
        (partial ? "about " : "") + TodaySummary.duration(seconds)
    }

    /// When you were at the Mac: the tracked day's entries, gaps under `minimumAway` bridged.
    public static func present(_ day: ActivityDay) -> [DateInterval] {
        var out: [DateInterval] = []
        for entry in day.entries.sorted(by: { $0.start < $1.start }) where entry.end >= entry.start {
            if let last = out.last, entry.start.timeIntervalSince(last.end) < minimumAway {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, entry.end))
            } else {
                out.append(DateInterval(start: entry.start, end: entry.end))
            }
        }
        return out
    }

    /// The parts of `range` outside `present` that last `minimumAway` or more.
    public static func away(present: [DateInterval], within range: DateInterval) -> [DateInterval] {
        var gaps: [DateInterval] = [], cursor = range.start
        for interval in ActivityCoverage.merged(present) where interval.end > cursor {
            if interval.start >= range.end { break }
            if interval.start > cursor { gaps.append(DateInterval(start: cursor, end: interval.start)) }
            cursor = max(cursor, interval.end)
        }
        if cursor < range.end { gaps.append(DateInterval(start: cursor, end: range.end)) }
        return gaps.filter { $0.duration >= minimumAway }
    }

    /// The day's away periods inside `range`: gaps of `minimumAway` or more between your presence,
    /// minus the stretches Burro wasn't recording. Without a coverage record only the gaps between
    /// the first and last tracked entry count (before and after them nothing is known).
    public static func away(tracked: ActivityDay, within range: DateInterval) -> [DateInterval] {
        let present = present(tracked)
        let until = min(range.end, tracked.coveredUntil ?? range.end)
        guard until > range.start else { return [] }
        /// Inside an unknown stretch only the gaps between the entries in it count.
        func between(_ start: Date, _ end: Date) -> [DateInterval] {
            let inside = present.filter { $0.end > start && $0.start < end }
            guard let first = inside.first, let last = inside.last else { return [] }
            let from = max(start, first.start), to = min(end, last.end)
            return to > from ? away(present: present, within: DateInterval(start: from, end: to)) : []
        }
        var gaps: [DateInterval]
        if !tracked.coverageKnown {
            gaps = between(range.start, until)
        } else if let from = tracked.coverageFrom, from > range.start {
            gaps = between(range.start, min(from, until))
            if until > from { gaps += away(present: present, within: DateInterval(start: from, end: until)) }
        } else {
            gaps = away(present: present, within: DateInterval(start: range.start, end: until))
        }
        let holes = ActivityCoverage.merged(tracked.notRecorded)
        return ActivityCoverage.merged(gaps)
            .flatMap { subtract(holes, from: $0) }
            .filter { $0.duration >= minimumAway }
    }

    /// `interval` minus `holes` (sorted and apart).
    public static func subtract(_ holes: [DateInterval], from interval: DateInterval) -> [DateInterval] {
        var out: [DateInterval] = [], cursor = interval.start
        for hole in holes where hole.end > cursor && hole.start < interval.end {
            if hole.start > cursor { out.append(DateInterval(start: cursor, end: hole.start)) }
            cursor = max(cursor, hole.end)
        }
        if cursor < interval.end { out.append(DateInterval(start: cursor, end: interval.end)) }
        return out
    }

    /// The overlap of two lists of intervals, each sorted and apart (merge them first).
    public static func intersection(_ a: [DateInterval], _ b: [DateInterval]) -> [DateInterval] {
        var out: [DateInterval] = [], i = 0, j = 0
        while i < a.count && j < b.count {
            let start = max(a[i].start, b[j].start), end = min(a[i].end, b[j].end)
            if end > start { out.append(DateInterval(start: start, end: end)) }
            if a[i].end < b[j].end { i += 1 } else { j += 1 }
        }
        return out
    }

    /// Wall-clock seconds any of `agents` (one list of stretches per chat) falls inside `away`.
    public static func awayAgentTime(agents: [[DateInterval]], away: [DateInterval]) -> TimeInterval {
        intersection(ActivityCoverage.merged(agents.flatMap { $0 }), ActivityCoverage.merged(away)).reduce(0) { $0 + $1.duration }
    }

    /// The summary for `day` up to `now` (the whole day once it is over). Nil when it can't be said:
    /// no tracked day, a tracked day with nothing recorded and no coverage record, or no chat whose
    /// stretches are known. `partial`: the scan's answer was partial.
    public static func summary(chats: [DailyActivity.Chat], tracked: ActivityDay?, day: Date, now: Date, partial: Bool = false,
                               calendar: Calendar = .current) -> Summary? {
        guard let tracked, !tracked.entries.isEmpty || tracked.coverageKnown else { return nil }
        let known = chats.compactMap { chat in chat.active.map { (chat.id, ActivityCoverage.merged($0)) } }
        guard !known.isEmpty || chats.isEmpty else { return nil }
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let until = min(end, max(start, now))
        let away = away(tracked: tracked, within: DateInterval(start: start, end: until))
        let perChat = known.compactMap { id, intervals -> Chat? in
            let inside = intersection(intervals, away)
            let seconds = inside.reduce(0) { $0 + $1.duration }
            return seconds > 0 ? Chat(id: id, seconds: seconds, intervals: inside) : nil
        }.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.id < $1.id }
        let all = ActivityCoverage.merged(perChat.flatMap(\.intervals))
        let span = all.first.flatMap { first in all.last.map { DateInterval(start: first.start, end: $0.end) } }
        return Summary(total: awayAgentTime(agents: known.map(\.1), away: away), chats: perChat, span: span, away: away,
                       partial: partial || known.count < chats.count)
    }
}
