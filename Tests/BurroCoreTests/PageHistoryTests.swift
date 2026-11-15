// Back and forward through the window's pages behave like a browser's history.
import XCTest
@testable import BurroCore

final class PageHistoryTests: XCTestCase {
    func testVisitPushesAndBackReturnsThePreviousPage() {
        var history = PageHistory(start: "home")
        XCTAssertFalse(history.canGoBack)
        history.visit("today")
        history.visit("chats")
        XCTAssertEqual(history.current, "chats")
        XCTAssertEqual(history.previous, "today")
        XCTAssertEqual(history.back(), "today")
        XCTAssertEqual(history.back(), "home")
        XCTAssertNil(history.back())
        XCTAssertEqual(history.current, "home")
    }
    func testForwardRetracesUntilANewVisitDropsIt() {
        var history = PageHistory(start: "home")
        history.visit("today")
        history.visit("chats")
        history.back(); history.back()
        XCTAssertTrue(history.canGoForward)
        XCTAssertEqual(history.forward(), "today")
        history.visit("usage")
        XCTAssertFalse(history.canGoForward)
        XCTAssertNil(history.forward())
        XCTAssertEqual(history.entries.map(\.page), ["home", "today", "usage"])
    }
    func testVisitingTheCurrentPageIsIgnored() {
        var history = PageHistory(start: "home")
        history.visit("home")
        history.visit("today")
        history.visit("today")
        XCTAssertEqual(history.entries.map(\.page), ["home", "today"])
        // Showing the page Back just returned to doesn't add an entry or drop the forward one.
        history.back()
        history.visit("home")
        XCTAssertTrue(history.canGoForward)
    }
    func testJumpOriginOnlyForPagesReachedByAJump() {
        var history = PageHistory(start: "today")
        history.visit("home")
        XCTAssertNil(history.jumpOrigin)
        history.visit("chats", jump: true)
        XCTAssertEqual(history.jumpOrigin, "home")
        history.back()
        XCTAssertNil(history.jumpOrigin)
        history.forward()
        XCTAssertEqual(history.jumpOrigin, "home")
    }
    func testKeepsOnlyTheNewestEntries() {
        var history = PageHistory(start: 0, limit: 3)
        for page in 1...5 { history.visit(page) }
        XCTAssertEqual(history.entries.map(\.page), [3, 4, 5])
        XCTAssertEqual(history.current, 5)
        XCTAssertEqual(history.back(), 4)
        XCTAssertEqual(history.back(), 3)
        XCTAssertNil(history.back())
    }
}
