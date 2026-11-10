// Watches what you're doing, event-driven and on this Mac only: the frontmost app from NSWorkspace
// and, with Accessibility, the focused window's title and a browser's address-bar text (its host
// is all that's kept, by ActivityPrivacy). No screenshots, no keystrokes. A 30-second timer
// (10 s tolerance) checks for two minutes without input; sleep, lock and session switches stop it
// outright. Title notifications are muted after the first one until a read 1–5 s later, so a
// window that renames itself ten times a second costs one read every five seconds.
import AppKit
import ApplicationServices
import BurroCore

struct ActivityObservation: Sendable, Equatable {
    var bundleID: String
    var app: String
    var title: String?
    var address: String?
    var privateWindow = false
}

/// AX elements are thread-safe CF objects; the box lets reads run off the main thread.
private struct AXBox: @unchecked Sendable { let element: AXUIElement }

@MainActor final class ActivitySampler {
    static let idleAfter: TimeInterval = 120
    /// The current window, or nil when you went idle, locked the screen or the Mac slept.
    /// The date may be in the past (idle started, or input resumed, before the check noticed).
    var onChange: (ActivityObservation?, Date) -> Void = { _, _ in }
    /// Every check while you're active; the tracker saves on it.
    var onTick: (Date) -> Void = { _ in }
    var onTrustChange: (Bool) -> Void = { _ in }
    private(set) var trusted = AXIsProcessTrusted()

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var idle = false
    private var suspended = false
    private var running = false
    private var app: (bundleID: String, name: String, pid: pid_t, element: AXUIElement)?
    private var last: ActivityObservation?
    private var axObserver: AXObserver?
    private var watchedWindow: AXUIElement?
    private var watchingTitles = false
    private var readScheduled = false
    private var lastRead = Date.distantPast
    private var generation = 0
    /// The focused window's address field and private-window flag, found once per window.
    private var browserCache: (window: AXBox, field: AXBox?, isPrivate: Bool)?
    private let reader = DispatchQueue(label: "local.burro.activity.ax", qos: .utility)

