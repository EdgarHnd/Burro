// Pointer acceptance, exit hysteresis, reentry, and deliberate dismissal regressions.
import XCTest
@testable import BurroCore

final class NotchHoverTests: XCTestCase {
    func testEntryOpensImmediatelyWithoutWaitingForAnotherEvent() {
        var state = NotchHoverState()
        state.updatePointer(inside: true, now: 0)
        XCTAssertTrue(state.expanded)
        XCTAssertNil(state.deadline)
        XCTAssertFalse(state.pinned)
    }
    func testLeavingClosesAfterShortGracePeriod() {
        var state = NotchHoverState()
        state.show(pointerInside: true)
        state.updatePointer(inside: false, now: 1)
        state.advance(now: 1.10)
        XCTAssertTrue(state.expanded)
        state.advance(now: 1.13)
        XCTAssertFalse(state.expanded)
    }
    func testRepeatedOutsideMovementDoesNotPostponeClosing() {
        var state = NotchHoverState()
        state.show(pointerInside: true)
        for time in stride(from: 1.0, through: 1.10, by: 0.01) { state.updatePointer(inside: false, now: time) }
        state.advance(now: 1.13)
        XCTAssertFalse(state.expanded)
    }
    func testReentryCancelsCloseWithoutFlapping() {
        var state = NotchHoverState()
        state.show(pointerInside: true)
        state.updatePointer(inside: false, now: 1)
        state.updatePointer(inside: true, now: 1.10)
        state.advance(now: 2)
        XCTAssertTrue(state.expanded)
        XCTAssertNil(state.deadline)
    }
    func testReturningDuringCloseReopensWithoutAnotherDwell() {
        var state = NotchHoverState()
        state.show(pointerInside: true)
        state.updatePointer(inside: false, now: 1)
        state.advance(now: 1.13)
        XCTAssertFalse(state.expanded)
        state.updatePointer(inside: true, now: 1.14)
        XCTAssertTrue(state.expanded)
        XCTAssertNil(state.deadline)
    }
    func testDeliberateCollapseStaysClosedUntilPointerLeaves() {
        var state = NotchHoverState()
        state.show(pointerInside: true)
        state.dismiss(pointerInside: true)
        state.updatePointer(inside: true, now: 1)
        state.advance(now: 2)
        XCTAssertFalse(state.expanded)
        state.updatePointer(inside: false, now: 3)
        state.updatePointer(inside: true, now: 4)
        XCTAssertTrue(state.expanded)
    }
    func testOnlyExplicitPinKeepsPanelOpenOutside() {
        var state = NotchHoverState()
        state.show(pointerInside: true)
        state.togglePin(now: 0)
        state.updatePointer(inside: false, now: 1)
        state.advance(now: 2)
        XCTAssertTrue(state.expanded)
        XCTAssertTrue(state.pinned)
        state.togglePin(now: 3)
        state.advance(now: 3.13)
        XCTAssertFalse(state.expanded)
    }
    func testKeyboardOpeningWaitsForFirstVisitAndThenClosesOnExit() {
        var state = NotchHoverState()
        state.show(pointerInside: false)
        state.updatePointer(inside: false, now: 1)
        state.advance(now: 2)
        XCTAssertTrue(state.expanded)
        state.updatePointer(inside: true, now: 3)
        state.updatePointer(inside: false, now: 4)
        state.advance(now: 4.13)
        XCTAssertFalse(state.expanded)
    }
    func testApproachMarginAndPhysicalTopEdgeAreInteractive() {
        let compact = CGRect(x: 400, y: 866, width: 293, height: 34)
        let expanded = CGRect(x: 306.5, y: 527, width: 480, height: 373)
        for point in [CGPoint(x: 546, y: 900), CGPoint(x: 546, y: 859), CGPoint(x: 394, y: 880)] {
            XCTAssertTrue(NotchHoverRegion.contains(point, compact: compact, expanded: expanded, isExpanded: false, isClosing: false))
        }
        XCTAssertFalse(NotchHoverRegion.contains(CGPoint(x: 546, y: 901), compact: compact, expanded: expanded, isExpanded: false, isClosing: false))
        XCTAssertFalse(NotchHoverRegion.contains(CGPoint(x: 546, y: 857), compact: compact, expanded: expanded, isExpanded: false, isClosing: false))
    }
    func testExpandedEdgeToleranceAndClosingRegionDoNotChasePointer() {
        let compact = CGRect(x: -546, y: 866, width: 293, height: 34)
        let expanded = CGRect(x: -640, y: 527, width: 480, height: 373)
        let point = CGPoint(x: -400, y: 519)
        XCTAssertTrue(NotchHoverRegion.contains(point, compact: compact, expanded: expanded, isExpanded: true, isClosing: false))
        XCTAssertTrue(NotchHoverRegion.contains(point, compact: compact, expanded: expanded, isExpanded: false, isClosing: true))
        XCTAssertFalse(NotchHoverRegion.contains(point, compact: compact, expanded: expanded, isExpanded: false, isClosing: false))
        XCTAssertFalse(NotchHoverRegion.contains(CGPoint(x: -400, y: 516), compact: compact, expanded: expanded, isExpanded: true, isClosing: false))
    }
    func testCompactFootprintLeavesOnlySmallStatusWings() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let camera = NotchGeometry.layout(screen: screen, visibleFrame: screen, safeTop: 32, hardwareWidth: 185, expanded: false)
        XCTAssertEqual(camera.frame.size, CGSize(width: 341, height: 34))
        XCTAssertEqual(camera.frame.maxY, screen.maxY)
        let flat = NotchGeometry.layout(screen: screen, visibleFrame: screen, safeTop: 0, hardwareWidth: 0, expanded: false)
        XCTAssertEqual(flat.frame.size, CGSize(width: 156, height: 26))
    }
}
