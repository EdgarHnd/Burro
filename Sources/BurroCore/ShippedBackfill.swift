// Writes the daily summaries for a range of past days in one go (`burro-inspect
// --shipped-backfill`). GitHub is read once for the whole range (ShippedHistory); days with
// nothing merged, released or pushed are recorded without a model call; every other day costs one
// small Claude call. Each finished day is saved to the same cache the app reads, marked final, so
// the app shows it with no call of its own and a stopped backfill resumes where it left off.
import Foundation

public enum ShippedBackfill {
    public struct Report: Sendable {
        public var days = 0
        public var alreadyDone = 0
        public var empty = 0
        public var toWrite = 0
        public var written = 0
        public var failed: [(day: String, reason: String)] = []
        public var cost = 0.0
        public var characters = 0
        public var activityComplete = true
        public var requests = 0
    }

    /// Serialises cache writes from the parallel calls.
    actor Store {
        var cache: ShippedSummaryCache
        let url: URL
        init(cache: ShippedSummaryCache, url: URL) { self.cache = cache; self.url = url }
        func save(_ entry: ShippedSummary.Entry, for id: String) throws {
            cache.store(entry, for: id)
            // Merged with the file: the app may have written today's summary meanwhile.
            cache = try ShippedSummaryCache.save([id: entry], to: url)
        }
    }

    /// `limit` writes at most that many summaries (oldest first); nil for all. `dryRun` reads
    /// GitHub and counts, without calling Claude or writing anything.
    public static func run(repository: String, from: Date, to: Date, dryRun: Bool = false, force: Bool = false, limit: Int? = nil,
                           parallel: Int = 4, cacheURL: URL = ShippedSummaryCache.url, calendar: Calendar = .current,
                           log: @escaping @Sendable (String) -> Void) async -> Result<Report, ShippedReader.Failure> {
        log("Reading GitHub for \(ShippedSummary.stamp(from, "yyyy-MM-dd", calendar: calendar)) to \(ShippedSummary.stamp(to, "yyyy-MM-dd", calendar: calendar))…")
        let range: ShippedHistory.Range
        switch await ShippedHistory.load(repository: repository, from: from, to: to, calendar: calendar, log: log) {
        case .success(let value): range = value
        case .failure(let failure): return .failure(failure)
        }
        let days = ShippedHistory.days(range, calendar: calendar)
        log("Read \(range.mergedCount) merged pull requests and \(range.activityCount) activity events in \(range.requests) GitHub calls\(range.activityComplete ? "" : " (the activity feed stopped early: some pushes may be missing)").")

        let store = Store(cache: ShippedSummaryCache.read(from: cacheURL), url: cacheURL)
        var report = Report()
        report.days = days.count
        report.activityComplete = range.activityComplete
        report.requests = range.requests
        var queue: [(id: String, day: ShippedDay, digest: ShippedDigest, input: String)] = []
        for day in days {
            let id = ShippedSummary.cacheID(repository: repository, day: day.day, calendar: calendar)
            if !force, await store.cache.entries[id]?.isSettled == true { report.alreadyDone += 1; continue }
            let digest = ShippedDigest(day, calendar: calendar)
            guard let input = digest.input else {
                report.empty += 1
                if !dryRun {
                    try? await store.save(ShippedSummary.Entry(key: "", text: "", model: ShippedSummary.model, createdAt: Date(), digest: digest, final: true), for: id)
                }
                continue
            }
            // Already written from exactly these items (by the app, say): keep it, now for good.
            if !force, var entry = await store.cache.entries[id], entry.key == ShippedSummary.key(input: input) {
                entry.digest = digest; entry.final = true
                if !dryRun { try? await store.save(entry, for: id) }
                report.alreadyDone += 1
                continue
            }
            queue.append((id, day, digest, input))
        }
        report.toWrite = queue.count
        report.characters = queue.reduce(0) { $0 + $1.input.count }
        if let limit { queue = Array(queue.prefix(limit)) }
        guard !dryRun, !queue.isEmpty else { return .success(report) }

        let total = queue.count
        var next = 0
        await withTaskGroup(of: (String, String, Result<String, ShippedSummary.Failure>, Double?, ShippedSummary.Entry?).self) { group in
            func start(_ item: (id: String, day: ShippedDay, digest: ShippedDigest, input: String)) {
                group.addTask {
                    let names = Set(item.digest.people.map(\.name))
                    let answer = await Task.detached(priority: .utility) {
                        ShippedSummary.ask(input: item.input, shape: .day, names: names, production: !item.digest.production.isEmpty)
                    }.value
                    let entry = (try? answer.result.get()).map {
                        ShippedSummary.Entry(key: ShippedSummary.key(input: item.input), text: $0, model: ShippedSummary.model, createdAt: Date(),
                                             digest: item.digest, final: true)
                    }
                    return (item.id, item.digest.date, answer.result, answer.cost, entry)
                }
            }
            while next < min(parallel, total) { start(queue[next]); next += 1 }
            for await (id, date, result, cost, entry) in group {
                report.cost += cost ?? 0
                switch result {
                case .success:
                    if let entry { try? await store.save(entry, for: id) }
                    report.written += 1
                case .failure(let failure):
                    report.failed.append((date, failure.short + (failure.detail.isEmpty ? "" : ": " + failure.detail)))
                    if failure == .noClaude || failure == .signedOut { group.cancelAll(); next = total }
                }
                let done = report.written + report.failed.count
                if done % 10 == 0 || done == total {
                    log("\(done)/\(total) days · \(report.written) written, \(report.failed.count) failed · $\(String(format: "%.3f", report.cost))")
                }
                if next < total { start(queue[next]); next += 1 }
            }
        }
        return .success(report)
    }

