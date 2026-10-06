// Verify the AppKit boundary that previously displaced the notch below the menu bar.
import AppKit
import QuartzCore
import XCTest
@testable import Burro
@testable import BurroCore

final class NotchPanelTests: XCTestCase {
    @MainActor func testAttentionUpdatesWithoutExpansionAndSurvivesUsageAndSpaceChanges() async throws {
        _ = NSApplication.shared
        let name = "burro-attention-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(true, forKey: "notchEnabled")
        defaults.set(false, forKey: "usageEnabled")
        defaults.set(false, forKey: "discover")
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppStore(defaults: defaults)
        let controller = NotchController(pointerLocation: { NSPoint(x: -100_000, y: -100_000) }, reduceMotion: { true })
        controller.start(store: store, openDashboard: {})
        defer { controller.stop() }
        let surface = try XCTUnwrap(controller.surface)
        let panel = try XCTUnwrap(controller.panel)
        let compactFrame = panel.frame
        var done = AgentSession(id: "fixture", provider: .codex, title: "Completed fixture", cwd: "/fixture", state: .idle,
                                updatedAt: Date(), evidence: "fixture", hasUnreadResult: true)
        store.agentActivity = AgentActivitySnapshot(sessions: [done], warnings: [], sampledAt: Date())
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(surface.attention, .done)
        XCTAssertEqual(surface.attentionGlow.opacity, 1)
        XCTAssertFalse(controller.presentation.expanded)
        XCTAssertEqual(panel.frame, compactFrame, "Glowing cannot expand the pointer hit area")
        XCTAssertNil(surface.attentionGlow.animationKeys(), "Reduce Motion leaves a steady indicator")
        controller.selectPage(.usage)
        controller.show()
        XCTAssertEqual(surface.attentionGlow.opacity, 0, "The rim is only needed while collapsed")
        done.state = .waiting
        store.agentActivity.sessions = [done]
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(surface.attention, .waiting)
        controller.collapse()
        XCTAssertEqual(surface.attentionGlow.opacity, 1)
        XCTAssertEqual(controller.presentation.navigation.visible, .usage)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(surface.attentionGlow.opacity, 1)
        XCTAssertEqual(panel.frame, compactFrame)
        done.state = .idle; done.hasUnreadResult = false
        store.agentActivity.sessions = [done]
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(surface.attention, .none)
        XCTAssertEqual(surface.attentionGlow.opacity, 0)
        controller.stop()
        store.agentActivity.sessions = []
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(controller.panel, "A queued observation cannot reopen a stopped controller")
    }
    @MainActor func testAttentionRimProducesVisiblePixelsAndClears() async throws {
        try await withController(reduceMotion: true) { controller, _ in
            let surface = try XCTUnwrap(controller.surface)
            surface.layoutSubtreeIfNeeded()
            @MainActor func render(_ attention: AgentAttention) throws -> NSBitmapImageRep {
                surface.setAttention(attention, animated: false)
                let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
                surface.cacheDisplay(in: surface.bounds, to: bitmap)
                return bitmap
            }
            let off = try render(.none), blue = try render(.done), amber = try render(.waiting)
            func changedPixels(_ image: NSBitmapImageRep) -> Int {
                var count = 0
                for y in 0..<image.pixelsHigh {
                    for x in 0..<image.pixelsWide {
                        guard let a = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                              let b = off.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.15 { count += 1 }
                    }
                }
                return count
            }
            XCTAssertGreaterThan(changedPixels(blue), 100, "A layer state alone does not prove the glow is visible")
            XCTAssertGreaterThan(changedPixels(amber), 100)
            XCTAssertEqual(changedPixels(try render(.none)), 0)
            if let directory = ProcessInfo.processInfo.environment["BURRO_NOTCH_RENDER_DIR"] {
                let root = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                for (name, bitmap) in [("off", off), ("done", blue), ("waiting", amber)] {
                    try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent(name + ".png"))
                }
            }
        }
    }
    @MainActor func testOverlayJoinsOtherApplicationsWithoutTakingFocus() async throws {
        try await withController(reduceMotion: true) { controller, _ in
            let panel = try XCTUnwrap(controller.panel)
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
            XCTAssertFalse(panel.hidesOnDeactivate)
            XCTAssertEqual(panel.level.rawValue, NSWindow.Level.statusBar.rawValue + 1)
            XCTAssertFalse(panel.isKeyWindow)
            XCTAssertFalse(panel.isMainWindow)
        }
    }
    @MainActor func testTabPreviewUsesScreenCoordinatesAndCommonModeDeadline() async throws {
        try await withController(reduceMotion: true) { controller, move in
            controller.show()
            try await Task.sleep(for: .milliseconds(100))
            let frame = controller.presentation.expandedGeometry.frame
            let usage = try XCTUnwrap(controller.navigationBounds[.usage])
            move(NSPoint(x: frame.minX + usage.midX, y: frame.maxY - usage.midY))
            controller.samplePointer()
            XCTAssertEqual(controller.presentation.navigation.visible, .agents)
            runMouseTrackingLoop(for: 0.20)
            XCTAssertEqual(controller.presentation.navigation.visible, .usage)
            XCTAssertEqual(controller.presentation.navigation.selected, .agents)
            move(NSPoint(x: frame.minX + 300, y: frame.maxY - 100))
            controller.samplePointer()
            runMouseTrackingLoop(for: 0.11)
            XCTAssertEqual(controller.presentation.navigation.visible, .agents)
            XCTAssertTrue(controller.presentation.expanded)
        }
    }
    @MainActor func testClickedTabSurvivesCollapseAndPendingPreviewCannotReopenPanel() async throws {
        try await withController(reduceMotion: true) { controller, move in
            controller.selectPage(.usage)
            controller.show()
            try await Task.sleep(for: .milliseconds(100))
            let frame = controller.presentation.expandedGeometry.frame
            let agents = try XCTUnwrap(controller.navigationBounds[.agents])
            move(NSPoint(x: frame.minX + agents.midX, y: frame.maxY - agents.midY))
            controller.samplePointer()
            controller.collapse()
            runMouseTrackingLoop(for: 0.20)
            XCTAssertFalse(controller.presentation.expanded)
            XCTAssertEqual(controller.presentation.navigation.visible, .usage)
            move(NSPoint(x: -100_000, y: -100_000)); controller.samplePointer()
            controller.show()
            XCTAssertEqual(controller.presentation.navigation.visible, .usage)
        }
    }
    @MainActor private func runMouseTrackingLoop(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { _ = RunLoop.main.run(mode: .eventTracking, before: until) }
    }

    @MainActor func testNativeMenuTrackingKeepsNotchOpenOutsidePanelUntilMenuEnds() async throws {
        try await withController(reduceMotion: true) { controller, move in
            let frame = try XCTUnwrap(controller.panel).frame
            move(NSPoint(x: frame.midX, y: frame.maxY)); controller.samplePointer()
            let menu = NSMenu()
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            move(NSPoint(x: frame.midX, y: frame.minY - 1000)); controller.samplePointer()
            runMouseTrackingLoop(for: 0.18)
            XCTAssertTrue(controller.presentation.expanded)
            XCTAssertTrue(controller.presentation.holdingList)
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
            runMouseTrackingLoop(for: 0.18)
            XCTAssertFalse(controller.presentation.expanded)
        }
    }

    @MainActor func testListHoldFollowsHoverWithoutChangingHoverDeadlines() async throws {
        try await withController(reduceMotion: true) { controller, move in
            let frame = try XCTUnwrap(controller.panel).frame
            move(NSPoint(x: frame.midX, y: frame.maxY)); controller.samplePointer()
            XCTAssertTrue(controller.presentation.holdingList)
            XCTAssertTrue(controller.presentation.expanded)
            let expanded = try XCTUnwrap(controller.panel).frame
            move(NSPoint(x: expanded.midX, y: expanded.minY - 20)); controller.samplePointer()
            XCTAssertFalse(controller.presentation.holdingList)
            XCTAssertTrue(controller.presentation.expanded, "Exit grace still applies")
            runMouseTrackingLoop(for: 0.18)
            XCTAssertFalse(controller.presentation.expanded)
        }
    }

    @MainActor func testExitDeadlineFiresDuringNativeMouseTracking() async throws {
        try await withController(reduceMotion: true) { controller, move in
            let panel = try XCTUnwrap(controller.panel)
            controller.show()
            let expanded = panel.frame
            move(NSPoint(x: expanded.midX, y: expanded.midY)); controller.samplePointer()
            move(NSPoint(x: expanded.midX, y: expanded.minY - 20)); controller.samplePointer()
            runMouseTrackingLoop(for: 0.18)
            XCTAssertFalse(controller.presentation.expanded, "Closing must not wait for AppKit to leave mouse-tracking mode")
        }
    }

    @MainActor func testApproachingBelowNativeWindowOpensImmediatelyAndTopEdgeRemainsInside() async throws {
        try await withController { controller, move in
            let frame = try XCTUnwrap(controller.panel).frame
            move(NSPoint(x: frame.midX, y: frame.minY - 6))
            controller.samplePointer()
            XCTAssertTrue(controller.presentation.expanded, "Approach must work outside the native window's tracking area")
            move(NSPoint(x: frame.midX, y: frame.maxY))
            controller.samplePointer()
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertTrue(controller.presentation.expanded, "The physical top edge must not be treated as an exit")
        }
    }

    @MainActor func testCompositorDisplaysIntermediateFramesDuringOpeningAndClosing() async throws {
        try await withController { controller, _ in
            let panel = try XCTUnwrap(controller.panel)
            let surface = try XCTUnwrap(controller.surface)
            let compactHeight = panel.frame.height
            // Allow the initial compact transaction to reach the render server.
            try await Task.sleep(for: .milliseconds(80))
            controller.show()
            let expandedHeight = panel.frame.height
            let recorder = NotchFrameRecorder(layer: surface.background)
            recorder.start(view: surface)
            try await Task.sleep(for: .milliseconds(280))
            recorder.stop()
            let opening = recorder.frames.filter { $0.height > compactHeight + 1 && $0.height < expandedHeight - 1 }
            XCTAssertGreaterThan(opening.count, 5, "A passing state transition is insufficient: visible intermediate frames are required")
            XCTAssertGreaterThan(Set(opening.map { Int($0.height) }).count, 5)
            XCTAssertGreaterThan(opening.last?.height ?? 0, opening.first?.height ?? 0)
            try await Task.sleep(for: .milliseconds(250))
            controller.collapse()
            recorder.start(view: surface)
            try await Task.sleep(for: .milliseconds(280))
            recorder.stop()
            let closing = recorder.frames.filter { $0.height > compactHeight + 1 && $0.height < expandedHeight - 1 }
            XCTAssertGreaterThan(closing.count, 5)
            XCTAssertLessThan(closing.last?.height ?? 0, closing.first?.height ?? 0)
            let maxGap = zip(recorder.frames, recorder.frames.dropFirst()).map { $1.time - $0.time }.max() ?? 0
            print("Notch compositor: \(opening.count) opening / \(closing.count) closing intermediate frames; max sampled display-link gap \(Int(maxGap * 1000)) ms")
        }
    }

    @MainActor private func withController(reduceMotion: Bool = false,
        _ test: @MainActor (NotchController, @MainActor (NSPoint) -> Void) async throws -> Void) async throws {
        _ = NSApplication.shared
        let name = "burro-notch-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(true, forKey: "notchEnabled")
        defaults.set(false, forKey: "discover")
        defaults.set(false, forKey: "usageEnabled") // Native interaction tests never contact provider accounts.
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppStore(defaults: defaults)
        var pointer = NSPoint(x: -100_000, y: -100_000)
        let controller = NotchController(pointerLocation: { pointer }, reduceMotion: { reduceMotion })
        controller.start(store: store, openDashboard: {})
        defer { controller.stop() }
        try await test(controller, { pointer = $0 })
    }

    @MainActor func testNativeWindowStaysStillThroughCollapseAndShrinksAfterAnimation() async throws {
        try await withController { controller, move in
            let panel = try XCTUnwrap(controller.panel)
            let compact = panel.frame
            controller.show()
            try await Task.sleep(for: .milliseconds(650))
            let expanded = panel.frame
            XCTAssertGreaterThan(expanded.height, compact.height)
            move(NSPoint(x: expanded.midX, y: expanded.midY)); controller.samplePointer()
            move(NSPoint(x: expanded.midX, y: expanded.minY - 20)); controller.samplePointer()
            try await Task.sleep(for: .milliseconds(145))
            XCTAssertFalse(controller.presentation.expanded)
            XCTAssertEqual(panel.frame, expanded, "Native frame must not animate with the surface")
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(panel.frame, expanded, "The old implementation resized every 16 ms")
            try await Task.sleep(for: .milliseconds(650))
            XCTAssertEqual(panel.frame, compact, "Transparent space must stop intercepting input once settled")
        }
    }

    @MainActor func testReentryReversesClosingAndOldCompletionCannotShrinkReopenedWindow() async throws {
        try await withController { controller, move in
            let panel = try XCTUnwrap(controller.panel)
            controller.show()
            try await Task.sleep(for: .milliseconds(650))
            let expanded = panel.frame
            let inside = NSPoint(x: expanded.midX, y: expanded.midY)
            move(inside); controller.samplePointer()
            move(NSPoint(x: expanded.midX, y: expanded.minY - 20)); controller.samplePointer()
            try await Task.sleep(for: .milliseconds(155))
            XCTAssertFalse(controller.presentation.expanded)
            move(inside); controller.samplePointer()
            XCTAssertTrue(controller.presentation.expanded, "Reentry during closing must not wait for another dwell")
            try await Task.sleep(for: .milliseconds(700))
            XCTAssertEqual(panel.frame, expanded)
            XCTAssertTrue(controller.presentation.expanded)
        }
    }

    @MainActor func testReduceMotionSetsFinalNativeFrameImmediately() async throws {
        try await withController(reduceMotion: true) { controller, _ in
            let panel = try XCTUnwrap(controller.panel)
            let compact = panel.frame
            controller.show()
            XCTAssertEqual(panel.frame, controller.presentation.expandedGeometry.frame)
            controller.collapse()
            XCTAssertEqual(panel.frame, compact)
        }
    }

    @MainActor func testPanelDoesNotShiftOrResizeTopEdgeFrames() async throws {
        _ = NSApplication.shared
        let panel = AgentNotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        for height: CGFloat in [37, 373] {
            let requested = NSRect(x: screen.frame.midX - 240, y: screen.frame.maxY - height, width: 480, height: height)
            XCTAssertEqual(panel.constrainFrameRect(requested, to: screen), requested)
            panel.setFrame(requested, display: false)
            XCTAssertEqual(panel.frame, requested)
        }
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }
}

@MainActor private final class NotchFrameRecorder: NSObject {
    struct Frame { var time: CFTimeInterval; var height: CGFloat }
    private let layer: CAShapeLayer
    private var link: CADisplayLink?
    var frames: [Frame] = []
    init(layer: CAShapeLayer) { self.layer = layer }
    func start(view: NSView) {
        stop(); frames = []
        let link = view.displayLink(target: self, selector: #selector(tick))
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func tick(_ link: CADisplayLink) {
        guard let path = layer.presentation()?.path else { return }
        frames.append(Frame(time: CACurrentMediaTime(), height: path.boundingBoxOfPath.height))
    }
}
