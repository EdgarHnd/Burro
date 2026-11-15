// Open at login: how macOS's login-item status reads in Settings and the Today menu. Nothing here
// registers a login item.
import XCTest
@testable import BurroCore

final class LoginItemPresentationTests: XCTestCase {
    func testEachStatusSetsTheToggleTheNoteAndTheApprovalButton() {
        let on = LoginItemPresentation(state: .enabled)
        XCTAssertEqual(on, LoginItemPresentation(state: .enabled, failure: nil))
        XCTAssertTrue(on.isOn)
        XCTAssertFalse(on.needsApproval)
        XCTAssertNil(on.note)

        let off = LoginItemPresentation(state: .notRegistered)
        XCTAssertFalse(off.isOn, "Off until you turn it on")
        XCTAssertFalse(off.needsApproval)
        XCTAssertNil(off.note)

        let pending = LoginItemPresentation(state: .requiresApproval)
        XCTAssertTrue(pending.isOn, "Registered and waiting, so turning it off unregisters")
        XCTAssertTrue(pending.needsApproval)
        XCTAssertEqual(pending.note, "Waiting for your approval in System Settings › General › Login Items.")
        XCTAssertFalse(pending.isProblem)

        let missing = LoginItemPresentation(state: .notFound)
        XCTAssertFalse(missing.isOn)
        XCTAssertFalse(missing.needsApproval)
        XCTAssertTrue(missing.isProblem)
        XCTAssertNotNil(missing.note)
    }

    func testAFailureIsShownButTheToggleKeepsFollowingTheStatus() {
        let message = LoginItemPresentation.failure(turningOn: true, reason: "Operation not permitted\n")
        XCTAssertEqual(message, "Couldn't add Burro to your login items: Operation not permitted")
        XCTAssertEqual(LoginItemPresentation.failure(turningOn: false, reason: "  "), "Couldn't remove Burro from your login items.")

        let failedOn = LoginItemPresentation(state: .notRegistered, failure: message)
        XCTAssertFalse(failedOn.isOn)
        XCTAssertEqual(failedOn.note, message)
        XCTAssertTrue(failedOn.isProblem)

        let failedOff = LoginItemPresentation(state: .requiresApproval, failure: "Couldn't remove Burro from your login items.")
        XCTAssertTrue(failedOff.isOn)
        XCTAssertTrue(failedOff.needsApproval, "The approval button stays while it's still pending")
        XCTAssertEqual(failedOff.note, "Couldn't remove Burro from your login items.")
    }
}
