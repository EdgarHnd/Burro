// Where the Today timeline draws each block, hour line and idle gap, in points from the top. Pure
// geometry so it can be tested: the axis starts at the hour of the day's first block and ends at
// its last block (or now, for today), with no empty hours either side. Blocks get at least a
// minimum height, so the axis stretches a little around short ones instead of letting them
// overlap, and hour lines follow the same stretched scale. A gap longer than `collapseIdle`
// between blocks (or between the last block and now) is drawn as a thin "Idle" divider instead
// of empty space, and hour lines inside it are left out. A stretch Burro wasn't recording (closed
// or paused, from ActivityDay.notRecorded) is always its own divider of the `.notRecording` kind,
// wherever it falls: before the first block, between blocks or after the last; idle time on either
// side of it collapses as usual.
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
    /// A collapsed gap: drawn as a divider of `height` at `y`.
    public struct Idle: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            /// You were away (Burro was recording).
            case idle
            /// Burro was closed or tracking was paused.
            case notRecording
        }
        public var kind: Kind = .idle
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

    /// `notRecorded`: stretches Burro wasn't recording, sorted and clear of the blocks (as ActivityDay leaves them).
    public init(blocks: [ActivityBlock], notRecorded: [DateInterval] = [], now: Date?, hourHeight: Double, minHeight: Double,
                idleHeight: Double = 30, calendar: Calendar = .current) {
        guard let firstBlock = blocks.first, let lastBlock = blocks.map(\.end).max() else { return }
        let perSecond = hourHeight / 3600
        let first = min(firstBlock.start, notRecorded.first?.start ?? firstBlock.start)
        let last = max(lastBlock, notRecorded.map(\.end).max() ?? lastBlock)
        let from = calendar.dateInterval(of: .hour, for: first)?.start ?? first
        let to = max(last, now ?? last)
        var time = from, y = 0.0
        anchors.append((from, 0))
        func advance(to date: Date) {
            guard date > time else { return }
            if !placed.isEmpty || !idle.isEmpty, date.timeIntervalSince(time) > Self.collapseIdle {
                idle.append(Idle(start: time, end: date, y: y, height: idleHeight))
                anchors.append((time, y))
                y += idleHeight
                anchors.append((date, y))
            } else {
                y += date.timeIntervalSince(time) * perSecond
            }
            time = date
        }
        var gaps = notRecorded[...]
        /// Not-recorded stretches that start before `date`, each as its own divider.
        func dividers(before date: Date) {
            while let gap = gaps.first, gap.start < date {
                gaps.removeFirst()
                guard gap.end > time else { continue }
                advance(to: gap.start)
                let start = max(time, gap.start)
                anchors.append((start, y))
                idle.append(Idle(kind: .notRecording, start: start, end: gap.end, y: y, height: idleHeight))
                y += idleHeight
                time = gap.end
                anchors.append((time, y))
            }
        }
        for block in blocks {
            dividers(before: block.start)
            advance(to: block.start)
            let height = max(minHeight, block.duration * perSecond)
            anchors.append((max(time, block.start), y))
            placed.append(Placed(block: block, y: y, height: height))
            y += height
            time = max(time, block.end)
            anchors.append((time, y))
        }
        dividers(before: .distantFuture)
        advance(to: to)
        anchors.append((to, y))
        height = y
        var hour = from
        while hour <= to {
            // A not-recorded stretch also hides the hour it starts on (a day that opens with one starts at 0:00).
            if !idle.contains(where: { ($0.start < hour || ($0.kind == .notRecording && $0.start == hour)) && hour < $0.end }) {
                marks.append(Mark(date: hour, y: map(hour)))
            }
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