    func start() {
        guard !running else { return }
        running = true
        let workspace = NSWorkspace.shared.notificationCenter, distributed = DistributedNotificationCenter.default()
        // Handlers get the activated app's pid, the only thing taken from a notification.
        let on = { [weak self] (center: NotificationCenter, name: Notification.Name, action: @escaping @MainActor @Sendable (ActivitySampler, pid_t?) -> Void) in
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated { if let self { action(self, pid) } }
            }
            self?.observers.append((center, token))
        }
        on(workspace, NSWorkspace.didActivateApplicationNotification) { sampler, pid in
            sampler.activate(pid.flatMap { NSRunningApplication(processIdentifier: $0) })
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            on(workspace, name) { sampler, _ in sampler.suspend() }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            on(workspace, name) { sampler, _ in sampler.resume() }
        }
        on(distributed, Notification.Name("com.apple.screenIsLocked")) { sampler, _ in sampler.suspend() }
        on(distributed, Notification.Name("com.apple.screenIsUnlocked")) { sampler, _ in sampler.resume() }
        // A hung app must not stall reads for AX's default six seconds per call.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        suspended = false; idle = false
        startTimer()
        activate(NSWorkspace.shared.frontmostApplication)
    }

    func stop() {
        guard running else { return }
        running = false
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        timer?.invalidate(); timer = nil
        detach()
        app = nil; last = nil
        onChange(nil, Date())
    }

    // MARK: Presence

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func check() {
        let now = Date()
        refreshTrust()
        let types: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .flagsChanged, .leftMouseDragged]
        let quiet = types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
        if !idle && quiet >= Self.idleAfter {
            idle = true
            onChange(nil, now.addingTimeInterval(-quiet))
        } else if idle && quiet < Self.idleAfter {
            idle = false
            if let last { onChange(last, now.addingTimeInterval(-quiet)) }
            scheduleRead(after: 0.2)
        }
        if !idle { onTick(now) }
    }

    private func suspend() {
        guard running, !suspended else { return }
        suspended = true
        timer?.invalidate(); timer = nil
        onChange(nil, Date())
    }

    private func resume() {
        guard running, suspended else { return }
        suspended = false; idle = false
        startTimer()
        activate(NSWorkspace.shared.frontmostApplication)
    }

    func refreshTrust() {
        let now = AXIsProcessTrusted()
        guard now != trusted else { return }
        trusted = now
        onTrustChange(now)
        if running, let app { attach(pid: app.pid, element: app.element); scheduleRead(after: 0.2) }
    }

    // MARK: Frontmost app and window

    private func activate(_ running: NSRunningApplication?) {
        guard self.running, !suspended, let running, let bundleID = running.bundleIdentifier else { return }
        idle = false
        let element = AXUIElementCreateApplication(running.processIdentifier)
        app = (bundleID, running.localizedName ?? bundleID, running.processIdentifier, element)
        browserCache = nil
        last = ActivityObservation(bundleID: bundleID, app: running.localizedName ?? bundleID)
        onChange(last, Date())
        refreshTrust()
        attach(pid: running.processIdentifier, element: element)
        lastRead = .distantPast
        scheduleRead(after: 0.3)
    }

    private func attach(pid: pid_t, element: AXUIElement) {
        detach()
        guard trusted else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, activityAXCallback, &observer) == .success, let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer
        watchTitles(true)
    }

    private func detach() {
        if let axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes) }
        axObserver = nil; watchedWindow = nil; watchingTitles = false
        generation += 1
    }

    /// Title notifications on the app and its focused window, muted between reads.
    private func watchTitles(_ on: Bool) {
        guard let axObserver, let app, on != watchingTitles else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for element in [app.element, watchedWindow].compactMap({ $0 }) {
            if on { AXObserverAddNotification(axObserver, element, kAXTitleChangedNotification as CFString, refcon) }
            else { AXObserverRemoveNotification(axObserver, element, kAXTitleChangedNotification as CFString) }
        }
        watchingTitles = on
    }

    fileprivate func axEvent(_ name: String) {
        if name == kAXTitleChangedNotification {
            watchTitles(false)
            // At most one read every five seconds while a title keeps changing.
            scheduleRead(after: max(1, lastRead.addingTimeInterval(ActivityRecorder.minimumSpan).timeIntervalSinceNow))
        } else {
            browserCache = nil
            scheduleRead(after: 0.3)
        }
    }

    private func scheduleRead(after delay: TimeInterval) {
        guard trusted, !readScheduled else { return }
        readScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.readScheduled = false
            self?.read()
        }
    }

    private func read() {
        guard running, !suspended, trusted, let app else { return }
        generation += 1
        lastRead = Date()
        let id = generation, box = AXBox(element: app.element), browser = ActivityPrivacy.browsers.contains(app.bundleID)
        let cache = browserCache
        reader.async { [weak self] in
            let result = Self.readWindow(box, browser: browser, cache: cache)
            Task { @MainActor [weak self] in self?.apply(result, id: id) }
        }
    }

    private func apply(_ result: WindowRead, id: Int) {
        guard id == generation, running, !suspended, let app else { return }
        if let window = result.window {
            if watchedWindow.map({ !CFEqual($0, window.element) }) ?? true {
                watchTitles(false)
                watchedWindow = window.element
            }
            if ActivityPrivacy.browsers.contains(app.bundleID) { browserCache = (window, result.field, result.isPrivate) }
        }
        watchTitles(true)
        let observation = ActivityObservation(bundleID: app.bundleID, app: app.name, title: result.title,
                                              address: result.address, privateWindow: result.isPrivate)
        guard observation != last else { return }
        last = observation
        if !idle { onChange(observation, Date()) }
    }

    // MARK: Reading (off the main thread)

    private struct WindowRead: Sendable {
        var window: AXBox?
        var title: String?
        var address: String?
        var field: AXBox?
        var isPrivate = false
    }

    private nonisolated static func readWindow(_ app: AXBox, browser: Bool, cache: (window: AXBox, field: AXBox?, isPrivate: Bool)?) -> WindowRead {
        guard let window: AXUIElement = attribute(app.element, kAXFocusedWindowAttribute) else { return WindowRead() }
        var read = WindowRead(window: AXBox(element: window), title: attribute(window, kAXTitleAttribute))
        guard browser else { return read }
        if let cache, CFEqual(cache.window.element, window) {
            read.field = cache.field; read.isPrivate = cache.isPrivate
        } else {
            (read.field, read.isPrivate) = searchToolbar(window)
        }
        read.address = read.field.flatMap { attribute($0.element, kAXValueAttribute) }
        return read
    }

    /// Breadth-first through the window's chrome (never into web content), at most 250 elements:
    /// the address field, and any Incognito / InPrivate / Private marker.
    private nonisolated static func searchToolbar(_ window: AXUIElement) -> (AXBox?, Bool) {
        var queue = [window], visited = 0, field: AXUIElement?, isPrivate = false
        while !queue.isEmpty && visited < 250 {
            let element = queue.removeFirst()
            visited += 1
            let role: String = attribute(element, kAXRoleAttribute) ?? ""
            if role == "AXWebArea" || role == "AXScrollArea" { continue }
            let labels = [kAXIdentifierAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute]
                .compactMap { (name: String) -> String? in attribute(element, name) }.map { $0.lowercased() }
            if field == nil, role == kAXTextFieldRole || role == kAXComboBoxRole,
               labels.contains(where: { $0.contains("address") || $0.contains("url") || $0.contains("search or enter") }) {
                field = element
            }
            if labels.contains(where: { ["incognito", "inprivate", "private browsing", "private"].contains($0) }) { isPrivate = true }
            if field != nil && visited > 60 { break }
            queue += (attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? []
        }
        return (field.map(AXBox.init), isPrivate)
    }

    private nonisolated static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

/// AX delivers on the main run loop (the source is added there).
private func activityAXCallback(_ observer: AXObserver, _ element: AXUIElement, _ name: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let sampler = Unmanaged<ActivitySampler>.fromOpaque(refcon).takeUnretainedValue()
    let name = name as String
    MainActor.assumeIsolated { sampler.axEvent(name) }
}
