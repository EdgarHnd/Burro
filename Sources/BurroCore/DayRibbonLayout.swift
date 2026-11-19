// Where the Today page's day ribbon draws things, in points from the left edge of its lanes. Pure
// geometry so it can be tested. The ribbon shows a window of time — the whole day (00–24), or one
// hour after a click zooms in — across a given width. Anything is placed by its start and end,
// clipped to the window, and never narrower than a minimum so a one-minute block stays visible and
// clickable. Grid lines and labels: every 3 hours for a whole day (00 03 … 21, with 24 at the right
// edge), every hour for a few hours, every 10 minutes for an hour; hour steps follow the wall clock
// in the calendar passed, so 23- and 25-hour DST days still label correctly; a label too close to
// the now marker's label is left out. The Agents lane packs chats into rows: one row per chat while they
// fit, otherwise each chat goes into the first row where it doesn't touch another chat, and what
// still doesn't fit shares the last row. An agent stretch is split into the parts inside your away
// periods (drawn lit) and the rest.
import Foundation

public struct DayRibbonLayout: Sendable {
    public struct Segment: Sendable, Equatable {
        public var x: Double
        public var width: Double
        public var maxX: Double { x + width }
    }
    public struct Tick: Sendable, Equatable {
        public var date: Date
        public var x: Double
        /// "09" on the hour in a whole-day view, "10:40" otherwise; nil when hidden near the now label.
        public var label: String?
    }

    public var window: DateInterval
    public var width: Double
    public var minWidth: Double

    public init(window: DateInterval, width: Double, minWidth: Double = 3) {
        self.window = window; self.width = max(0, width); self.minWidth = minWidth
    }

    private var scale: Double { window.duration > 0 ? width / window.duration : 0 }

    /// The x of `date`, clamped to the lanes.
    public func x(_ date: Date) -> Double {
        min(width, max(0, date.timeIntervalSince(window.start) * scale))
    }

    /// Where `interval` is drawn, or nil when it falls outside the window. At least `minWidth`
    /// wide, kept inside the lanes.
    public func segment(_ interval: DateInterval) -> Segment? {
        guard interval.end >= window.start, interval.start <= window.end, width > 0 else { return nil }
        let from = x(interval.start), to = x(interval.end)
        let wide = max(minWidth, to - from)
        return Segment(x: max(0, min(from, width - wide)), width: min(wide, width))
    }

    /// The now marker's x, or nil when now is outside the window.
    public func nowX(_ now: Date?) -> Double? {
        guard let now, window.contains(now) else { return nil }
        return x(now)
    }

    /// The grid step for this window.
    public var step: TimeInterval {
        let duration = window.duration
        if duration >= 12 * 3600.0 { return 3 * 3600.0 }
        if duration >= 3 * 3600.0 { return 3600.0 }
        if duration >= 90 * 60.0 { return 30 * 60.0 }
        return 10 * 60.0
    }

    /// Grid lines from the window's start (included) to its end (included), with 24-hour labels in
    /// `calendar`. Labels within `clearance` points of `nowX` are hidden.
    public func ticks(calendar: Calendar, nowX: Double? = nil, clearance: Double = 44) -> [Tick] {
        let step = self.step
        let dayStart = calendar.startOfDay(for: window.start)
        var dates: [Date] = []
        if step >= 3600 {
            // Hour steps follow the wall clock, so a 23- or 25-hour (DST) day still reads 00 03 … 21 24:
            // every hour boundary in the window whose hour is a multiple of the step, plus the start.
            let every = max(1, Int(step / 3600))
            dates.append(window.start)
            var cursor = calendar.dateInterval(of: .hour, for: window.start)?.start ?? window.start
            while cursor <= window.start { cursor = calendar.date(byAdding: .hour, value: 1, to: cursor) ?? cursor.addingTimeInterval(3600) }
            while cursor <= window.end {
                if calendar.component(.hour, from: cursor) % every == 0 { dates.append(cursor) }
                cursor = calendar.date(byAdding: .hour, value: 1, to: cursor) ?? cursor.addingTimeInterval(3600)
            }
        } else {
            let count = Int((window.duration / step).rounded(.down))
            dates = (0...max(0, count)).map { window.start.addingTimeInterval(Double($0) * step) }
        }
        return dates.map { date in
            let x = self.x(date)
            var label: String?
            if nowX.map({ abs($0 - x) >= clearance }) ?? true {
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                // The next midnight closes the day: "24", not "00".
                let hour = parts.hour == 0 && date > dayStart && !calendar.isDate(date, inSameDayAs: dayStart) ? 24 : parts.hour ?? 0
                label = step >= 3600 && parts.minute == 0 ? String(format: "%02d", hour) : String(format: "%02d:%02d", hour, parts.minute ?? 0)
            }
            return Tick(date: date, x: x, label: label)
        }
    }

