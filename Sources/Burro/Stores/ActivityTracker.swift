// Burro's own activity tracker: off by default, on this Mac only. While on and not paused, the
// sampler's observations go through ActivityPrivacy, the recorder merges them, and finished spans
// are appended to the day's file on a background queue at most every 30 seconds (and on idle,
// lock, pause and quit). Old days are pruned at launch and once a day. Nothing here is sent
// anywhere, logged, or included in the orchestrator's snapshot.
import AppKit
import ApplicationServices
import Observation
import BurroCore

@MainActor @Observable final class ActivityTracker {
    var enabled: Bool { didSet { defaults.set(enabled, forKey: "activity.enabled"); apply() } }
    var paused: Bool { didSet { defaults.set(paused, forKey: "activity.paused"); apply() } }
    private(set) var accessibilityTrusted = AXIsProcessTrusted()
    private(set) var rules = ActivityRules()
    /// Bumps whenever stored data or rules change, so the Today page re-reads.
    private(set) var revision = 0
    var recording: Bool { enabled && !paused }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let log: ActivityLog
    @ObservationIgnored private var recorder = ActivityRecorder()
    @ObservationIgnored private var unsaved: [ActivitySpan] = []
    @ObservationIgnored private var sampler: ActivitySampler?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastCheckpoint = Date()
    @ObservationIgnored private var lastPrune = Date.distantPast
    @ObservationIgnored private let writer = DispatchQueue(label: "local.burro.activity.write", qos: .utility)

    init(defaults: UserDefaults = .standard, log: ActivityLog = ActivityLog()) {
        self.defaults = defaults
        self.log = log
        enabled = defaults.bool(forKey: "activity.enabled")
        paused = defaults.bool(forKey: "activity.paused")
    }

    func start() {
        guard !started else { return }
        started = true
        let log = log
        rules = writer.sync { ActivityRules.load(from: log.rulesURL) }
        prune(Date())
        apply()
    }

    /// Quit: saves everything still in memory before returning.
    func stop() {
        sampler?.stop()
        let spans = unsaved, log = log
        unsaved = []
        writer.sync { if !spans.isEmpty { try? log.append(spans) } }
    }

    private func apply() {
        guard started else { return }
        if recording {
            guard sampler == nil else { return }
            let sampler = ActivitySampler()
            sampler.onChange = { [weak self] observation, at in self?.observe(observation, at: at) }
            sampler.onTick = { [weak self] now in self?.tick(now) }
            sampler.onTrustChange = { [weak self] trusted in self?.accessibilityTrusted = trusted }
            self.sampler = sampler
            lastCheckpoint = Date()
            sampler.start()
        } else if let sampler {
            sampler.stop()
            self.sampler = nil
        }
    }

    private func observe(_ observation: ActivityObservation?, at time: Date) {
        let key = observation.map {
            ActivityPrivacy.key(bundleID: $0.bundleID, app: $0.app, title: $0.title, address: $0.address,
                                privateWindow: $0.privateWindow, privateHosts: rules.privateHosts)
        }
        unsaved += recorder.observe(key, at: time)
        if key == nil { save() }
    }

    private func tick(_ now: Date) {
        if now.timeIntervalSince(lastCheckpoint) >= 300 {
            lastCheckpoint = now
            unsaved += recorder.checkpoint(at: now)
        }
        save()
        prune(now)
    }

    private func save() {
        guard !unsaved.isEmpty else { return }
        let spans = unsaved, log = log
        unsaved = []
        writer.async { try? log.append(spans) }
        revision += 1
    }

    private func prune(_ now: Date) {
        guard !Calendar.current.isDate(lastPrune, inSameDayAs: now) else { return }
        lastPrune = now
        let log = log
        writer.async { log.prune(now: now) }
    }

    // MARK: Reading and editing

    /// The day's spans from disk, read after any pending writes, plus today's unsaved time.
    func day(_ date: Date) async -> ActivityDay {
        let log = log, rules = rules, now = Date()
        let live = Calendar.current.isDate(date, inSameDayAs: now) ? unsaved + recorder.live(at: now) : []
        let stored = await withCheckedContinuation { (done: CheckedContinuation<[ActivitySpan], Never>) in
            writer.async { done.resume(returning: log.read(day: date)) }
        }
        return ActivityDay.build(spans: stored + live, rules: rules, day: date)
    }

    func deleteDay(_ date: Date) {
        let log = log
        if Calendar.current.isDateInToday(date) { recorder.discard(at: Date()); unsaved = [] }
        writer.async { log.deleteDay(date) }
        revision += 1
    }

    func deleteAll() {
        let log = log
        recorder.discard(at: Date()); unsaved = []
        writer.async { log.deleteAll() }
        revision += 1
    }

    /// Nil returns the app to its built-in category.
    func setCategory(_ category: ActivityCategory?, app bundleID: String) {
        rules.apps[bundleID] = category
        saveRules()
    }

    func setCategory(_ category: ActivityCategory?, host: String) {
        rules.hosts[host] = category
        saveRules()
    }

    /// Future visits keep no title and store the host as "Private"; stored days are rewritten the same way.
    func makePrivate(host: String) {
        guard !rules.privateHosts.contains(host) else { return }
        rules.privateHosts.append(host)
        rules.hosts[host] = nil
        recorder.redact(host: host)
        unsaved = unsaved.map { $0.redacted(host: host) }
        save()
        let log = log
        writer.async { log.scrub(host: host) }
        saveRules()
    }

    func refreshTrust() { accessibilityTrusted = AXIsProcessTrusted(); sampler?.refreshTrust() }

    /// Only on an explicit click: macOS's prompt, then the Accessibility pane.
    func requestAccessibility() {
        accessibilityTrusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func saveRules() {
        let rules = rules, log = log
        writer.async { try? rules.save(to: log.rulesURL) }
        revision += 1
    }
}
