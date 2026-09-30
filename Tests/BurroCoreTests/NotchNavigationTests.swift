// Temporary previews must not change committed tabs or survive dismissal and rapid crossings.
import XCTest
@testable import BurroCore

final class NotchNavigationTests: XCTestCase {
    func testHoverPreviewsWithoutCommittingAfterShortDwell() {
        var state = NotchNavigation()
        state.updatePointer(over: .usage, now: 1)
        state.advance(now: 1.15)
        XCTAssertEqual(state.visible, .agents)
        state.advance(now: 1.17)
        XCTAssertEqual(state.visible, .usage)
        XCTAssertEqual(state.selected, .agents)
        XCTAssertTrue(state.isPreviewing)
    }
    func testPassingOverTabDoesNotFlashContent() {
        var state = NotchNavigation()
        state.updatePointer(over: .usage, now: 1)
        state.updatePointer(over: nil, now: 1.05)
        state.advance(now: 2)
        XCTAssertEqual(state.visible, .agents)
        XCTAssertNil(state.deadline)
    }
    func testLeavingPreviewRestoresSelectionAfterGrace() {
        var state = NotchNavigation()
        state.updatePointer(over: .usage, now: 1)
        state.advance(now: 1.2)
        state.updatePointer(over: nil, now: 2)
        state.advance(now: 2.04)
        XCTAssertEqual(state.visible, .usage)
        state.advance(now: 2.09)
        XCTAssertEqual(state.visible, .agents)
        XCTAssertFalse(state.isPreviewing)
    }
    func testClickCommitsAndCancelsPendingHoverReversion() {
        var state = NotchNavigation()
        state.updatePointer(over: .usage, now: 1)
        state.advance(now: 1.2)
        state.updatePointer(over: nil, now: 2)
        state.select(.usage)
        state.advance(now: 3)
        XCTAssertEqual(state.visible, .usage)
        XCTAssertEqual(state.selected, .usage)
        XCTAssertFalse(state.isPreviewing)
        XCTAssertNil(state.deadline)
    }
    func testClickDoesNotRequireHoverDwell() {
        var state = NotchNavigation()
        state.updatePointer(over: .usage, now: 1)
        state.select(.usage)
        state.advance(now: 2)
        XCTAssertEqual(state.visible, .usage)
        XCTAssertFalse(state.isPreviewing)
    }
    func testReturnToSelectedTabImmediatelyCancelsPreview() {
        var state = NotchNavigation()
        state.updatePointer(over: .usage, now: 1)
        state.advance(now: 1.2)
        state.updatePointer(over: .agents, now: 2)
        XCTAssertEqual(state.visible, .agents)
        XCTAssertNil(state.deadline)
    }
    func testCollapseClearsPreviewAndRetainsClickedTab() {
        var state = NotchNavigation()
        state.select(.usage)
        state.updatePointer(over: .agents, now: 1)
        state.advance(now: 1.2)
        XCTAssertEqual(state.visible, .agents)
        state.endPreview()
        state.advance(now: 3)
        XCTAssertEqual(state.visible, .usage)
        XCTAssertEqual(state.selected, .usage)
        XCTAssertNil(state.hovered)
        XCTAssertNil(state.deadline)
    }
    func testRepeatedMovementDoesNotPostponePreviewAndEdgeReentryCancelsRevert() {
        var state = NotchNavigation()
        state.updatePointer(over: .usage, now: 1)
        state.updatePointer(over: .usage, now: 1.12)
        state.advance(now: 1.17)
        XCTAssertEqual(state.preview, .usage)
        state.updatePointer(over: nil, now: 2)
        state.updatePointer(over: .usage, now: 2.04)
        state.advance(now: 2.1)
        XCTAssertEqual(state.visible, .usage)
        XCTAssertEqual(state.selected, .agents)
    }
}
