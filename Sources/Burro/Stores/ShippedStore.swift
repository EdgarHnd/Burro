// What shipped on GitHub per day for the main project, for the Today page. Read through the GitHub
// CLI only while the page is on screen: today at most every five minutes, yesterday again until
// half an hour after midnight (late merges), older days once. Kept in memory only; the written
// summary on top is cached on disk per repository and day and rewritten only when the day's
// items change (one Claude call per change, never per refresh).
import Foundation
import Observation
import BurroCore

@MainActor @Observable final class ShippedStore {
    enum State: Equatable {
        case loading
        case loaded(ShippedDay)
        case failed(ShippedReader.Failure)
    }

    /// The written summary for a day: the latest text (maybe from before the day's items last
    /// changed), whether it's current, whether a new one is being written, and why not.
    struct Summary: Equatable {
        var text: String?
        var current = false
        var writing = false
        var problem: ShippedSummary.Failure?
    }

    /// A week or month report: the days put together, and its summary.
    struct Period: Equatable {
        var report: ShippedPeriodReport
        var summary: Summary?
    }

    private(set) var states: [Date: State] = [:]
    private(set) var summaries: [Date: Summary] = [:]
    /// Week and month reports by cache id (a week so far has its own).
    private(set) var periods: [String: Period] = [:]
    /// Bumped whenever a day's items change, so an open week or month report refreshes.
    private(set) var digestVersion = 0
    /// Bumped whenever the cache changes, so views reading it (the recap) redraw.
    private(set) var cacheVersion = 0
    /// The main project's checkout, set by the app store.
    @ObservationIgnored var project: () -> String? = { nil }
    @ObservationIgnored private var fetchedAt: [Date: Date] = [:]
    @ObservationIgnored private var running: Set<Date> = []
    @ObservationIgnored private var repositories: [String: String?] = [:]
    @ObservationIgnored private var currentPath: String?
    @ObservationIgnored private let calendar = Calendar.current
    @ObservationIgnored private var cache: ShippedSummaryCache?
    /// Each loaded day's items, for the week and month reports while those days are still open.
    @ObservationIgnored private var digests: [Date: ShippedDigest] = [:]
    @ObservationIgnored private var periodWriting: [String: String] = [:]
    /// Per day, the key of the day's current items and of the summary being written.
    @ObservationIgnored private var latestKey: [Date: String] = [:]
    @ObservationIgnored private var writing: [Date: String] = [:]
    /// Keys that failed, and when: tried again after ten minutes, or at once on Retry.
    @ObservationIgnored private var failedAt: [String: Date] = [:]

    func state(_ day: Date) -> State? { states[calendar.startOfDay(for: day)] }
    func shipped(_ day: Date) -> ShippedDay? {
        if case .loaded(let value) = state(day) { return value }
        return nil
    }
    func summary(_ day: Date) -> Summary? { summaries[calendar.startOfDay(for: day)] }

    func refresh(_ date: Date, force: Bool = false) {
        let day = calendar.startOfDay(for: date), now = Date()
        guard let path = project() else { return }
        // Another main project: what was read belongs to the old one.
        if path != currentPath {
            currentPath = path; states = [:]; fetchedAt = [:]; running = []
            summaries = [:]; latestKey = [:]; writing = [:]; digests = [:]; periods = [:]; periodWriting = [:]; timeline = []
        }
        guard !running.contains(day), force || due(day, now: now) else { return }
        running.insert(day)
        if states[day] == nil || { if case .failed = states[day] { return true }; return false }() { states[day] = .loading }
        let known = repositories[path]
        Task { [weak self] in
            let repository: String?
            if let known { repository = known } else {
                repository = await Task.detached(priority: .utility) { ShippedReader.repository(at: path) }.value
            }
            let result: Result<ShippedDay, ShippedReader.Failure> = if let repository {
                await ShippedReader.load(day: day, repository: repository)
            } else { .failure(.noRepository) }
            guard let self, self.currentPath == path else { return }
            self.repositories[path] = repository
            self.running.remove(day)
            self.fetchedAt[day] = Date()
            switch result {
            case .success(let shipped):
                self.states[day] = .loaded(shipped)
                self.summarize(day, shipped, path: path)
            case .failure(let failure):
                // Keep what was shown when a later refresh fails; say so only when there's nothing.
                if case .loaded = self.states[day] { return }
                self.states[day] = .failed(failure)
            }
        }
    }

