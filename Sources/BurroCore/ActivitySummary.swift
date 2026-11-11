// One day of tracked activity rolled up for the Today page and Home: focused time, time per
// category, top apps and sites, the latest activities, each hour's main category, and the
// timeline's blocks and focus stretches (ActivityTimeline.swift). Categories come from the
// current rules, so a rule you change applies to past days as well.
import Foundation

public struct ActivityDay: Sendable, Equatable {
    public struct CategoryTime: Sendable, Equatable, Identifiable {
        public var category: ActivityCategory
        public var seconds: TimeInterval
        public var id: ActivityCategory { category }
    }
    /// An app (by bundle id) or a site (by host) with its time and main category.
    public struct Item: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var category: ActivityCategory
        public var seconds: TimeInterval
    }
    /// Consecutive time in one app and site, labelled by its longest window title.
    public struct Entry: Sendable, Equatable, Identifiable {
        public var start: Date
        public var end: Date
        public var bundleID: String
        public var app: String
        public var label: String
        public var host: String?
        public var category: ActivityCategory
        public var id: String { "\(bundleID)|\(start.timeIntervalSince1970)" }
    }

    public var day: Date
    public var total: TimeInterval
    public var categories: [CategoryTime]
    public var apps: [Item]
    public var sites: [Item]
    public var entries: [Entry]
    /// One cell per hour of the day (23 or 25 on DST days): the category with the most time.
    public var hourly: [ActivityCategory?]
    /// The day timeline: readable blocks, idle gaps left out.
    public var blocks: [ActivityBlock]
    public var focus: ActivityFocus
    /// Everything except Break.
    public var focused: TimeInterval { categories.filter { $0.category != .break }.reduce(0) { $0 + $1.seconds } }

    public static func build(spans input: [ActivitySpan], rules: ActivityRules, day: Date, calendar: Calendar = .current) -> ActivityDay {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        // Clip to the day and trim overlaps (a live span can repeat one just written).
        var spans: [ActivitySpan] = []
        for var span in input.sorted(by: { $0.start < $1.start }) {
            span.start = max(span.start, start, spans.last?.end ?? start)
            span.end = min(span.end, end)
            if span.end > span.start { spans.append(span) }
        }
        let categorized = spans.map { ($0, rules.category(bundleID: $0.bundleID, host: $0.host, title: $0.title, isPrivate: $0.isPrivate, stored: $0.category)) }

        var perCategory: [ActivityCategory: TimeInterval] = [:]
        var apps: [String: (name: String, seconds: TimeInterval, categories: [ActivityCategory: TimeInterval])] = [:]
        var sites: [String: (seconds: TimeInterval, categories: [ActivityCategory: TimeInterval])] = [:]
        for (span, category) in categorized {
            perCategory[category, default: 0] += span.duration
            apps[span.bundleID, default: (span.app, 0, [:])].seconds += span.duration
            apps[span.bundleID]?.categories[category, default: 0] += span.duration
            if let host = span.host, host != ActivityPrivacy.privateHost {
                sites[host, default: (0, [:])].seconds += span.duration
                sites[host]?.categories[category, default: 0] += span.duration
            }
        }
        let main = { (times: [ActivityCategory: TimeInterval]) in times.max { $0.value < $1.value }?.key ?? .other }

        let hours = Int((end.timeIntervalSince(start) / 3600).rounded(.up))
        let hourly: [ActivityCategory?] = (0..<hours).map { index in
            let from = start.addingTimeInterval(Double(index) * 3600), to = from.addingTimeInterval(3600)
            var times: [ActivityCategory: TimeInterval] = [:]
            for (span, category) in categorized where span.end > from && span.start < to {
                times[category, default: 0] += min(span.end, to).timeIntervalSince(max(span.start, from))
            }
            return times.max { $0.value < $1.value }?.key
        }

        var entries: [Entry] = []
        var titles: [String: TimeInterval] = [:]
        for (span, category) in categorized {
            if let last = entries.last, last.bundleID == span.bundleID, last.host == span.host, last.category == category,
               span.start.timeIntervalSince(last.end) <= 60 {
                entries[entries.count - 1].end = span.end
            } else {
                titles = [:]
                entries.append(Entry(start: span.start, end: span.end, bundleID: span.bundleID, app: span.app, label: "",
                                     host: span.host, category: category))
            }
            if let title = span.title { titles[title, default: 0] += span.duration }
            let index = entries.count - 1
            entries[index].label = titles.max { $0.value < $1.value }?.key ?? entries[index].host ?? entries[index].app
        }

        return ActivityDay(
            day: start, total: spans.reduce(0) { $0 + $1.duration },
            categories: perCategory.map { CategoryTime(category: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds },
            apps: apps.map { Item(id: $0.key, name: $0.value.name, category: main($0.value.categories), seconds: $0.value.seconds) }
                .sorted { $0.seconds > $1.seconds },
            sites: sites.map { Item(id: $0.key, name: $0.key, category: main($0.value.categories), seconds: $0.value.seconds) }
                .sorted { $0.seconds > $1.seconds },
            entries: entries, hourly: hourly,
            blocks: ActivityTimeline.blocks(categorized), focus: ActivityTimeline.focus(categorized))
    }
}
