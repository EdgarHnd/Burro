import AppKit
import XCTest
@testable import Burro

/// ⌘⌫ on the Worktrees page opens Move to Trash only when nothing is being typed in.
final class WorktreeTrashKeyTests: XCTestCase {
    func testCommandDeleteFiresOnlyOutsideTextFields() {
        XCTAssertTrue(WorktreeTrashKey.fires(keyCode: 51, modifiers: .command, sameWindow: true, editingText: false))
        XCTAssertTrue(WorktreeTrashKey.fires(keyCode: 51, modifiers: [.command, .capsLock], sameWindow: true, editingText: false))
        XCTAssertFalse(WorktreeTrashKey.fires(keyCode: 51, modifiers: .command, sameWindow: true, editingText: true), "typing in a field")
        XCTAssertFalse(WorktreeTrashKey.fires(keyCode: 51, modifiers: .command, sameWindow: false, editingText: false), "another window or a sheet")
        XCTAssertFalse(WorktreeTrashKey.fires(keyCode: 51, modifiers: [], sameWindow: true, editingText: false), "plain Delete")
        XCTAssertFalse(WorktreeTrashKey.fires(keyCode: 51, modifiers: [.command, .shift], sameWindow: true, editingText: false))
        XCTAssertFalse(WorktreeTrashKey.fires(keyCode: 117, modifiers: .command, sameWindow: true, editingText: false), "forward delete")
    }
}
