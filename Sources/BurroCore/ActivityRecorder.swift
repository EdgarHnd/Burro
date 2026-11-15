// Turns a stream of frontmost-window observations into a few spans worth writing. Title changes
// inside one app and site never split it while the old title held less than five seconds (a
// terminal spinner renaming its window ten times a second is one span), app flicks under five
// seconds fold into their neighbour, and the last finished span waits in memory until something
// different and longer replaces it, so a steady day writes a handful of lines an hour. Going idle
// is often noticed late and dated back to the last input: nothing handed out then runs past that
// moment. Spans too short to show at the log's tenth-of-a-second precision are never handed out.
import Foundation

public struct ActivityRecorder: Sendable {
    public static let minimumSpan: TimeInterval = 5
    struct Open: Sendable { var key: ActivityKey; var start: Date; var titleStart: Date }
    private var open: Open?
    /// Finished but not yet handed out: it may still absorb a following blip.
    public private(set) var pending: ActivitySpan?

    public init() {}

    /// A new observation, or nil when you went idle, locked the screen or paused tracking.
    /// Returns spans that are final and ready to write. A nil `time` may be in the past (idle
    /// began at the last input): unsaved time after it is dropped, and a span across it is cut there.
    public mutating func observe(_ key: ActivityKey?, at time: Date) -> [ActivitySpan] {
        guard let key else { return close(at: time) }
        if var current = open, current.key.sameApp(key) {
            if current.key.title == key.title { return [] }
            if time.timeIntervalSince(current.titleStart) < Self.minimumSpan {
                current.key.title = key.title
                current.titleStart = time
                open = current
                return []
            }
        }
        var ready: [ActivitySpan] = []
        if let current = open { ready += absorb(ActivitySpan(current.key, start: current.start, end: max(current.start, time))) }
        open = Open(key: key, start: time, titleStart: time)
        return ready
    }

    /// Ends everything at `time`: the open span and the pending one are handed out, cut at `time`,
    /// and dropped if they start at or after it.
    private mutating func close(at time: Date) -> [ActivitySpan] {
        var ready: [ActivitySpan] = []
        if let current = open, time > current.start { ready += absorb(ActivitySpan(current.key, start: current.start, end: time)) }
        open = nil
        if let last = pending { ready.append(last); pending = nil }
        return ready.compactMap { span in
            guard span.start < time else { return nil }
            var cut = span
            cut.end = min(span.end, time)
            return cut.isRecordable ? cut : nil
        }
    }

    /// Cuts the open span at `time` so a long stay in one window is saved now and then, and
    /// hands out the pending span if it's long enough to stand on its own.
    public mutating func checkpoint(at time: Date) -> [ActivitySpan] {
        var ready: [ActivitySpan] = []
        if let current = open, time > current.start {
            ready += absorb(ActivitySpan(current.key, start: current.start, end: time))
            open = Open(key: current.key, start: time, titleStart: current.titleStart)
        }
        if let last = pending, last.duration >= Self.minimumSpan { ready.append(last); pending = nil }
        return ready
    }

    /// Drops everything unsaved (delete this day); the current window counts again from `time`.
    public mutating func discard(at time: Date) {
        pending = nil
        open = open.map { Open(key: $0.key, start: time, titleStart: time) }
    }

    /// Applies a newly private host to unsaved time and the open span.
    public mutating func redact(host: String) {
        pending = pending?.redacted(host: host)
        if let current = open { open?.key = ActivityPrivacy.redacted(current.key, host: host) }
    }

    /// Unsaved time up to `now`, for showing today live.
    public func live(at now: Date) -> [ActivitySpan] {
        [pending, open.map { ActivitySpan($0.key, start: $0.start, end: max($0.start, now)) }].compactMap { $0 }
    }

    private mutating func absorb(_ span: ActivitySpan) -> [ActivitySpan] {
        guard span.isRecordable else { return [] }
        guard var last = pending else { pending = span; return [] }
        if span.start.timeIntervalSince(last.end) > 1 { pending = span; return [last] }
        if last.key == span.key || span.duration < Self.minimumSpan {
            last.end = span.end
            pending = last
            return []
        }
        if last.duration < Self.minimumSpan {
            var merged = span
            merged.start = last.start
            pending = merged
            return []
        }
        pending = span
        return [last]
    }
}
