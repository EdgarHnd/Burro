// When Burro was recording, so "Burro wasn't recording" reads differently from "you were away".
// A recording interval runs from when the sampler starts (tracking on, not paused, Burro open) to
// when it stops (pause, turn off, quit). Sleep and screen lock don't end it: the app kept running,
// so that time is away, not unrecorded. `ActivityRecording` holds the open interval in memory and
// hands out the piece to write on each heartbeat (at most every 30 seconds, plus at wake and stop),
// so a crash or kill loses at most that much; a heartbeat after a long sleep simply extends the
// interval across it. Intervals are kept in a small owner-only sidecar per local day
// (`yyyy-MM-dd.coverage` next to the day's spans, 0600, no symlinks, 64 KiB cap, rewritten whole
// through a temporary file), split at midnight, pruned and deleted with the day. A day without a
// sidecar (before this existed, or imported from another tracker) makes no claim. A sidecar that is
// present but unreadable (corrupt or over the cap) is moved aside to `yyyy-MM-dd.coverage.bad`
// (replacing an earlier one, owner-only, pruned and deleted with the day) and that day stays
// unknown: no fresh sidecar is started that would claim the earlier hours weren't recorded. Only times are
// stored; nothing here touches the network, logs or the orchestrator's snapshot.
import Foundation

/// The open recording interval and what of it has reached disk.
public struct ActivityRecording: Sendable, Equatable {
    /// Start of the open interval; nil while not recording.
    public private(set) var start: Date?
    /// End last handed out for writing.
    public private(set) var written: Date?

    public init() {}

    /// Recording began (or began again after a pause). Returns the first piece to write.
    public mutating func begin(at time: Date) -> DateInterval? {
        guard start == nil else { return nil }
        start = time
        written = nil
        return DateInterval(start: time, end: time)
    }

    /// The open interval extended to `now`, from the start of the day of the last write (earlier
    /// days are already final), or nil when not recording or nothing moved. A long gap since the
    /// last beat (the Mac slept) is covered: the app was running all along.
    public mutating func beat(at now: Date, calendar: Calendar = .current) -> DateInterval? {
        guard let start, now > (written ?? start) else { return nil }
        let from = written.map { max(start, calendar.startOfDay(for: $0)) } ?? start
        written = now
        return DateInterval(start: from, end: now)
    }

    /// Recording stopped at `time`: the last piece to write, if it moved.
    public mutating func end(at time: Date, calendar: Calendar = .current) -> DateInterval? {
        defer { start = nil; written = nil }
        return beat(at: time, calendar: calendar)
    }

    /// Starts the open interval over at `time` (the day's record was deleted). Returns its first
    /// piece to write, or nil while not recording.
    public mutating func restart(at time: Date) -> DateInterval? {
        guard start != nil else { return nil }
        start = nil
        return begin(at: time)
    }

    /// The open interval up to `now`, for showing today live.
    public func live(at now: Date) -> DateInterval? {
        start.map { DateInterval(start: $0, end: max($0, now)) }
    }
}

public enum ActivityCoverage {
    /// Gaps in the record shorter than this aren't worth a mention.
    public static let minimumGap: TimeInterval = 5 * 60
    static let fileLimit = 64 * 1024
    static let intervalLimit = 2000

    /// Sorted, overlapping or touching intervals joined.
    public static func merged(_ intervals: [DateInterval]) -> [DateInterval] {
        var out: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, interval.start <= last.end {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                out.append(interval)
            }
        }
        return out
    }

    /// The stretches of `range` Burro wasn't recording: not inside a recording interval and not
    /// covered by a recorded span, at least `minimumGap` long. Nil coverage (no sidecar) claims nothing.
    /// Spans from before the first recording interval mean coverage wasn't being kept yet (the day
    /// this was first recorded): nothing is claimed before that interval.
    public static func notRecorded(coverage: [DateInterval]?, spans: [ActivitySpan], within range: DateInterval) -> [DateInterval] {
        guard let coverage, range.duration > 0 else { return [] }
        let recorded = merged(coverage + spans.filter { $0.end > $0.start }.map { DateInterval(start: $0.start, end: $0.end) })
        var gaps: [DateInterval] = [], cursor = range.start
        if let first = unknownUntil(coverage: coverage, spans: spans) { cursor = max(cursor, first) }
        for interval in recorded where interval.end > cursor {
            if interval.start >= range.end { break }
            if interval.start > cursor { gaps.append(DateInterval(start: cursor, end: interval.start)) }
            cursor = max(cursor, interval.end)
        }
        if cursor < range.end { gaps.append(DateInterval(start: cursor, end: range.end)) }
        return gaps.filter { $0.duration >= minimumGap }
    }

    /// On the day coverage began to be kept: the start of the first recording interval when spans
    /// predate it (before it, whether Burro was recording is unknown). Nil otherwise.
    public static func unknownUntil(coverage: [DateInterval]?, spans: [ActivitySpan]) -> Date? {
        guard let first = coverage?.map(\.start).min(), spans.contains(where: { $0.start < first }) else { return nil }
        return first
    }

    /// The short note for the summary: "Not recorded 0:00–16:42" for one gap, "Not recorded for
    /// 5h 20m" for several, nil for none. Times are 24-hour in `calendar`; a day's end reads 24:00.
    public static func note(_ gaps: [DateInterval], day: Date, calendar: Calendar = .current) -> String? {
        guard let first = gaps.first else { return nil }
        guard gaps.count == 1 else { return "Not recorded for " + TodaySummary.duration(gaps.reduce(0) { $0 + $1.duration }) }
        let start = calendar.startOfDay(for: day)
        func clock(_ date: Date) -> String {
            let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            if date >= next { return "24:00" }
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return "\(parts.hour ?? 0):" + String(format: "%02d", parts.minute ?? 0)
        }
        return "Not recorded \(clock(first.start))–\(clock(first.end))"
    }
}

