import AppKit
import QuartzCore
import XCTest
@testable import Burro

final class BurroMascotTests: XCTestCase {
    @MainActor func testMotionFollowsActivityWithoutRestartingBlinkAndRespectsReduceMotion() async throws {
        try await withMascot { view, _ in
            view.configure(active: true, working: false, reduceMotion: false)
            let blink = try XCTUnwrap(view.eyes.animation(forKey: "blink"))
            XCTAssertNil(view.mascot.animation(forKey: "hop"))
            XCTAssertNotNil(view.mascot.animation(forKey: "idle"))
            view.configure(active: true, working: true, reduceMotion: false)
            XCTAssertNotNil(view.mascot.animation(forKey: "hop"))
            XCTAssertNil(view.mascot.animation(forKey: "idle"))
            XCTAssertNil(view.plate.animationKeys(), "Only the butter jumps; the plate stays grounded")
            XCTAssertEqual(view.eyes.animation(forKey: "blink")?.beginTime, blink.beginTime)
            view.configure(active: true, working: false, reduceMotion: false)
            XCTAssertNil(view.mascot.animation(forKey: "hop"))
            XCTAssertEqual(view.eyes.animation(forKey: "blink")?.beginTime, blink.beginTime)

            view.configure(active: true, working: true, reduceMotion: true)
            XCTAssertNil(view.eyes.animationKeys())
            XCTAssertNil(view.mascot.animationKeys())
            XCTAssertTrue(CATransform3DIsIdentity(view.mascot.transform))
            XCTAssertEqual(view.eyes.path, view.eyeMask(openness: 1))
            view.configure(active: true, working: true, reduceMotion: false)
            XCTAssertNotNil(view.eyes.animation(forKey: "blink"))
            XCTAssertEqual(view.frame.size, NSSize(width: 22, height: 22))
            XCTAssertNil(view.hitTest(NSPoint(x: 11, y: 11)))
        }
    }

    @MainActor func testClosingHidingAndDetachingStopAllMotion() async throws {
        try await withMascot { view, panel in
            view.configure(active: true, working: true, reduceMotion: false)
            view.configure(active: false, working: true, reduceMotion: false)
            XCTAssertNil(view.eyes.animationKeys(), "Expanded hosting views stay mounted when the notch collapses")
            XCTAssertNil(view.mascot.animationKeys())
            view.configure(active: true, working: true, reduceMotion: false)
            view.isHidden = true
            XCTAssertNil(view.eyes.animationKeys())
            view.isHidden = false
            XCTAssertNotNil(view.eyes.animation(forKey: "blink"))

            panel.orderOut(nil)
            try await settleVisibility(panel, visible: false)
            XCTAssertNil(view.eyes.animationKeys())
            XCTAssertNil(view.mascot.animationKeys())
            panel.orderFrontRegardless()
            try await settleVisibility(panel, visible: true)
            XCTAssertNotNil(view.eyes.animation(forKey: "blink"))
            view.removeFromSuperview()
            XCTAssertNil(view.eyes.animationKeys())
            XCTAssertNil(view.mascot.animationKeys())
        }
    }

    @MainActor func testBlinkClosesTransparentEyesWithoutChangingSilhouette() throws {
        let view = BurroMascotView()
        view.frame.size = NSSize(width: 108, height: 108)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(BurroBrand.eyes.count, 2)
        let open = view.eyeMask(openness: 1), closed = view.eyeMask(openness: 0.12)
        for eye in BurroBrand.eyes {
            let upperEye = CGPoint(x: eye.midX, y: eye.midY - eye.height * 0.3)
            XCTAssertFalse(open.contains(upperEye, using: .evenOdd))
            XCTAssertTrue(closed.contains(upperEye, using: .evenOdd))
            XCTAssertFalse(closed.contains(CGPoint(x: eye.midX, y: eye.midY), using: .evenOdd))
        }
        XCTAssertEqual(open.boundingBox, closed.boundingBox)
    }

    @MainActor func testButterLiftsOffStationaryPlateAndKeepsProviderTint() async throws {
        try await withMascot { view, _ in
            let tint = NSColor(srgbRed: 0.40, green: 0.68, blue: 1, alpha: 1)
            view.configure(active: true, working: true, reduceMotion: false, tint: tint)
            let plateFrame = view.plate.frame
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(770))
            let body = try XCTUnwrap(view.mascot.presentation())
            let plate = try XCTUnwrap(view.plate.presentation())
            XCTAssertLessThan(body.transform.m42, -1.5, "The rendered butter should be visibly above its resting place")
            XCTAssertTrue(CATransform3DIsIdentity(plate.transform))
            XCTAssertEqual(plate.frame, plateFrame)
            XCTAssertEqual(view.plate.backgroundColor, tint.cgColor)
            XCTAssertEqual(view.frame.size, NSSize(width: 22, height: 22))
        }
    }

    @MainActor func testOffscreenAgentAvatarsPauseAndResume() async throws {
        try await withMascot { view, panel in
            let root = try XCTUnwrap(panel.contentView)
            let scroll = NSScrollView(frame: root.bounds)
            let document = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 200))
            view.removeFromSuperview()
            document.addSubview(view)
            scroll.documentView = document
            root.addSubview(scroll)
            scroll.tile()
            scroll.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: .zero)
            view.configure(active: true, working: true, reduceMotion: false)
            XCTAssertNotNil(view.mascot.animation(forKey: "hop"))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
            XCTAssertFalse(view.bounds.intersects(view.visibleRect))
            XCTAssertNil(view.mascot.animationKeys())
            XCTAssertNil(view.eyes.animationKeys())
            scroll.contentView.scroll(to: .zero)
            XCTAssertNotNil(view.mascot.animation(forKey: "hop"))
        }
    }

    @MainActor private func withMascot(_ body: @MainActor (BurroMascotView, NSPanel) async throws -> Void) async throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        guard let screen = NSScreen.main else { throw XCTSkip("A display is needed for native animation lifecycle checks") }
        let panel = NSPanel(contentRect: NSRect(x: screen.visibleFrame.minX + 30, y: screen.visibleFrame.minY + 30,
                                              width: 40, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        let view = BurroMascotView()
        view.frame = NSRect(x: 9, y: 9, width: 22, height: 22)
        root.addSubview(view)
        panel.contentView = root
        panel.orderFrontRegardless()
        defer { view.stopAnimating(); panel.close() }
        try await settleVisibility(panel, visible: true)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.mascot.bounds.size, NSSize(width: 22, height: 22))
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.occlusionState.contains(.visible))
        try await body(view, panel)
        XCTAssertFalse(panel.isKeyWindow)
    }

    // XCTest does not run NSApplication's normal event pump. Occlusion notifications
    // arrive as window-server events and must be dispatched before checking motion.
    @MainActor private func settleVisibility(_ panel: NSPanel, visible: Bool) async throws {
        for _ in 0..<50 {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            if panel.occlusionState.contains(.visible) == visible { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Window-server visibility did not settle")
    }
}
