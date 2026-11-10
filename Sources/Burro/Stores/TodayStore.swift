// State for the Today page: the selected day, its agent activity (Rust history worker) and the
// activity Burro tracked itself. Scans run only while the page is on screen: agent activity at
// most once a minute for today (past days once); tracked activity is a small local file, re-read
// when the tracker saved something or at most once a minute for today.
import Foundation
import Observation
import BurroCore

@MainActor @Observable final class TodayStore {
    private(set) var day: Date
    private(set) var activity: DailyActivity?
    private(set) var tracked: ActivityDay?
    private(set) var scanning = false
    let tracker: ActivityTracker
    var previews: Bool { didSet { defaults.set(previews, forKey: "today.previews"); activityCache = [:]; refresh(force: true) } }
    var profiles: () -> [UsageProvider: String] = { [:] }

    @ObservationIgnored private var activityCache: [Date: (activity: DailyActivity, at: Date)] = [:]
    @ObservationIgnored private var trackedCache: [Date: (day: ActivityDay, at: Date, revision: Int)] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var trackedTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar = Calendar.current

    init(defaults: UserDefaults = .standard, tracker: ActivityTracker) {
        self.defaults = defaults
        self.tracker = tracker
        day = Calendar.current.startOfDay(for: Date())
        previews = defaults.object(forKey: "today.previews") as? Bool ?? true
    }

    var isToday: Bool { calendar.isDateInToday(day) }
    var canGoForward: Bool { day < calendar.startOfDay(for: Date()) }

    func step(_ days: Int) { show(calendar.date(byAdding: .day, value: days, to: day) ?? day) }
    func show(_ date: Date) {
        let target = min(calendar.startOfDay(for: date), calendar.startOfDay(for: Date()))
        guard target != day else { return }
        day = target
        activity = activityCache[target]?.activity
        tracked = trackedCache[target]?.day
        refresh()
    }

    /// Re-scans when the cached result is stale: past days never change, so they scan once.
    func refresh(force: Bool = false) {
        refreshTracked()
        let target = day, now = Date(), today = isToday
        let activityDue = force || activityCache[target].map { today && now.timeIntervalSince($0.at) > 60 } ?? true
        guard activityDue, task == nil else { return }
        scanning = true
        let previews = previews, profiles = profiles()
        task = Task { [weak self] in
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
                self.activityCache[target] = (activity, Date())
                if self.day == target { self.activity = activity }
            }
            self.scanning = false
            self.task = nil
        }
    }

    /// Reads the tracked day when the tracker changed it (save, delete, rules) or, for today, after a minute.
    func refreshTracked() {
        tracker.refreshTrust()
        let target = day, now = Date(), revision = tracker.revision
        let cached = trackedCache[target]
        let due = cached.map { $0.revision != revision || (isToday && now.timeIntervalSince($0.at) > 60) } ?? true
        guard due, trackedTask == nil else { return }
        trackedTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.tracker.day(target)
            self.trackedCache[target] = (result, Date(), revision)
            if self.day == target { self.tracked = result }
            self.trackedTask = nil
            if self.tracker.revision != revision { self.refreshTracked() }
        }
    }
}