extension ActivityLog {
    public func coverageURL(for day: Date, calendar: Calendar = .current) -> URL {
        folder.appendingPathComponent(TodoDay.key(day, calendar: calendar) + ".coverage")
    }

    /// The day's recording intervals, merged; nil when there is no readable sidecar (coverage unknown).
    public func readCoverage(day: Date, calendar: Calendar = .current) -> [DateInterval]? {
        guard let data = Self.readRegularFile(coverageURL(for: day, calendar: calendar), limit: ActivityCoverage.fileLimit + 1),
              data.count <= ActivityCoverage.fileLimit,
              let pairs = try? JSONDecoder().decode([[Double]].self, from: data) else { return nil }
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let intervals = pairs.prefix(ActivityCoverage.intervalLimit).compactMap { pair -> DateInterval? in
            guard pair.count == 2, pair.allSatisfy(\.isFinite), pair[1] >= pair[0] else { return nil }
            let from = max(start, Date(timeIntervalSince1970: pair[0])), to = min(end, Date(timeIntervalSince1970: pair[1]))
            return to >= from ? DateInterval(start: from, end: to) : nil
        }
        return ActivityCoverage.merged(intervals)
    }

    /// Records a piece of a recording interval, split at midnight. In each day's sidecar the
    /// interval with the same start is extended, or a new one added; a sidecar is rewritten only
    /// when it changed. Times are kept to the second.
    public func recordCoverage(_ interval: DateInterval, calendar: Calendar = .current) throws {
        var from = interval.start
        repeat {
            let dayStart = calendar.startOfDay(for: from)
            let next = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? interval.end
            let to = min(interval.end, next)
            try upsertCoverage(start: from, end: to, day: dayStart, calendar: calendar)
            from = to
        } while from < interval.end
    }

    private func upsertCoverage(start: Date, end: Date, day: Date, calendar: Calendar) throws {
        let url = coverageURL(for: day, calendar: calendar), bad = unreadableCoverageURL(for: day, calendar: calendar)
        let s = start.timeIntervalSince1970.rounded(.down), e = end.timeIntervalSince1970.rounded(.up)
        var info = stat()
        var pairs: [[Double]] = []
        if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG {
            guard let data = Self.readRegularFile(url, limit: ActivityCoverage.fileLimit + 1), data.count <= ActivityCoverage.fileLimit,
                  let decoded = try? JSONDecoder().decode([[Double]].self, from: data) else {
                // Present but unreadable: set it aside (replacing an earlier one) and leave the day unknown.
                guard rename(url.path, bad.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
                chmod(bad.path, 0o600)
                return
            }
            pairs = decoded.filter { $0.count == 2 && $0.allSatisfy(\.isFinite) }
        } else if lstat(bad.path, &info) == 0 {
            // The day's record was unreadable: its coverage stays unknown rather than starting a new claim.
            return
        }
        if let index = pairs.firstIndex(where: { abs($0[0] - s) < 1 }) {
            guard e > pairs[index][1] else { return }
            pairs[index][1] = e
        } else {
            guard pairs.count < ActivityCoverage.intervalLimit else { throw CocoaError(.fileWriteOutOfSpace) }
            pairs.append([s, e])
        }
        let data = try JSONEncoder().encode(pairs.map { $0.map(Int.init) })
        guard data.count <= ActivityCoverage.fileLimit else { throw CocoaError(.fileWriteOutOfSpace) }
        try Self.ensurePrivateFolder(folder)
        try Self.writePrivateFile(url, data: data)
    }

    public func deleteCoverage(_ day: Date, calendar: Calendar = .current) {
        unlink(coverageURL(for: day, calendar: calendar).path)
        unlink(unreadableCoverageURL(for: day, calendar: calendar).path)
    }

    /// Where an unreadable sidecar is moved aside; while it exists the day's coverage is unknown.
    public func unreadableCoverageURL(for day: Date, calendar: Calendar = .current) -> URL {
        folder.appendingPathComponent(TodoDay.key(day, calendar: calendar) + ".coverage.bad")
    }

    /// Every `yyyy-MM-dd.coverage` sidecar (and `.coverage.bad` set aside) in the folder.
    func coverageFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { name in
            (name.count == 19 && name.hasSuffix(".coverage") || name.count == 23 && name.hasSuffix(".coverage.bad"))
                && name.prefix(10).enumerated().allSatisfy { index, ch in
                    [4, 7].contains(index) ? ch == "-" : ch.isASCII && ch.isNumber
                }
        }
    }
}
