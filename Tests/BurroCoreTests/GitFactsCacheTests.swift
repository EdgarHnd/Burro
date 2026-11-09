import XCTest
@testable import BurroCore

final class GitFactsCacheTests: XCTestCase {
    func testCacheIsOptInAndCannotReplaceCleanupChecks() {
        XCTAssertFalse(ScanConfiguration().incremental)
        let cache = GitFactsCache(), record = WorktreeRecord(path: "/missing")
        var count = 0
        for _ in 0..<2 { _ = cache.facts(record, base: nil) { count += 1; return GitFacts() } }
        XCTAssertEqual(count, 2, "Without a working watcher every read must remain fresh")
    }

    func testEventsHEADBaseExpiryAndConcurrentChangesInvalidateFacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("burro-git-cache-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = Paths.canonical(root.path), record = WorktreeRecord(path: path, head: "one", branch: "feature")
        let cache = GitFactsCache(lifetime: 60)
        cache.prepare(watches: [path: [path]], globals: [])
        try await Task.sleep(for: .milliseconds(700))
        var count = 0
        func load() -> GitFacts {
            count += 1
            var facts = GitFacts(); facts.changed = count; facts.merged = true
            facts.unpushed = 0; facts.retentionChecked = true; facts.lastCommit = Date()
            return facts
        }
        XCTAssertEqual(cache.facts(record, base: "main", now: 0, load: load).changed, 1)
        XCTAssertEqual(cache.facts(record, base: "main", now: 1, load: load).changed, 1)
        XCTAssertEqual(cache.facts(record, base: "main", now: 60, load: load).changed, 2)
        XCTAssertEqual(cache.facts(record, base: "staging", now: 61, load: load).changed, 3)
        var committed = record; committed.head = "two"
        XCTAssertEqual(cache.facts(committed, base: "staging", now: 62, load: load).changed, 4)
        try Data("new work".utf8).write(to: root.appendingPathComponent("file"))
        // Real FSEvents must invalidate a clean cache entry.
        let deadline = Date().addingTimeInterval(5)
        while count == 4 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            _ = cache.facts(committed, base: "staging", now: 63, load: load)
        }
        XCTAssertGreaterThan(count, 4)
        cache.invalidate(paths: ["/unrelated"], uncertain: false)
        let previous = count
        _ = cache.facts(committed, base: "staging", now: 64, load: load)
        XCTAssertEqual(count, previous)
        cache.invalidate(paths: [], uncertain: true)
        _ = cache.facts(committed, base: "staging", now: 65) {
            cache.invalidate(paths: [path + "/file"], uncertain: false)
            return load()
        }
        _ = cache.facts(committed, base: "staging", now: 66, load: load)
        XCTAssertEqual(count, previous + 2, "Never cache results spanning a filesystem change")
    }

    func testIncompleteChecksAndOperationsAreRetriedWithoutAnErrorMessage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("burro-git-incomplete-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = Paths.canonical(root.path), record = WorktreeRecord(path: path)
        let cache = GitFactsCache()
        cache.prepare(watches: [path: [path]], globals: [])
        try await Task.sleep(for: .milliseconds(700))
        for kind in 0..<5 {
            cache.invalidate(paths: [path], uncertain: false)
            var count = 0
            for _ in 0..<2 {
                _ = cache.facts(record, base: "main") {
                    count += 1
                    var facts = GitFacts(); facts.merged = true; facts.unpushed = 0
                    facts.retentionChecked = true; facts.lastCommit = Date()
                    switch kind {
                    case 0: facts.unpushed = nil
                    case 1: facts.merged = nil
                    case 2: facts.retentionChecked = nil
                    case 3: facts.lastCommit = nil
                    default: facts.operationInProgress = true
                    }
                    return facts
                }
            }
            XCTAssertEqual(count, 2)
        }
    }
}