    /// Writes the summary again now, after a failure.
    func retrySummary(_ date: Date) {
        let day = calendar.startOfDay(for: date)
        guard let path = currentPath, let shipped = shipped(day) else { return }
        if let key = latestKey[day] { failedAt[key] = nil }
        summarize(day, shipped, path: path)
    }

    /// Shows the cached summary when it is final (written after the day was over, by the app or a
    /// backfill) or was written from these exact items; otherwise asks Claude once for them,
    /// keeping the older text on screen meanwhile. Everything slow runs detached.
    private func summarize(_ day: Date, _ shipped: ShippedDay, path: String) {
        Task { [weak self] in
            let prepared = await Task.detached(priority: .utility) { () -> (digest: ShippedDigest, input: String?, key: String?, id: String) in
                let digest = ShippedDigest(shipped)
                let input = digest.input
                return (digest, input, input.map(ShippedSummary.key(input:)), ShippedSummary.cacheID(repository: shipped.repository, day: shipped.day))
            }.value
            guard let self, self.currentPath == path else { return }
            let (digest, input, key, id) = prepared
            if self.digests[day] != digest { self.digests[day] = digest; self.digestVersion += 1 }
            self.latestKey[day] = key
            if self.show(day, id: id, key: key, digest: digest) { return }
            // Not in memory: read the file (first use, or a backfill or another Burro wrote it).
            await self.loadCache()
            guard self.currentPath == path, self.latestKey[day] == key else { return }
            if self.show(day, id: id, key: key, digest: digest) { return }
            guard let input, let key else {
                // Nothing to summarise. Once the day is over, note that it was read (no model call).
                self.summaries[day] = nil
                if ShippedSummary.isClosed(day) {
                    self.save(ShippedSummary.Entry(key: "", text: "", model: ShippedSummary.model, createdAt: Date(), digest: digest, final: true), for: id)
                }
                return
            }
            let previous = self.cache?.entries[id]?.text.nonEmpty ?? self.summaries[day]?.text
            guard self.writing[day] != key else { return }
            if let failed = self.failedAt[key], Date().timeIntervalSince(failed) < 600 { return }
            self.writing[day] = key
            self.summaries[day] = Summary(text: previous, current: false, writing: true, problem: nil)
            let result = await Task.detached(priority: .utility) { ShippedSummary.generate(for: shipped, input: input) }.value
            guard self.currentPath == path else { return }
            if self.writing[day] == key { self.writing[day] = nil }
            // Items changed again while Claude wrote: that newer call owns the day.
            guard self.latestKey[day] == key else { return }
            switch result {
            case .success(let text):
                self.save(ShippedSummary.Entry(key: key, text: text, model: ShippedSummary.model, createdAt: Date(), digest: digest,
                                               final: ShippedSummary.isClosed(day)), for: id)
                self.summaries[day] = Summary(text: text, current: true)
            case .failure(let failure):
                self.failedAt[key] = Date()
                self.summaries[day] = Summary(text: previous, current: false, writing: false, problem: failure)
            }
        }
    }

    /// The main project's GitHub repository, once known.
    var repository: String? { currentPath.flatMap { repositories[$0] ?? nil } }

    /// A week or month up to `through` (a week so far), or all of it.
    func period(_ period: ShippedPeriod, through: Date = Date()) -> Period? {
        guard let repository else { return nil }
        return periods[ShippedPeriodReport.cacheID(period: period, repository: repository, through: min(through, Date()))]
    }

