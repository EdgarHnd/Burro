// State for the Today page: the selected day, its agent activity (Rust history worker) and the
// activity Burro tracked itself. Scans run only while the page is on screen: agent activity at
// most once a minute for today; a past day once its scan was taken after the day ended (plus 5
// minutes, DayScanCache), so a scan just before midnight is redone; tracked activity is a small
// local file, re-read when the tracker saved something, at most once a minute for today, and on
// the same rule for a past day. Caches keep today, the day shown and the five most recently used
// other days. The day follows the calendar (ShownDay): left on today, the page moves to the new
// day at midnight, checked on every refresh and on the system's day-change notice so it holds
// while the page is off screen; a past day you picked stays put.
// From the two it works out how much agents worked while you were away (AgentAwayTime), in the
// app and from data it already has: `away` for the day shown, and `awayAgentTime` (with
// `awayAgentTimePartial`) for today whatever day is shown, which Home reads along with
// `todayTracked` for its card. Home keeps them fresh with `refreshAwayAgentTime()` from its own
// on-screen loop: today's tracked day read once per call (when over a minute old), and today's
// agent scan reused when under 100 seconds old, otherwise redone without previews (cheaper; the
// Today page rescans with previews when it needs them).
// Neither is logged, stored or sent anywhere; both are nil when tracking is off or nothing can be said.
// `todayActivity` is today's scan as last read (whatever day the page shows), for Home's lanes;
// with tracking off Home keeps it fresh with `refreshTodayActivity()` (the same preview-free scan,
// reused when under 100 seconds old, and no tracked-day read).
import Foundation
import Observation
import BurroCore

@MainActor @Observable final class TodayStore {
    private var shown: ShownDay
    var day: Date { shown.day }
    private(set) var activity: DailyActivity?
    private(set) var tracked: ActivityDay?
    /// Agent work while you were away on the day shown; nil when it can't be said.
    private(set) var away: AgentAwayTime.Summary?
    /// Today's wall-clock agent time while you were away (Burro recording, you not there), for
    /// Home. Nil until today's activity and tracked day have been read, or when tracking is off.
    private(set) var awayAgentTime: TimeInterval?
    /// `awayAgentTime` is approximate (partial scan or chats with unknown stretches): worded "about".
    private(set) var awayAgentTimePartial = false
    /// Today's tracked day as last read, for Home's card (one read serves both).
    private(set) var todayTracked: ActivityDay?
    /// Today's agent activity as last scanned, whatever day the page shows (Home's lanes). Nil until
    /// the first scan of today answers.
    private(set) var todayActivity: DailyActivity?
    @ObservationIgnored private var todayActivityAt: Date?
    private var scanningDays: Set<Date> = []
    /// The day shown is being scanned.
    var scanning: Bool { scanningDays.contains(day) }
    let tracker: ActivityTracker
    var previews: Bool { didSet { defaults.set(previews, forKey: "today.previews"); activityCache = [:]; refresh(force: true) } }
    var profiles: () -> [UsageProvider: String] = { [:] }