    /// The hour containing `date`, inside `day`: the window a click zooms to.
    public static func zoomWindow(around date: Date, day: DateInterval, calendar: Calendar) -> DateInterval {
        let hour = calendar.dateInterval(of: .hour, for: date) ?? DateInterval(start: date, duration: 3600)
        let start = max(day.start, hour.start), end = min(day.end, max(start, hour.end))
        return DateInterval(start: start, end: end)
    }

    /// Row index per chat (in the order given), using at most `maxRows` rows.
    public func rows(_ chats: [[DateInterval]], maxRows: Int, padding: Double = 4) -> [Int] {
        guard chats.count > maxRows, maxRows > 0 else { return Array(chats.indices) }
        var taken: [[Segment]] = Array(repeating: [], count: maxRows)
        return chats.map { intervals in
            let segments = intervals.compactMap(segment)
            let row = taken.indices.first { row in
                !segments.contains { s in taken[row].contains { t in s.x < t.maxX + padding && t.x < s.maxX + padding } }
            } ?? maxRows - 1
            taken[row] += segments
            return row
        }
    }

    /// `interval` cut where it enters or leaves `away` (sorted and apart): each piece and whether it was while you were away.
    public static func split(_ interval: DateInterval, by away: [DateInterval]) -> [(interval: DateInterval, away: Bool)] {
        var out: [(DateInterval, Bool)] = [], cursor = interval.start
        for gap in away where gap.end > cursor && gap.start < interval.end {
            if gap.start > cursor { out.append((DateInterval(start: cursor, end: gap.start), false)) }
            let end = min(gap.end, interval.end)
            out.append((DateInterval(start: max(cursor, gap.start), end: end), true))
            cursor = end
        }
        if cursor < interval.end || out.isEmpty { out.append((DateInterval(start: cursor, end: max(cursor, interval.end)), false)) }
        return out
    }

    // MARK: Lanes panel

    /// The lanes panel's window: a past day is the whole day; today runs from the hour of the
    /// earliest thing drawn (at least an hour before now) to now.
    public static func laneWindow(day: DateInterval, earliest: Date?, now: Date?, calendar: Calendar) -> DateInterval {
        guard let now, day.contains(now) else { return day }
        let floor = { (date: Date) in calendar.dateInterval(of: .hour, for: date)?.start ?? date }
        let start = max(day.start, min(floor(earliest ?? now), floor(now.addingTimeInterval(-3600))))
        return DateInterval(start: start, end: max(start.addingTimeInterval(60), now))
    }

    /// The lanes window and how much drawn time it leaves out before its start.
    public struct LaneWindow: Sendable, Equatable {
        public var window: DateInterval
        /// Drawn time (stretches, tracked blocks) before `window.start` that the window leaves out.
        public var cut: TimeInterval
        public init(window: DateInterval, cut: TimeInterval) { self.window = window; self.cut = cut }
    }