    /// A day's written summary, from what the app read or the cache (backfilled days included).
    func daySummary(_ date: Date) -> String? {
        _ = cacheVersion
        let day = calendar.startOfDay(for: date)
        if let summary = summaries[day], summary.current, let text = summary.text { return text }
        guard let repository, let entry = cache?.entries[ShippedSummary.cacheID(repository: repository, day: day)] else { return nil }
        return entry.text.isEmpty ? nil : entry.text
    }

    /// A day's items: as just read, or from the cache.
    func dayDigest(_ date: Date) -> ShippedDigest? {
        _ = cacheVersion
        let day = calendar.startOfDay(for: date)
        if let digest = digests[day] { return digest }
        guard let repository else { return nil }
        return cache?.entries[ShippedSummary.cacheID(repository: repository, day: day)]?.digest
    }

    /// Whether the cache has settled that day (a summary, or a note that nothing happened).
    func hasDay(_ date: Date) -> Bool {
        _ = cacheVersion
        guard let repository else { return false }
        return cache?.entries[ShippedSummary.cacheID(repository: repository, day: date)] != nil
    }

    /// The recap under a day: the day before, its week so far and the week before. Reads the
    /// day before from GitHub only when nothing is cached for it; the weeks come from the cache.
    func refreshRecap(_ date: Date) {
        let day = calendar.startOfDay(for: date)
        guard repository != nil else { return }
        let before = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        Task { [weak self] in
            guard let self else { return }
            if self.cache == nil { await self.loadCache() }
            if !self.hasDay(before), self.summaries[before] == nil { self.refresh(before) }
            let week = ShippedPeriod.containing(day, .week)
            if week.start < day { self.refreshPeriod(week, through: day, reload: false) }
            self.refreshPeriod(week.previous(), reload: false)
        }
    }

    /// The months shown on the Timeline page, newest first, from the first recorded day.
    private(set) var timeline: [ShippedPeriod] = []

