// The Usage page's local token picture for this Mac: the last seven days (today included) and
// today's tokens by model, with an estimated API value at the reference rates. The Rust usage
// worker scans Codex and Claude logs touched in those seven days (one request per provider, older
// cached files stay warm); Swift only fills in empty days, names models and prices them. Grok only
// reports cumulative session counters, so it is not part of this. Returns nil when the worker is
// unavailable; the page then says local figures are unavailable rather than parsing in-process.
// `UsageBreakdown` turns per-project totals (Home's project activity) into the page's rows.
import Foundation

public struct UsageWeek: Sendable, Equatable {
    public struct Day: Sendable, Equatable, Identifiable {
        public var date: Date
        public var tokens: Double
        public var apiValue: Double
        public var id: Date { date }
        public init(date: Date, tokens: Double = 0, apiValue: Double = 0) { self.date = date; self.tokens = tokens; self.apiValue = apiValue }
    }
    public struct Model: Sendable, Equatable, Identifiable {
        public var provider: UsageProvider
        public var model: String
        public var tokens: Double
        /// Estimated API value; nil when the model isn't in the reference rates.
        public var apiValue: Double?
        public var id: String { provider.rawValue + ":" + model }
        /// "Claude · Opus 5.5", "Codex · GPT-5.5".
        public var title: String { provider.title + " · " + UsageWeek.modelTitle(model) }
        public init(provider: UsageProvider, model: String, tokens: Double, apiValue: Double?) {
            self.provider = provider; self.model = model; self.tokens = tokens; self.apiValue = apiValue
        }
    }
    /// Seven days, oldest first, the last one today.
    public var days: [Day]
    /// Today's models, most tokens first.
    public var todayModels: [Model]
    public var records: Int
    public var pricedRecords: Int
    /// A scan limit was reached or a provider didn't answer.
    public var partial: Bool
    public var scannedAt: Date

    public var tokens: Double { days.reduce(0) { $0 + $1.tokens } }
    public var apiValue: Double { days.reduce(0) { $0 + $1.apiValue } }
    public var today: Day? { days.last }

    /// "claude-opus-5-5" reads "Opus 5.5", "gpt-5.5" reads "GPT-5.5"; other names stay as they are.
    public static func modelTitle(_ model: String) -> String {
        if let known = LaunchModel.claude.first(where: { $0.id == model }) { return known.title }
        if model.hasPrefix("claude-") {
            let parts = model.dropFirst(7).split(separator: "-")
            guard let family = parts.first else { return model }
            let version = parts.dropFirst().filter { $0.count <= 2 && $0.allSatisfy(\.isNumber) }.joined(separator: ".")
            return family.capitalized + (version.isEmpty ? "" : " " + version)
        }
        if model.lowercased().hasPrefix("gpt-") { return "GPT-" + model.dropFirst(4) }
        return model
    }
}

public enum UsageWeekScanner {
    /// The seven days ending today, from the usage worker; nil when it is unavailable.
    public static func scan(profiles: [UsageProvider: String] = [:], now: Date = Date(), calendar: Calendar = .current) -> UsageWeek? {
        let worker = AgentLogWorker.usage
        let start = weekStart(now: now, calendar: calendar)
        let answers = [UsageProvider.codex, .claude].map { provider -> Answer in
            let roots = LocalUsageScanner.roots(provider: provider, profile: profiles[provider])
            let request = UsageLogRequest(provider: provider, roots: roots, now: now, calendar: calendar, projectsSince: start)
            return Answer(provider: provider, batch: worker.exchange([], usage: request)?.usage.map { ($0.buckets, $0.partial) })
        }
        return build(answers, now: now, calendar: calendar)
    }

    static func weekStart(now: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? calendar.startOfDay(for: now)
    }

    /// One provider's reply: its day-and-model buckets, or nil when the worker didn't answer.
    struct Answer {
        var provider: UsageProvider
        var batch: (buckets: [UsageLogBucket], partial: Bool)?
    }

    /// Folds each provider's day-and-model buckets into the week; nil when no provider answered.
    static func build(_ answers: [Answer], now: Date, calendar: Calendar) -> UsageWeek? {
        let todayStart = calendar.startOfDay(for: now)
        let starts = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0 - 6, to: todayStart) }
        var days = starts.map { UsageWeek.Day(date: $0) }
        var models: [String: UsageWeek.Model] = [:]
        var records = 0, priced = 0, partial = false, answered = false
        for reply in answers {
            let provider = reply.provider
            guard let answer = reply.batch else { partial = true; continue }
            answered = true
            partial = partial || answer.partial
            for bucket in answer.buckets {
                let date = Date(timeIntervalSince1970: bucket.date)
                guard let index = starts.firstIndex(where: { abs($0.timeIntervalSince(date)) < 1 }) else { continue }
                let record = bucket.record
                let value = record.apiValue
                days[index].tokens += record.total
                days[index].apiValue += value ?? 0
                records += bucket.recordCount
                if value != nil { priced += bucket.recordCount }
                guard index == starts.count - 1 else { continue }
                let key = provider.rawValue + ":" + bucket.model
                var model = models[key] ?? UsageWeek.Model(provider: provider, model: bucket.model, tokens: 0, apiValue: value == nil ? nil : 0)
                model.tokens += record.total
                if let value { model.apiValue = (model.apiValue ?? 0) + value }
                models[key] = model
            }
        }
        guard answered else { return nil }
        let ordered = models.values.sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.id < $1.id }
        return UsageWeek(days: days, todayModels: ordered, records: records, pricedRecords: priced, partial: partial, scannedAt: now)
    }
}

/// One labelled bar on the page: a project or a model with its tokens and estimated cost.
public struct UsageBreakdownRow: Sendable, Equatable, Identifiable {
    public var title: String
    public var tokens: Double
    public var apiValue: Double?
    /// The catch-all row ("Other folders"), drawn quieter.
    public var isRest: Bool
    public var id: String { (isRest ? "rest:" : "row:") + title }
    public init(title: String, tokens: Double, apiValue: Double?, isRest: Bool = false) {
        self.title = title; self.tokens = tokens; self.apiValue = apiValue; self.isRest = isRest
    }
}

public enum UsageBreakdown {
    /// Named projects, most tokens first, at most `limit` rows; the smaller ones and whatever today's
    /// total holds outside any known project fold into one "Other folders" row. Rows under 1 token drop.
    public static func projects(_ named: [(name: String, tokens: Double, apiValue: Double)], total: Double, totalValue: Double,
                                limit: Int = 5) -> [UsageBreakdownRow] {
        let sorted = named.filter { $0.tokens >= 1 }.sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.name < $1.name }
        var rows = sorted.prefix(limit).map { UsageBreakdownRow(title: $0.name, tokens: $0.tokens, apiValue: $0.apiValue) }
        let shownTokens = rows.reduce(0) { $0 + $1.tokens }, shownValue = rows.reduce(0) { $0 + ($1.apiValue ?? 0) }
        let restTokens = max(0, total - shownTokens), restValue = max(0, totalValue - shownValue)
        if restTokens >= 1 { rows.append(UsageBreakdownRow(title: "Other folders", tokens: restTokens, apiValue: restValue, isRest: true)) }
        return rows
    }
}
