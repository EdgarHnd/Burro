// Where the Today timeline draws each block, hour line and idle gap, in points from the top. Pure
// geometry so it can be tested: the axis starts at the hour of the day's first block and ends at
// its last block (or now, for today), with no empty hours either side. Blocks get at least a
// minimum height, so the axis stretches a little around short ones instead of letting them
// overlap, and hour lines follow the same stretched scale. A gap longer than `collapseIdle`
// between blocks (or between the last block and now) is drawn as a thin "Idle" divider instead
// of empty space, and hour lines inside it are left out.
import Foundation

public struct ActivityTimelineLayout: Sendable {
    public struct Placed: Sendable, Identifiable {
        public var block: ActivityBlock
        public var y: Double
        public var height: Double
        public var id: TimeInterval { block.id }
    }
    public struct Mark: Sendable, Equatable {
        public var date: Date
        public var y: Double
    }
    /// A collapsed idle gap: drawn as a divider of `height` at `y`.
    public struct Idle: Sendable, Equatable, Identifiable {
        public var start: Date
        public var end: Date
        public var y: Double
        public var height: Double
        public var duration: TimeInterval { end.timeIntervalSince(start) }
        public var id: TimeInterval { start.timeIntervalSince1970 }
    }

    /// Idle gaps longer than this collapse to a divider.
    public static let collapseIdle: TimeInterval = 45 * 60

    public private(set) var placed: [Placed] = []
    public private(set) var marks: [Mark] = []
    public private(set) var idle: [Idle] = []
    public private(set) var height: Double = 0
    public private(set) var nowY: Double?
    private var anchors: [(date: Date, y: Double)] = []

    public init(blocks: [ActivityBlock], now: Date?, hourHeight: Double, minHeight: Double, idleHeight: Double = 30,
                calendar: Calendar = .current) {
        guard let first = blocks.first, let last = blocks.map(\.end).max() else { return }
        let perSecond = hourHeight / 3600
        let from = calendar.dateInterval(of: .hour, for: first.start)?.start ?? first.start
        let to = max(last, now ?? last)
        var time = from, y = 0.0
        anchors.append((from, 0))
        func advance(to date: Date) {
            guard date > time else { return }
            if !placed.isEmpty, date.timeIntervalSince(time) > Self.collapseIdle {
                idle.append(Idle(start: time, end: date, y: y, height: idleHeight))
                anchors.append((time, y))
                y += idleHeight
                anchors.append((date, y))
            } else {
                y += date.timeIntervalSince(time) * perSecond
            }
            time = date
        }
        for block in blocks {
            advance(to: block.start)
            let height = max(minHeight, block.duration * perSecond)
            anchors.append((max(time, block.start), y))
            placed.append(Placed(block: block, y: y, height: height))
            y += height
            time = max(time, block.end)
            anchors.append((time, y))
        }
        advance(to: to)
        anchors.append((to, y))
        height = y
        var hour = from
        while hour <= to {
            if !idle.contains(where: { $0.start < hour && hour < $0.end }) { marks.append(Mark(date: hour, y: map(hour))) }
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hour) else { break }
            hour = next
        }
        if let now, now >= from, now <= to { nowY = map(now) }
    }

    /// Time to height along the stretched scale.
    public func map(_ date: Date) -> Double {
        guard let after = anchors.firstIndex(where: { $0.date >= date }) else { return anchors.last?.y ?? 0 }
        guard after > 0 else { return anchors[0].y }
        let a = anchors[after - 1], b = anchors[after]
        let span = b.date.timeIntervalSince(a.date)
        return span > 0 ? a.y + (b.y - a.y) * date.timeIntervalSince(a.date) / span : b.y
    }
}
