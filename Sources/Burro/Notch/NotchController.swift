// A single nonactivating AppKit panel hosts SwiftUI; no global keyboard hooks or extra permissions.
import AppKit
import SwiftUI
import Observation
import OSLog
import BurroCore

@MainActor @Observable final class NotchPresentation {
    var expanded = false
    var pinned = false
    var includeIdle = false
    var chatScope: NotchChatScope = .activity
    var holdingList = false
    var visibleRows = 3
    var navigation = NotchNavigation()
    var compactGeometry = NotchGeometry.layout(screen: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875), safeTop: 0, hardwareWidth: 0, expanded: false)
    var expandedGeometry = NotchGeometry.layout(screen: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875), safeTop: 0, hardwareWidth: 0, expanded: true)
}
@MainActor final class NotchController {
    let presentation = NotchPresentation()
    private(set) var panel: AgentNotchPanel?
    private(set) var surface: NotchSurfaceView?
    private weak var dashboardWindow: NSWindow?
    private weak var store: AppStore?
    private var openDashboard: (() -> Void)?
    private var hoverState = NotchHoverState()
    private var hoverTimer: Timer?
    private var scheduledDeadline: TimeInterval?
    private var transitionID: UUID?
    private var observationID = UUID()
    private var contentLayoutRequest: UUID?
    private var placingWindow = false
    private var destinationFrame: NSRect = .zero
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var pointerMonitors: [Any] = []
    private var trackingMenus: Set<ObjectIdentifier> = []
    private(set) var navigationBounds: [NotchPage: CGRect] = [:]
    private let pointerLocation: () -> NSPoint
    private let reduceMotion: () -> Bool
    private let reduceTransparency: () -> Bool
    private let hoverLog = Logger(subsystem: "local.burro.worktrees", category: "Notch")

