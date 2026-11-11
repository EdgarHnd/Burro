// Watches what you're doing, event-driven and on this Mac only: the frontmost app from NSWorkspace
// and, with Accessibility, the focused window's title and a browser's address-bar text (its host
// is all that's kept, by ActivityPrivacy). No screenshots, no keystrokes. A 30-second timer
// (10 s tolerance) checks for two minutes without input; sleep, lock and session switches stop it
// outright. Title notifications are muted after the first one until a read 1–5 s later, so a
// window that renames itself ten times a second costs one read every five seconds. The lock
// screen, login window and screen saver count as away. Arc (and Chrome, Brave or Edge when their
// address field can't be found) only builds its accessibility tree when asked: the sampler sets
// `AXManualAccessibility` on it once per launch, then reads just the page's `AXURL` from the
// window's web area, never anything inside it.
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
    /// Ask Chromium-family browsers to build their accessibility tree when no address field is found.
    /// It costs the browser some CPU and memory; off, those browsers fall back to window titles.
    var wakesBrowserTrees = true

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
    /// The focused window's address field, private-window flag and web area's parent, found once per window.
    private var browserCache: BrowserCache?
    /// Browsers (by pid) already asked to build their accessibility tree: once per launch.
    private var wokenBrowsers: Set<pid_t> = []
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
        // The lock screen, login window or screen saver in front: you're away, nothing to read.
        if ActivityPrivacy.isSystemScreen(bundleID) {
            detach()
            app = nil; last = nil; browserCache = nil
            onChange(nil, Date())
            return
        }
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
        let chromium = ActivityPrivacy.chromiumBrowsers.contains(app.bundleID)
        let wake = chromium && wakesBrowserTrees && !wokenBrowsers.contains(app.pid)
        let cache = browserCache
        reader.async { [weak self] in
            let result = Self.readWindow(box, browser: browser, chromium: chromium, wake: wake, cache: cache)
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
            // A Chromium window with nothing found yet is searched again next time (its tree may still be building).
            let empty = ActivityPrivacy.chromiumBrowsers.contains(app.bundleID) && result.field == nil && result.webParent == nil
            if ActivityPrivacy.browsers.contains(app.bundleID) {
                browserCache = empty ? nil : BrowserCache(window: window, field: result.field, isPrivate: result.isPrivate, webParent: result.webParent)
            }
        }
        if result.woke {
            // The browser builds its tree now; one more read shortly picks up the page.
            wokenBrowsers.insert(app.pid)
            scheduleRead(after: 1.5)
        }
        watchTitles(true)
        let observation = ActivityObservation(bundleID: app.bundleID, app: app.name, title: result.title,
                                              address: result.address, privateWindow: result.isPrivate)
        guard observation != last else { return }
        last = observation
        if !idle { onChange(observation, Date()) }
    }

    // MARK: Reading (off the main thread)

    private struct BrowserCache: Sendable {
        var window: AXBox
        var field: AXBox?
        var isPrivate: Bool
        var webParent: AXBox?
    }

    private struct WindowRead: Sendable {
        var window: AXBox?
        var title: String?
        var address: String?
        var field: AXBox?
        var isPrivate = false
        var webParent: AXBox?
        /// This read asked the browser to build its accessibility tree.
        var woke = false
    }

    private nonisolated static func readWindow(_ app: AXBox, browser: Bool, chromium: Bool, wake: Bool, cache: BrowserCache?) -> WindowRead {
        guard let window: AXUIElement = attribute(app.element, kAXFocusedWindowAttribute) else { return WindowRead() }
        var read = WindowRead(window: AXBox(element: window), title: attribute(window, kAXTitleAttribute))
        guard browser else { return read }
        let cached = cache.map { CFEqual($0.window.element, window) } ?? false
        if cached, let cache {
            read.field = cache.field; read.isPrivate = cache.isPrivate; read.webParent = cache.webParent
        } else {
            (read.field, read.isPrivate, read.webParent) = searchToolbar(window, webAreas: chromium)
        }
        read.address = read.field.flatMap { attribute($0.element, kAXValueAttribute) }
        // Chromium without an address field (Arc always): the page's URL from the window's web area.
        guard chromium, read.field == nil else { return read }
        var url = read.webParent.flatMap { pageURL(in: $0.element) }
        if url == nil, cached {
            // The layout changed under the cached parent (a new tab page, a split): look again.
            let found = searchToolbar(window, webAreas: true)
            read.webParent = found.2
            read.isPrivate = read.isPrivate || found.1
            url = read.webParent.flatMap { pageURL(in: $0.element) }
        }
        if url == nil, read.webParent == nil, wake {
            // Arc exposes only an empty window until asked. Costs the browser some CPU and memory.
            AXUIElementSetAttributeValue(app.element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            read.woke = true
        }
        read.address = url
        return read
    }

    /// Breadth-first through the window's chrome (never into web content), at most 250 elements:
    /// the address field, any Incognito / InPrivate / Private marker and, for Chromium browsers, the
    /// parent of the first web area. Chromium's scroll areas are entered only to find the web area;
    /// labels inside them (tab titles) aren't read. A web area's own attributes are never read here.
    private nonisolated static func searchToolbar(_ window: AXUIElement, webAreas: Bool) -> (AXBox?, Bool, AXBox?) {
        var queue: [(element: AXUIElement, parent: AXUIElement?, scrolled: Bool)] = [(window, nil, false)]
        var visited = 0, field: AXUIElement?, isPrivate = false, webParent: AXUIElement?
        while !queue.isEmpty && visited < 250 {
            let (element, parent, inScroll) = queue.removeFirst()
            visited += 1
            let role: String = attribute(element, kAXRoleAttribute) ?? ""
            if role == "AXWebArea" {
                if webParent == nil { webParent = parent }
                continue
            }
            if role == "AXScrollArea" && !webAreas { continue }
            let scrolled = inScroll || role == "AXScrollArea"
            if !scrolled {
                let labels = [kAXIdentifierAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute]
                    .compactMap { (name: String) -> String? in attribute(element, name) }.map { $0.lowercased() }
                if field == nil, role == kAXTextFieldRole || role == kAXComboBoxRole,
                   labels.contains(where: { $0.contains("address") || $0.contains("url") || $0.contains("search or enter") }) {
                    field = element
                }
                if labels.contains(where: { ["incognito", "inprivate", "private browsing", "private"].contains($0) }) { isPrivate = true }
            }
            if (field != nil || (webAreas && webParent != nil)) && visited > 60 { break }
            queue += ((attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? []).map { ($0, element, scrolled) }
        }
        return (field.map(AXBox.init), isPrivate, webParent.map(AXBox.init))
    }

    /// The `AXURL` of the web area under `parent`, as text for `ActivityPrivacy.key` (which keeps only
    /// the host). Reads the parent's children's roles and that one attribute, nothing else.
    private nonisolated static func pageURL(in parent: AXUIElement) -> String? {
        let children: [AXUIElement] = attribute(parent, kAXChildrenAttribute) ?? []
        guard let area = children.first(where: { (attribute($0, kAXRoleAttribute) as String?) == "AXWebArea" }),
              let url: URL = attribute(area, "AXURL") else { return nil }
        return url.absoluteString
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
