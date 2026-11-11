// The Today page's day timeline and focus stretches, worked out from a day's categorised spans.
// Pure and deterministic, no AI: a block's title comes only from the app names, sanitised window
// titles and hosts already in the spans. Blocks: consecutive time in one category with gaps under
// 5 minutes; three or more touching runs under 10 minutes each (Claude, Arc, Claude, Arc…) become
// one "Switching between" block that never joins a neighbour; runs under 5 minutes fold into their longer neighbour (Private never folds or joins
// either way); blocks with under a minute of recorded time are left out. A block names its app
// when one app has more than 60% of the time, otherwise the apps it switched between, and takes
// the category with the most time in it. A window title never repeats the app ("Claude · Claude"
// reads "Claude"; a trailing " - Slack" naming the app is dropped). Imported spans (from another
// tracker, already one per activity) are one block each: never joined or folded either way, titled
// by their own title (else the site or app) with the site or app as detail; Private ones read only
// "Private". Focus stretches: non-Break time, joined across gaps or breaks under 2 minutes.
import Foundation

public struct ActivityBlock: Sendable, Equatable, Identifiable {
    public struct App: Sendable, Equatable {
        public var bundleID: String
        public var name: String
        public var seconds: TimeInterval
    }
    public var start: Date
    public var end: Date
    public var category: ActivityCategory
    /// One line: "Xcode · ActivityLog.swift", "Arc · github.com", "Switching between Xcode, Arc and Slack", "Private · Safari".
    public var title: String
    /// The main app's most-seen window title when the title already names its site. Never set for Private.
    public var detail: String?
    /// The block's apps by time, longest first (at most three).
    public var apps: [App]
    /// The app with more than 60% of the block's time, if any; never set for a switching block.
    public var main: App?
    /// The main app's most-seen site, as stored (the title drops a leading "www."). Never set for Private.
    public var host: String?
    /// Recorded time inside the block; short idle gaps between its spans don't count.
    public var seconds: TimeInterval
    public var id: TimeInterval { start.timeIntervalSince1970 }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public struct ActivityFocus: Sendable, Equatable {
    /// Stretches of non-Break time in order.
    public var stretches: [DateInterval]
    /// The longest stretch (the earliest on a tie).
    public var longest: DateInterval? {
        stretches.reduce(nil) { best, next in (best?.duration ?? -1) >= next.duration ? best : next }
    }
    public init(stretches: [DateInterval] = []) { self.stretches = stretches }
}

private extension ActivityCategory {
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

public enum ActivityTimeline {
    /// Spans of one category closer than this join one block; a longer gap is idle and stays empty.
    public static let joinGap: TimeInterval = 300
    /// Runs shorter than this fold into a neighbour so the timeline isn't confetti.
    public static let foldBelow: TimeInterval = 300
    /// This many touching runs in a row, each shorter than `switchBelow`, are one block of switching.
    public static let switchRuns = 3
    public static let switchBelow: TimeInterval = 600
    /// Blocks with less recorded time than this aren't shown (their time still counts in the totals).
    public static let minimumShown: TimeInterval = 60
    /// An app above this share of a block's time names the block.
    public static let mainShare = 0.6
    /// A focus stretch survives gaps (idle, Break or nothing recorded) shorter than this.
    public static let focusInterruption: TimeInterval = 120

    private struct Run {
        var category: ActivityCategory
        var spans: [ActivitySpan]
        /// Time per category, which folded runs can mix.
        var times: [ActivityCategory: TimeInterval]
        /// Short alternating runs merged into one: titled "Switching between…", never joined with a neighbour.
        var switching = false
        /// An imported span, which stays a block of its own.
        var imported: Bool { spans.first?.source != nil }
        var start: Date { spans.first?.start ?? .distantPast }
        var end: Date { spans.map(\.end).max() ?? .distantPast }
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// `spans` must be sorted and non-overlapping, as `ActivityDay.build` leaves them.
    public static func blocks(_ spans: [(span: ActivitySpan, category: ActivityCategory)]) -> [ActivityBlock] {
        var runs: [Run] = []
        for (span, category) in spans {
            if let last = runs.last, !last.imported, span.source == nil, last.category == category, span.start.timeIntervalSince(last.end) < joinGap {
                runs[runs.count - 1].spans.append(span)
                runs[runs.count - 1].times[category, default: 0] += span.duration
            } else {
                runs.append(Run(category: category, spans: [span], times: [category: span.duration]))
            }
        }

        func live(_ index: Int) -> Bool { runs.indices.contains(index) && runs[index].category != .private && !runs[index].imported }
        func touching(_ a: Int, _ b: Int) -> Bool {
            guard live(a), live(b) else { return false }
            let (first, second) = a < b ? (runs[a], runs[b]) : (runs[b], runs[a])
            return second.start.timeIntervalSince(first.end) < joinGap
        }
        func merge(_ range: ClosedRange<Int>) {
            var merged = runs[range.lowerBound]
            for index in range.dropFirst() {
                merged.spans += runs[index].spans
                merged.times.merge(runs[index].times, uniquingKeysWith: +)
            }
            merged.spans.sort { $0.start < $1.start }
            merged.category = merged.times.max { $0.value != $1.value ? $0.value < $1.value : $0.key.order > $1.key.order }?.key ?? merged.category
            runs.replaceSubrange(range, with: [merged])
        }
        // Neighbours of one category side by side (after a merge or a fold) join; switching blocks stay apart.
        func joinNeighbours() {
            var i = 1
            while i < runs.count {
                if touching(i - 1, i), runs[i].category == runs[i - 1].category, !runs[i].switching, !runs[i - 1].switching {
                    merge(i - 1...i)
                } else { i += 1 }
            }
        }

        // A stretch of short alternating runs is one block of switching.
        var i = 0
        while i < runs.count {
            var j = i
            while live(j), runs[j].duration < switchBelow, j == i || touching(j - 1, j) { j += 1 }
            if j - i >= switchRuns { merge(i...j - 1); runs[i].switching = true }
            i = j - i >= switchRuns ? i + 1 : max(i + 1, j)
        }
        joinNeighbours()

        // Fold the shortest short run into its longer touching neighbour until none is left.
        while true {
            let candidates = runs.indices.filter { runs[$0].duration < foldBelow && (touching($0, $0 - 1) || touching($0, $0 + 1)) }
            guard let index = candidates.min(by: { runs[$0].duration < runs[$1].duration }) else { break }
            let previous = touching(index, index - 1) ? index - 1 : nil, next = touching(index, index + 1) ? index + 1 : nil
            let target: Int
            if let previous, let next { target = runs[next].duration > runs[previous].duration ? next : previous } else { target = previous ?? next! }
            let category = runs[target].category, switching = runs[target].switching
            merge(min(index, target)...max(index, target))
            runs[min(index, target)].category = category
            runs[min(index, target)].switching = switching
            joinNeighbours()
        }
        return runs.map(block).filter { $0.seconds.rounded() >= minimumShown }
    }