    init(pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         reduceTransparency: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }) {
        self.pointerLocation = pointerLocation
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
    }

    func start(store: AppStore, openDashboard: @escaping () -> Void) {
        self.openDashboard = openDashboard
        guard panel == nil else { return }
        self.store = store
        let panel = AgentNotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Burro — Agents"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = true
        // isFloatingPanel resets the level to floating; apply the overlay level afterwards.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isReleasedWhenClosed = false; panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        func content(compact: Bool) -> NotchView {
            NotchView(store: store, presentation: presentation,
                onToggle: { [weak self] in self?.toggle() },
                onPin: { [weak self] in self?.togglePin() },
                onCollapse: { [weak self] in self?.collapse() },
                onSelect: { [weak self] in self?.select($0) },
                onInspect: { [weak self] in self?.inspect($0) },
                onOpenDashboard: { [weak self] in self?.openDashboardWindow() },
                onSelectPage: { [weak self] in self?.selectPage($0) },
                onNavigationBounds: { [weak self] in self?.setNavigationBounds($0) },
                onContentChange: { [weak self] in self?.requestContentLayout() }, compact: compact)
        }
        let surface = NotchSurfaceView(compact: content(compact: true), expanded: content(compact: false), reduceTransparency: reduceTransparency)
        panel.contentView = surface
        panel.acceptsMouseMovedEvents = true
        self.surface = surface
        self.panel = panel
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.surface?.updateGlassAccessibility() }
            })
        store.onNotchPreferenceChange = { [weak self] in self?.configure() }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.configure() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.configure() }
        })
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, event.window === self?.panel else { return event }
            self?.collapse(); return nil
        }
        // Observe movement both over Burro and over other apps. This does not intercept events,
        // monitor keys, or require accessibility/input-monitoring permission. Window/view tracking
        // regions are deliberately not involved in hover intent.
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.samplePointer(source: "local movement"); return event
        }) { pointerMonitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            self?.samplePointer(source: "global movement")
        }) { pointerMonitors.append(monitor) }
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                let id = ObjectIdentifier(menu)
                let beginning = notification.name == NSMenu.didBeginTrackingNotification
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if beginning {
                        guard self.presentation.expanded else { return }
                        self.trackingMenus.insert(id)
                    } else { self.trackingMenus.remove(id) }
                    self.samplePointer(source: "menu tracking")
                }
            })
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateListHold() }
            })
        }
        observationID = UUID()
        observeAttention()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let store = self.store else { return }
                self.surface?.setAttention(store.agentActivity.attention, animated: !self.reduceMotion())
            }
        })
        configure()
        samplePointer()
    }
    // Observe live activity independently of the frozen expanded list and the selected tab.
    private func observeAttention() {
        guard let store, let surface, panel != nil else { return }
        let id = observationID
        withObservationTracking {
            surface.setAttention(store.agentActivity.attention, animated: !reduceMotion())
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observationID == id else { return }
                self.observeAttention()
            }
        }
    }
    func show() {
        if store?.notchEnabled == false { store?.notchEnabled = true }
        hoverState.show(pointerInside: containsPointer())
        applyInteraction()
        panel?.makeKeyAndOrderFront(nil)
    }
    func toggle() {
        if presentation.expanded { collapse() }
        else { show() }
    }
    func collapse() {
        presentation.navigation.endPreview()
        hoverState.dismiss(pointerInside: containsPointer())
        applyInteraction()
    }
    func stop() {
        observationID = UUID()
        contentLayoutRequest = nil
        presentation.navigation.endPreview(); navigationBounds = [:]
        hoverTimer?.invalidate(); transitionID = nil
        scheduledDeadline = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll(); trackingMenus.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        pointerMonitors.forEach { NSEvent.removeMonitor($0) }; pointerMonitors.removeAll()
        keyMonitor = nil; surface?.cancel(); surface = nil; panel?.close(); panel = nil
    }
    private func togglePin() {
        hoverState.togglePin(now: ProcessInfo.processInfo.systemUptime)
        applyInteraction()
    }
    private func containsPointer() -> Bool {
        guard let panel, panel.isVisible else { return false }
        return NotchHoverRegion.contains(pointerLocation(), compact: presentation.compactGeometry.frame,
            expanded: presentation.expandedGeometry.frame, isExpanded: presentation.expanded,
            isClosing: transitionID != nil && !presentation.expanded)
    }
    func samplePointer(source: String = "reconcile") {
        guard store?.notchEnabled == true, !placingWindow else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let inside = containsPointer() || !trackingMenus.isEmpty
        if inside != hoverState.pointerInside {
            hoverLog.info("Hover inside=\(inside, privacy: .public) source=\(source, privacy: .public)")
        }
        hoverState.updatePointer(inside: inside, now: now)
        hoverState.advance(now: now)
        var navigation = presentation.navigation
        if hoverState.expanded && trackingMenus.isEmpty {
            let frame = presentation.expandedGeometry.frame
            let pointer = pointerLocation()
            let local = CGPoint(x: pointer.x - frame.minX, y: frame.maxY - pointer.y)
            let page = NotchPage.allCases.first { navigationBounds[$0]?.contains(local) == true }
            navigation.updatePointer(over: page, now: now)
            navigation.advance(now: now)
        } else { navigation.endPreview() }
        // Pointer events are frequent; publish only actual navigation changes to SwiftUI.
        if navigation != presentation.navigation { presentation.navigation = navigation }
        applyInteraction()
    }
    func setNavigationBounds(_ bounds: [NotchPage: CGRect]) {
        guard bounds != navigationBounds else { return }
        navigationBounds = bounds
        samplePointer(source: "tab layout")
    }
    func selectPage(_ page: NotchPage) {
        presentation.navigation.select(page)
        armHoverDeadline()
    }
    private func updateListHold() {
        presentation.holdingList = hoverState.expanded && (hoverState.pointerInside || panel?.isKeyWindow == true)
    }
    private func applyInteraction() {
        updateListHold()
        let changed = presentation.expanded != hoverState.expanded
        presentation.pinned = hoverState.pinned
        if changed {
            hoverLog.info("Notch expanded=\(self.hoverState.expanded, privacy: .public)")
            configure(animate: true)
        }
        armHoverDeadline()
    }
    private func armHoverDeadline() {
        let next = [hoverState.deadline, presentation.navigation.deadline].compactMap { $0 }.min()
        guard scheduledDeadline != next else { return }
        hoverTimer?.invalidate()
        scheduledDeadline = next
        guard let deadline = scheduledDeadline else { return }
        // A common-mode timer continues to fire while AppKit is in a mouse-tracking loop.
        let timer = Timer(timeInterval: max(0, deadline - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduledDeadline = nil
                self.samplePointer(source: "hover deadline")
            }
        }
        timer.tolerance = 0.002
        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func requestContentLayout() {
        guard panel != nil, contentLayoutRequest == nil else { return }
        let id = UUID()
        contentLayoutRequest = id
        // SwiftUI calls onAppear/onChange during its render pass. Resizing the
        // hosting view (or forcing its layout) from that stack makes AppKit skip
        // the reentrant pass, leaving old content bounds after repeated previews.
        // A main-queue turn also coalesces the visible-page and preview callbacks.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.contentLayoutRequest == id else { return }
            self.contentLayoutRequest = nil
            self.configure(animate: true)
        }
    }
    private func present(_ layout: NotchGeometry, expanded: Bool, animate: Bool) {
        guard let panel, let surface else { return }
        let frame = layout.frame
        guard destinationFrame != frame || presentation.expanded != expanded || !animate else { return }
        destinationFrame = frame
        let id = UUID(); transitionID = id
        let changesExpansion = presentation.expanded != expanded
        presentation.expanded = expanded
        // The two hosts crossfade only when opening/closing. An already-open page
        // replaces its SwiftUI content at full size immediately, so its window and
        // clipping outline must change in the same transaction. A spring here cuts
        // the new Usage page beneath the previous (shorter) Agents outline.
        let animated = animate && changesExpansion && panel.isVisible && !reduceMotion()
        setPanelFrame(animated ? panel.frame.union(frame) : frame)
        surface.transition(size: frame.size, expanded: expanded, animated: animated) { [weak self] in
            guard let self, self.transitionID == id else { return }
            self.transitionID = nil
            self.setPanelFrame(frame)
            self.samplePointer()
        }
    }
    private func setPanelFrame(_ frame: NSRect) {
        guard let panel, panel.frame != frame else { return }
        placingWindow = true
        panel.setFrame(frame, display: false)
        placingWindow = false
    }
    private func configure(animate: Bool = false) {
        guard let store, let panel else { return }
        guard store.notchEnabled else {
            hoverTimer?.invalidate(); transitionID = nil; scheduledDeadline = nil; surface?.cancel()
            hoverState.dismiss(pointerInside: false)
            presentation.expanded = false; presentation.pinned = false; presentation.holdingList = false
            presentation.navigation.endPreview()
            panel.orderOut(nil); return
        }
        let screens = NSScreen.screens
        let screen = store.notchPreferMainDisplay ? screens.first : (screens.first { $0.safeAreaInsets.top > 0 } ?? screens.first)
        guard let screen else { panel.orderOut(nil); return }
        let gap: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            gap = max(0, right.minX - left.maxX)
        } else { gap = 0 }
        let compact = NotchGeometry.layout(screen: screen.frame, visibleFrame: screen.visibleFrame,
            safeTop: screen.safeAreaInsets.top, hardwareWidth: gap, expanded: false)
        let expanded = NotchGeometry.layout(screen: screen.frame, visibleFrame: screen.visibleFrame,
            safeTop: screen.safeAreaInsets.top, hardwareWidth: gap, expanded: true,
            visibleAgents: store.didCheckAgents ? presentation.visibleRows : 3)
        if presentation.compactGeometry != compact { presentation.compactGeometry = compact }
        if presentation.expandedGeometry != expanded { presentation.expandedGeometry = expanded }
        surface?.setContentSizes(compact: compact.frame.size, expanded: expanded.frame.size)
        present(hoverState.expanded ? expanded : compact, expanded: hoverState.expanded, animate: animate)
        if !panel.isVisible || !animate { panel.orderFrontRegardless() }
    }
    private func select(_ session: AgentSession) {
        // Collapse before handing focus to another app; opening a chat never sends input.
        collapse()
        if let url = session.chatURL, NSWorkspace.shared.open(url) { return }
        inspect(session)
    }
    private func inspect(_ session: AgentSession) {
        store?.selectAgent(session)
        openDashboardWindow()
    }
    func registerDashboard(_ window: NSWindow) { dashboardWindow = window }
    func openDashboardWindow() {
        collapse()
        if let window = dashboardWindow, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else { openDashboard?() }
        NSApp.activate(ignoringOtherApps: true)
    }
}
final class AgentNotchPanel: NSPanel {
    // AppKit otherwise pushes even borderless panels below the menu bar (33 pt on this Mac).
    // NotchGeometry owns screen bounds; this surface intentionally occupies the menu-bar area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