    @ObservationIgnored private var activityCache: [Date: (activity: DailyActivity, at: Date, previews: Bool)] = [:]
    @ObservationIgnored private var trackedCache: [Date: (day: ActivityDay, at: Date, revision: Int)] = [:]
    /// Last use per cached day, for keeping the most recently used (DayScanCache.evictions).
    @ObservationIgnored private var used: [Date: Int] = [:]
    @ObservationIgnored private var useCounter = 0
    @ObservationIgnored private var trackedReading: Set<Date> = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar = Calendar.current
    @ObservationIgnored private var dayObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, tracker: ActivityTracker) {
        self.defaults = defaults
        self.tracker = tracker
        shown = ShownDay(now: Date(), calendar: Calendar.current)
        previews = defaults.object(forKey: "today.previews") as? Bool ?? true
        // Midnight (or a clock or time zone change) while the page is off screen: move on without scanning.
        dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followCalendar() }
        }
    }

    var isToday: Bool { calendar.isDateInToday(day) }
    var canGoForward: Bool { day < calendar.startOfDay(for: Date()) }

    func step(_ days: Int) { show(calendar.date(byAdding: .day, value: days, to: day) ?? day) }
    /// A past day stays shown across midnight; today follows the calendar again.
    func show(_ date: Date) {
        var next = shown
        let changed = next.show(date, now: Date(), calendar: calendar)
        if next != shown { shown = next }
        guard changed else { return }
        showCached()
        refresh()
    }

    /// Re-scans when the cached result is stale (DayScanCache.due): a past day settles once scanned after it ended.
    func refresh(force: Bool = false) {
        followCalendar()
        refreshTracked()
        scan(day, force: force, previews: previews, maxAge: 60)
        updateAway()
    }

    /// For Home: reads today's tracked day when over a minute old and today's agent activity when
    /// over 100 seconds old, without previews (a fresher scan from the Today page is reused), so
    /// `awayAgentTime` and `todayTracked` stay current while Today is off screen.
    func refreshAwayAgentTime() {
        followCalendar()
        let today = calendar.startOfDay(for: Date())
        refreshTracked(today)
        scan(today, force: false, previews: false, maxAge: 100)
        updateAway()
    }

    /// For Home's lanes with activity tracking off: today's agent scan only (no tracked day), reused
    /// when under 100 seconds old, otherwise redone without previews. Called from Home's own
    /// on-screen loop; it adds no timer.
    func refreshTodayActivity() {
        followCalendar()
        scan(calendar.startOfDay(for: Date()), force: false, previews: false, maxAge: 100)
        updateAway()
    }

    private func scan(_ target: Date, force: Bool, previews: Bool, maxAge: TimeInterval) {
        let now = Date()
        touch(target)
        let due = force || activityCache[target].map { cached in
            (previews && !cached.previews) || DayScanCache.due(takenAt: cached.at, day: target, now: now, maxAge: maxAge, calendar: calendar)
        } ?? true
        guard due, !scanningDays.contains(target) else { return }
        scanningDays.insert(target)
        let profiles = profiles()
        Task { [weak self] in
            let scanned = await Task.detached(priority: .utility) {
                DailyActivityScanner.scan(day: target, previews: previews, profiles: profiles)
            }.value
            guard let self else { return }
            let activity = scanned.map { day -> DailyActivity in
                var day = day
                day.chats.removeAll { Orchestrator.owns(folder: $0.folder) }
                return day
            }
            if let activity {
                self.activityCache[target] = (activity, Date(), previews)
                if self.day == target { self.activity = activity }
                self.evict()
            }
            self.scanningDays.remove(target)
            self.updateAway()
        }
    }

    /// Moves a page left on today to the new today, showing what's cached for it (usually nothing yet).
    private func followCalendar() {
        var next = shown
        guard next.update(now: Date(), calendar: calendar) else { return }
        shown = next
        showCached()
    }

    private func showCached() {
        touch(day)
        activity = activityCache[day]?.activity
        tracked = trackedCache[day]?.day
        updateAway()
    }

    /// Reads the tracked day when the tracker changed it (save, delete, rules) or, for today, after a minute.
    func refreshTracked() { refreshTracked(day) }

    private func refreshTracked(_ target: Date) {
        tracker.refreshTrust()
        let now = Date(), revision = tracker.revision
        touch(target)
        let cached = trackedCache[target]
        let due = cached.map { $0.revision != revision || DayScanCache.due(takenAt: $0.at, day: target, now: now, maxAge: 60, calendar: calendar) } ?? true
        guard due, !trackedReading.contains(target) else { return }
        trackedReading.insert(target)
        Task { [weak self] in
            guard let self else { return }
            let result = await self.tracker.day(target)
            self.trackedCache[target] = (result, Date(), revision)
            if self.day == target { self.tracked = result }
            self.evict()
            self.trackedReading.remove(target)
            self.updateAway()
            if self.tracker.revision != revision { self.refreshTracked(target) }
        }
    }

    /// Works out `away` (day shown) and `awayAgentTime` (today) from what is cached. Cheap: a few
    /// interval merges over one day's stretches.
    private func updateAway() {
        let now = Date(), today = calendar.startOfDay(for: now)
        let summary = { [self] (target: Date) -> AgentAwayTime.Summary? in
            guard tracker.enabled, let activity = activityCache[target]?.activity, let tracked = trackedCache[target]?.day else { return nil }
            return AgentAwayTime.summary(chats: activity.chats, tracked: tracked, day: target, now: now, partial: activity.partial, calendar: calendar)
        }
        let shownSummary = summary(day)
        if shownSummary != away { away = shownSummary }
        let todaySummary = day == today ? shownSummary : summary(today)
        if todaySummary?.total != awayAgentTime { awayAgentTime = todaySummary?.total }
        let partial = todaySummary?.partial ?? false
        if partial != awayAgentTimePartial { awayAgentTimePartial = partial }
        let todayDay = trackedCache[today]?.day
        if todayDay != todayTracked { todayTracked = todayDay }
        // Compared by scan time: a new scan of today replaces it, a new day clears it.
        let todayScan = activityCache[today]
        if todayScan?.at != todayActivityAt { todayActivityAt = todayScan?.at; todayActivity = todayScan?.activity }
    }

    /// Marks a day as just used, for eviction.
    private func touch(_ target: Date) {
        useCounter += 1
        used[target] = useCounter
    }

    /// Keeps today, the day shown and the five most recently used other days in the caches.
    private func evict() {
        let keep: Set<Date> = [calendar.startOfDay(for: Date()), day]
        let cached = Set(activityCache.keys).union(trackedCache.keys)
        let drop = DayScanCache.evictions(used: Dictionary(uniqueKeysWithValues: cached.map { ($0, used[$0] ?? 0) }), keep: keep)
        for target in drop {
            activityCache[target] = nil
            trackedCache[target] = nil
            used[target] = nil
        }
    }
}