    /// Puts every month and week together from the cache (one read of the file); summaries are
    /// written later, per month, as each comes into view (`summarize`).
    func refreshTimeline() {
        guard let repository else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.loadCache()
            let entries = self.cache?.entries ?? [:], live = self.digests
            let built = await Task.detached(priority: .utility) { () -> ([ShippedPeriod], [String: ShippedPeriodReport]) in
                let prefix = repository + " "
                let days = entries.keys.filter { $0.hasPrefix(prefix) && $0.count == prefix.count + 10 }.compactMap { key -> Date? in
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
                    return formatter.date(from: String(key.dropFirst(prefix.count)))
                }
                guard let first = days.min() else { return ([], [:]) }
                var months: [ShippedPeriod] = []
                var month = ShippedPeriod.containing(Date(), .month)
                while month.end > first { months.append(month); month = month.previous() }
                var reports: [String: ShippedPeriodReport] = [:]
                for month in months {
                    for period in [month] + month.weeks() {
                        let report = ShippedPeriodReport(period: period, repository: repository, entries: entries, live: live)
                        reports[report.cacheID] = report
                    }
                }
                return (months, reports)
            }.value
            for (id, report) in built.1 {
                var state = self.periods[id] ?? Period(report: report)
                state.report = report
                if let text = report.summary { state.summary = Summary(text: text, current: true) }
                self.periods[id] = state
            }
            self.timeline = built.0
        }
    }

    /// Writes the summaries a month on the Timeline still lacks (its own and its weeks'): once
    /// each for a closed one, again as days arrive for the current ones.
    func summarize(_ month: ShippedPeriod) {
        for period in [month] + month.weeks() where self.period(period)?.summary?.current != true {
            refreshPeriod(period, reload: false)
        }
    }

    /// Puts a week or month (up to `through`) together from the cached days and the days just
    /// read, shows its cached summary when it's final or written from these exact days, and
    /// otherwise asks Claude once. No GitHub reads: days nobody opened or backfilled count as not read.
    func refreshPeriod(_ period: ShippedPeriod, through: Date = Date(), reload: Bool = true) {
        guard let path = currentPath, let repository else { return }
        Task { [weak self] in
            guard let self else { return }
            // From disk: a backfill may have written days or periods meanwhile.
            if reload || self.cache == nil { await self.loadCache() }
            let entries = self.cache?.entries ?? [:], live = self.digests
            let last = min(through, Date())
            let report = await Task.detached(priority: .utility) {
                ShippedPeriodReport(period: period, repository: repository, entries: entries, live: live, through: last)
            }.value
            guard self.currentPath == path else { return }
            let id = report.cacheID
            let entry = self.cache?.entries[id]
            var state = Period(report: report, summary: self.periods[id]?.summary)
            if let cached = report.cached(entries) {
                state.summary = cached.text.isEmpty ? nil : Summary(text: cached.text, current: true)
                self.periods[id] = state
                if !cached.isFinal, report.isFinal(), var upgraded = entry { upgraded.final = true; self.save(upgraded, for: id) }
                return
            }
            guard let key = report.key else { state.summary = nil; self.periods[id] = state; return }
            let previous = entry?.text.nonEmpty ?? state.summary?.text
            guard self.periodWriting[id] != key else { self.periods[id] = state; return }
            if let failed = self.failedAt[key], Date().timeIntervalSince(failed) < 600 { self.periods[id] = state; return }
            self.periodWriting[id] = key
            state.summary = Summary(text: previous, current: false, writing: true)
            self.periods[id] = state
            let answer = await Task.detached(priority: .utility) { report.generate() }.value
            guard self.currentPath == path else { return }
            if self.periodWriting[id] == key { self.periodWriting[id] = nil }
            // Newer days arrived while Claude wrote: the newer call owns the period.
            guard self.periods[id]?.report.key == key else { return }
            switch answer.result {
            case .success(let text):
                self.save(ShippedSummary.Entry(key: key, text: text, model: ShippedSummary.model, createdAt: Date(), final: report.isFinal()), for: id)
                self.periods[id]?.summary = Summary(text: text, current: true)
            case .failure(let failure):
                self.failedAt[key] = Date()
                self.periods[id]?.summary = Summary(text: previous, current: false, writing: false, problem: failure)
            }
        }
    }

    /// Shows what the cache holds for the day when it settles it; true when no call is needed.
    private func show(_ day: Date, id: String, key: String?, digest: ShippedDigest) -> Bool {
        guard let entry = cache?.entries[id] else { return false }
        if entry.isSettled {
            summaries[day] = entry.text.isEmpty ? nil : Summary(text: entry.text, current: true)
            return true
        }
        guard let key, entry.key == key else { return false }
        summaries[day] = Summary(text: entry.text, current: true)
        // The day is over and nothing changed since it was written: keep it for good, with its items.
        let closed = ShippedSummary.isClosed(day)
        if closed || entry.digest == nil {
            var upgraded = entry
            upgraded.digest = digest
            upgraded.final = closed
            save(upgraded, for: id)
        }
        return true
    }

    /// Reads the cache file and keeps whichever copy of each entry is newer.
    private func loadCache() async {
        let disk = await Task.detached(priority: .utility) { ShippedSummaryCache.read() }.value
        var cache = self.cache ?? ShippedSummaryCache()
        for (other, entry) in disk.entries where (cache.entries[other]?.createdAt ?? .distantPast) < entry.createdAt { cache.entries[other] = entry }
        if cache != self.cache { self.cache = cache; cacheVersion += 1 }
    }

    /// Saves one entry, merged with the file (a backfill may be writing too), never by
    /// overwriting the file with what this store happened to load.
    private func save(_ entry: ShippedSummary.Entry, for id: String) {
        var cache = self.cache ?? ShippedSummaryCache()
        cache.store(entry, for: id)
        self.cache = cache
        cacheVersion += 1
        Task.detached(priority: .utility) { try? ShippedSummaryCache.save([id: entry]) }
    }

    private func due(_ day: Date, now: Date) -> Bool {
        guard let last = fetchedAt[day] else { return true }
        if case .failed = states[day] { return now.timeIntervalSince(last) > 60 }
        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        if now < end { return now.timeIntervalSince(last) > 300 }
        return last < end.addingTimeInterval(1800) && now.timeIntervalSince(last) > 300
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