    /// A window title as a block shows it: without a trailing " - App" / " — App" naming the app, and
    /// nil when all that's left is the app's own name.
    public static func displayTitle(_ title: String?, app: String) -> String? {
        guard var text = title?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if !app.isEmpty {
            for separator in [" - ", " — ", " – "] {
                if let range = text.range(of: separator + app, options: [.caseInsensitive, .anchored, .backwards]) {
                    text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }
        return text.isEmpty || text.caseInsensitiveCompare(app) == .orderedSame ? nil : text
    }

    private static func block(_ run: Run) -> ActivityBlock {
        let ranked = { (times: [String: TimeInterval]) in times.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key } }
        var appTimes: [String: TimeInterval] = [:], names: [String: String] = [:]
        for span in run.spans {
            appTimes[span.bundleID, default: 0] += span.duration
            names[span.bundleID] = names[span.bundleID] ?? span.app
        }
        let total = run.spans.reduce(0) { $0 + $1.duration }
        let apps = ranked(appTimes).map { ActivityBlock.App(bundleID: $0.key, name: names[$0.key] ?? $0.key, seconds: $0.value) }
        let main = run.switching ? nil : apps.first.flatMap { total > 0 && $0.seconds > mainShare * total ? $0 : nil }
        let category = run.times.max { $0.value != $1.value ? $0.value < $1.value : $0.key.order > $1.key.order }?.key ?? run.category
        var block = ActivityBlock(start: run.start, end: run.end, category: category, title: "", detail: nil,
                                  apps: Array(apps.prefix(3)), main: main, host: nil, seconds: total)
        if run.imported, let span = run.spans.first {
            if run.category == .private { block.title = ActivityPrivacy.privateHost; return block }
            let site = span.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            block.title = span.title ?? site ?? span.app
            block.detail = span.title == nil ? nil : site ?? span.app
            block.host = span.host
            return block
        }
        if run.category == .private {
            block.title = "Private · " + (apps.first?.name ?? "")
            return block
        }
        guard let main else {
            let shown = apps.prefix(3).map(\.name)
            block.title = "Switching between " + (shown.count > 1 ? shown.dropLast().joined(separator: ", ") + " and " + shown.last! : shown.joined())
            return block
        }
        var hosts: [String: TimeInterval] = [:], titles: [String: TimeInterval] = [:]
        for span in run.spans where span.bundleID == main.bundleID {
            if let host = span.host, host != ActivityPrivacy.privateHost { hosts[host, default: 0] += span.duration }
            if let title = displayTitle(span.title, app: main.name) { titles[title, default: 0] += span.duration }
        }
        let host = ranked(hosts).first?.key, title = ranked(titles).first?.key
        block.host = host
        if let host {
            block.title = "\(main.name) · \(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)"
            block.detail = title
        } else {
            block.title = title.map { "\(main.name) · \($0)" } ?? main.name
        }
        return block
    }

    public static func focus(_ spans: [(span: ActivitySpan, category: ActivityCategory)]) -> ActivityFocus {
        var stretches: [DateInterval] = []
        for (span, category) in spans where category != .break && span.end > span.start {
            if let last = stretches.last, span.start.timeIntervalSince(last.end) < focusInterruption {
                stretches[stretches.count - 1] = DateInterval(start: last.start, end: max(last.end, span.end))
            } else {
                stretches.append(DateInterval(start: span.start, end: span.end))
            }
        }
        return ActivityFocus(stretches: stretches)
    }
}
