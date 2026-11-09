import XCTest
import Darwin
@testable import BurroCore

final class CodexWriterLocksTests: XCTestCase {
    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-lock-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    func testHistoricalChatsDoNotProbeMissingLockFiles() throws {
        let folder = try fixture()
        try Data().write(to: folder.appendingPathComponent("live.lock"))
        let locks = CodexWriterLocks(directory: folder)
        var probes = 0
        for i in 0..<10_000 { XCTAssertEqual(locks.held("old-\(i)") { _ in probes += 1; return -1 }, 0) }
        XCTAssertEqual(probes, 0)
        XCTAssertEqual(locks.held("live") { _ in probes += 1; return 1 }, 1)
        XCTAssertEqual(probes, 1)
        XCTAssertTrue(locks.isCurrent)
    }
    func testExistingLocksRemainLiveAcrossBothPasses() throws {
        let folder = try fixture(), file = folder.appendingPathComponent("live.lock")
        try Data().write(to: file)
        let locks = CodexWriterLocks(directory: folder)
        XCTAssertEqual(locks.held("live"), 0)
        let fd = Darwin.open(file.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(locks.held("live"), 1)
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        XCTAssertEqual(locks.held("live"), 0)
        XCTAssertTrue(locks.isCurrent)
    }
    func testCreatingOrRemovingLockInvalidatesFilenameSnapshot() throws {
        let folder = try fixture(), file = folder.appendingPathComponent("new.lock")
        let before = CodexWriterLocks(directory: folder)
        try Data().write(to: file)
        XCTAssertFalse(before.isCurrent)
        let after = CodexWriterLocks(directory: folder)
        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(after.isCurrent)
    }
    func testSymlinkedDirectoryFallsBackToPerFileChecks() throws {
        let folder = try fixture(), link = folder.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let locks = CodexWriterLocks(directory: link)
        var probes = 0
        XCTAssertEqual(locks.held("missing") { _ in probes += 1; return -1 }, -1)
        XCTAssertEqual(probes, 1)
    }
}
