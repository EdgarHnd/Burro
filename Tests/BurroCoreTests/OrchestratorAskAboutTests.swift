import XCTest
@testable import BurroCore

final class OrchestratorAskAboutTests: XCTestCase {
    func testNamesTheChatAndItsMachine() {
        XCTAssertEqual(OrchestratorAskAbout.question(title: "Fix the login bug", machine: "studio"),
                       "What's the latest on “Fix the login bug” (studio)?")
    }
    func testBlankMachineIsThisMacAndBlankTitleIsThisChat() {
        XCTAssertEqual(OrchestratorAskAbout.question(title: " Ship it ", machine: nil), "What's the latest on “Ship it” (This Mac)?")
        XCTAssertEqual(OrchestratorAskAbout.question(title: "", machine: "  "), "What's the latest on “this chat” (This Mac)?")
    }
}
