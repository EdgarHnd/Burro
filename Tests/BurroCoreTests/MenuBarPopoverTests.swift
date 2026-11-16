import XCTest
@testable import Burro

/// The menu-bar popover's Keep awake status line.
final class MenuBarPopoverTests: XCTestCase {
    func testKeepAwakeLineSaysWhenAClosedLidIsCovered() {
        XCTAssertEqual(MenuBarPopover.keepAwakeLine(agentsMode: true, awake: true, headline: "Awake", working: 3), "While agents work · 3 now")
        XCTAssertEqual(MenuBarPopover.keepAwakeLine(agentsMode: true, awake: false, headline: "Off", working: 0), "While agents work · none now")
        XCTAssertEqual(MenuBarPopover.keepAwakeLine(agentsMode: false, awake: true, headline: "Awake until 15:00", working: 0, lidClosed: true),
                       "Awake until 15:00 · lid closed")
        XCTAssertEqual(MenuBarPopover.keepAwakeLine(agentsMode: false, awake: false, headline: "Off", working: 0), "Off")
    }
}