    /// Writes the weekly and monthly reports for every closed week and month touching the range,
    /// from the cached days alone (no GitHub). Periods with days not read yet are left for later.
    public static func periods(repository: String, from: Date, to: Date, dryRun: Bool = false, force: Bool = false, parallel: Int = 4,
                               cacheURL: URL = ShippedSummaryCache.url, calendar: Calendar = .current,
                               log: @escaping @Sendable (String) -> Void) async -> Report {
        let store = Store(cache: ShippedSummaryCache.read(from: cacheURL), url: cacheURL)
        let entries = await store.cache.entries
        var periods: [ShippedPeriod] = []
        for kind in ShippedPeriod.Kind.allCases {
            var period = ShippedPeriod.containing(to, kind, calendar: calendar)
            while period.end > calendar.startOfDay(for: from) {
                if period.isClosed(calendar: calendar) { periods.append(period) }
                period = period.previous(calendar: calendar)
            }
        }
        var report = Report()
        report.days = periods.count
        var queue: [(id: String, report: ShippedPeriodReport)] = []
        for period in periods.reversed() {
            let id = period.cacheID(repository: repository, calendar: calendar)
            if !force, entries[id]?.isSettled == true { report.alreadyDone += 1; continue }
            let built = ShippedPeriodReport(period: period, repository: repository, entries: entries, through: period.end.addingTimeInterval(-3600), calendar: calendar)
            // Already written from exactly these days: keep it, now for good.
            if !force, var entry = entries[id], let key = built.key, entry.key == key, built.missing == 0 {
                entry.final = true
                if !dryRun { try? await store.save(entry, for: id) }
                report.alreadyDone += 1
                continue
            }
            guard built.missing == 0 else {
                report.failed.append((id, "\(ShippedDay.count(built.missing, "day")) not read yet"))
                continue
            }
            guard built.input != nil else {
                report.empty += 1
                if !dryRun { try? await store.save(ShippedSummary.Entry(key: "", text: "", model: ShippedSummary.model, createdAt: Date(), final: true), for: id) }
                continue
            }
            queue.append((id, built))
        }
        report.toWrite = queue.count
        report.characters = queue.reduce(0) { $0 + ($1.report.input?.count ?? 0) }
        guard !dryRun, !queue.isEmpty else { return report }
        var next = 0
        await withTaskGroup(of: (String, Result<String, ShippedSummary.Failure>, Double?, String?).self) { group in
            func start(_ item: (id: String, report: ShippedPeriodReport)) {
                group.addTask {
                    let answer = await Task.detached(priority: .utility) { item.report.generate() }.value
                    return (item.id, answer.result, answer.cost, item.report.key)
                }
            }
            while next < min(parallel, queue.count) { start(queue[next]); next += 1 }
            for await (id, result, cost, key) in group {
                report.cost += cost ?? 0
                switch result {
                case .success(let text):
                    try? await store.save(ShippedSummary.Entry(key: key ?? "", text: text, model: ShippedSummary.model, createdAt: Date(), final: true), for: id)
                    report.written += 1
                case .failure(let failure):
                    report.failed.append((id, failure.short + ": " + failure.detail))
                    if failure == .noClaude || failure == .signedOut { group.cancelAll(); next = queue.count }
                }
                let done = report.written + report.failed.count
                if done % 10 == 0 { log("\(done)/\(queue.count) weeks and months · $\(String(format: "%.3f", report.cost))") }
                if next < queue.count { start(queue[next]); next += 1 }
            }
        }
        return report
    }
}
