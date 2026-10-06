// Verify silent legacy reads, permission failures, and restoration without accessing credentials.
import Security
import XCTest
@testable import BurroCore

final class KeychainAccessTests: XCTestCase {
    func testBackgroundReadDisablesLegacyUIAndRestoresIt() throws {
        var allowed = true, changes: [Bool] = []
        let value = try KeychainAccess.withInteraction(allowPrompt: false,
            get: { (errSecSuccess, allowed) }, set: { allowed = $0; changes.append($0); return errSecSuccess }) {
                XCTAssertFalse(allowed)
                return 42
            }
        XCTAssertEqual(value, 42)
        XCTAssertTrue(allowed)
        XCTAssertEqual(changes, [false, true])
    }

    func testCancelledExplicitReadRestoresPreviousSilentState() {
        var allowed = false, changes: [Bool] = []
        XCTAssertThrowsError(try KeychainAccess.withInteraction(allowPrompt: true,
            get: { (errSecSuccess, allowed) }, set: { allowed = $0; changes.append($0); return errSecSuccess }) {
                XCTAssertTrue(allowed)
                throw UsageIssue.permissionRequired
            }) { XCTAssertEqual($0 as? UsageIssue, .permissionRequired) }
        XCTAssertFalse(allowed)
        XCTAssertEqual(changes, [true, false])
    }

    func testCannotReadUntilSilentPolicyIsEstablished() {
        for failGet in [true, false] {
            var reads = 0
            XCTAssertThrowsError(try KeychainAccess.withInteraction(allowPrompt: false,
                get: { (failGet ? errSecNotAvailable : errSecSuccess, true) },
                set: { _ in errSecNotAvailable }, operation: { reads += 1 })) {
                    XCTAssertEqual($0 as? UsageIssue, .permissionRequired)
                }
            XCTAssertEqual(reads, 0)
        }
    }

    func testNativeScopeActuallyDisablesAndRestoresLegacyUI() throws {
        var before: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&before), errSecSuccess)
        try KeychainAccess.perform(allowPrompt: false) {
            var during: DarwinBoolean = true
            XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&during), errSecSuccess)
            XCTAssertFalse(during.boolValue)
        }
        var after: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&after), errSecSuccess)
        XCTAssertEqual(before.boolValue, after.boolValue)
    }
}