    /// The lanes window from everything drawn (`pieces`: chat stretches, tracked blocks, and marks
    /// and shipped ticks as zero-length intervals). A short early piece followed by 3 hours or more
    /// with nothing drawn (one block just after midnight, then nothing until 10:00) is left out: the
    /// window starts at the hour of the first thing after that gap and `cut` says how much was left
    /// out. Only a lead of under `earlyLimit` of drawn time is cut, so real morning work is never
    /// hidden. Today runs from there (at least an hour before now) to now; a past day from there to
    /// the hour after its last piece (00–24 when nothing was drawn).
    public static func laneWindow(day: DateInterval, pieces: [DateInterval], now: Date?, calendar: Calendar,
                                  gap: TimeInterval = 3 * 3600, earlyLimit: TimeInterval = 3600) -> LaneWindow {
        let today = now.map { day.contains($0) } ?? false
        let limit = today ? (now ?? day.end) : day.end
        let merged = ActivityCoverage.merged(pieces.compactMap { piece -> DateInterval? in
            let start = max(piece.start, day.start), end = min(piece.end, limit)
            return start <= end ? DateInterval(start: start, end: end) : nil
        })
        guard let lastPiece = merged.last else {
            return LaneWindow(window: today ? laneWindow(day: day, earliest: nil, now: now, calendar: calendar) : day, cut: 0)
        }
        var keep = 0, longest: TimeInterval = 0, lead: TimeInterval = 0
        for index in 0..<(merged.count - 1) {
            lead += merged[index].duration
            let empty = merged[index + 1].start.timeIntervalSince(merged[index].end)
            if empty >= gap && lead < earlyLimit && empty > longest { longest = empty; keep = index + 1 }
        }
        let cut = merged[..<keep].reduce(0) { $0 + $1.duration }
        let first = merged[keep].start
        if today {
            return LaneWindow(window: laneWindow(day: day, earliest: first, now: now, calendar: calendar), cut: cut)
        }
        let floor = calendar.dateInterval(of: .hour, for: first)?.start ?? first
        let lastHour = calendar.dateInterval(of: .hour, for: lastPiece.end)
        let ceiling = lastHour.map { $0.start == lastPiece.end ? $0.start : $0.end } ?? lastPiece.end
        let start = max(day.start, floor), end = min(day.end, max(ceiling, start.addingTimeInterval(3600)))
        return LaneWindow(window: DateInterval(start: start, end: end), cut: cut)
    }

    /// A chat's stretches as drawn: stretches whose on-screen gap is under `joinBelow` points are one
    /// piece, and every piece is at least `minWidth` wide, so a busy hour of short bursts reads as a
    /// bar rather than a row of specks. Drawing only: totals use the stretches themselves.
    public struct DrawnPiece: Sendable, Equatable {
        /// From the first joined stretch's start to the last one's end.
        public var interval: DateInterval
        /// Seconds actually active inside it.
        public var active: TimeInterval
        public var x: Double
        public var width: Double
        public var maxX: Double { x + width }
    }

    public func drawn(_ intervals: [DateInterval], joinBelow: Double = 4, minWidth: Double = 3) -> [DrawnPiece] {
        guard width > 0 else { return [] }
        var pieces: [DrawnPiece] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) where interval.end >= window.start && interval.start <= window.end {
            let from = x(interval.start), to = x(interval.end)
            if var last = pieces.last, from - last.maxX < joinBelow {
                last.interval = DateInterval(start: last.interval.start, end: max(last.interval.end, interval.end))
                last.active += interval.duration
                last.width = max(last.width, to - last.x)
                pieces[pieces.count - 1] = last
            } else {
                pieces.append(DrawnPiece(interval: interval, active: interval.duration, x: from, width: to - from))
            }
        }
        return pieces.map { piece in
            var piece = piece
            let wide = min(width, max(minWidth, piece.width))
            piece.x = max(0, min(piece.x, width - wide)); piece.width = wide
            return piece
        }
    }

    /// The drawn piece under `x`, allowing `tolerance` points either side (thin bars are hard to hit).
    public func piece(atX x: Double, in intervals: [DateInterval], tolerance: Double = 3) -> DrawnPiece? {
        drawn(intervals).first { x >= $0.x - tolerance && x <= $0.maxX + tolerance }
    }

    /// The stretch drawn under `x` (the whole joined piece), allowing `tolerance` points either side.
    public func stretch(atX x: Double, in intervals: [DateInterval], tolerance: Double = 3) -> DateInterval? {
        piece(atX: x, in: intervals, tolerance: tolerance)?.interval
    }

    /// The time under `x`.
    public func date(atX x: Double) -> Date {
        guard width > 0 else { return window.start }
        return window.start.addingTimeInterval(min(width, max(0, x)) / width * window.duration)
    }

    /// The lane under `y` when lanes of `height` are stacked from the top, or nil outside them.
    public static func lane(atY y: Double, height: Double, count: Int) -> Int? {
        guard height > 0, y >= 0 else { return nil }
        let index = Int(y / height)
        return index < count ? index : nil
    }
}
