// State for the Today page: the selected day, its agent activity (Rust history worker) and
// Dayflow timeline. Scans run only while the page is on screen: activity at most once a
// minute for today (past days once), Dayflow at most every five minutes.
import Foundation
import Observation
import BurroCore

@MainActor @Observable final class TodayStore {
    private(set) var day: Date
    private(set) var activity: DailyActivity?
    private(set) var dayflow: DayflowDay?
    private(set) var scanning = false
    let dayflowInstalled: Bool
    var previews: Bool { didSet { defaults.set(previews, forKey: "today.previews"); activityCache = [:]; refresh(force: true) } }
    var profiles: () -> [UsageProvider: String] = { [:] }

    @ObservationIgnored private var activityCache: [Date: (activity: DailyActivity, at: Date)] = [:]
    @ObservationIgnored private var dayflowCache: [Date: (day: DayflowDay, at: Date)] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar = Calendar.current

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        day = Calendar.current.startOfDay(for: Date())
        previews = defaults.object(forKey: "today.previews") as? Bool ?? true
        dayflowInstalled = Dayflow.executable() != nil
    }

    var isToday: Bool { calendar.isDateInToday(day) }
    var canGoForward: Bool { day < calendar.startOfDay(for: Date()) }

    func step(_ days: Int) { show(calendar.date(byAdding: .day, value: days, to: day) ?? day) }
    func show(_ date: Date) {
        let target = min(calendar.startOfDay(for: date), calendar.startOfDay(for: Date()))
        guard target != day else { return }
        day = target
        activity = activityCache[target]?.activity
        dayflow = dayflowCache[target]?.day
        refresh()
    }

    /// Re-scans when the cached result is stale: past days never change, so they scan once.
    func refresh(force: Bool = false) {
        let target = day, now = Date(), today = isToday
        let activityDue = force || activityCache[target].map { today && now.timeIntervalSince($0.at) > 60 } ?? true
        let dayflowDue = dayflowInstalled && (force || dayflowCache[target].map { today && now.timeIntervalSince($0.at) > 300 } ?? true)
        guard (activityDue || dayflowDue), task == nil else { return }
        scanning = true
        let previews = previews, profiles = profiles()
        task = Task { [weak self] in
            async let scannedActivity: DailyActivity? = activityDue
                ? Task.detached(priority: .utility) { DailyActivityScanner.scan(day: target, previews: previews, profiles: profiles) }.value : nil
            async let scannedDayflow: DayflowDay? = dayflowDue
                ? Task.detached(priority: .utility) { Dayflow.day(target) }.value : nil
            let (activity, dayflow) = await (scannedActivity, scannedDayflow)
            guard let self else { return }
            if let activity { self.activityCache[target] = (activity, Date()) }
            if let dayflow { self.dayflowCache[target] = (dayflow, Date()) }
            if self.day == target {
                if let activity { self.activity = activity }
                if let dayflow { self.dayflow = dayflow }
            }
            self.scanning = false
            self.task = nil
        }
    }
}
