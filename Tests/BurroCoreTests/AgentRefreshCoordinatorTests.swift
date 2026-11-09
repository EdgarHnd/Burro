import XCTest
@testable import BurroCore

final class AgentRefreshCoordinatorTests: XCTestCase {
    func testProviderEventsIgnoreUnrelatedCodexOutputButKeepChangesAndOverflow() {
        for path in ["state_5.sqlite-wal", ".codex-global-state.json", ".codex-global-state.json.tmp", "thread-writer-locks/a.lock", "sessions/2026/chat.jsonl", "archived_sessions/chat.jsonl"] {
            XCTAssertTrue(AgentFileWatcher.affectsAgents(["/home/.codex/" + path], uncertain: false, home: "/home"))
        }
        XCTAssertFalse(AgentFileWatcher.affectsAgents(["/home/.codex/log/ui.log", "/home/.codex/tmp/build.out"], uncertain: false, home: "/home"))
        XCTAssertTrue(AgentFileWatcher.affectsAgents(["/home/.codex/log/ui.log"], uncertain: true, home: "/home"))
        XCTAssertTrue(AgentFileWatcher.affectsAgents(["/home/.codex"], uncertain: false, home: "/home"))
        XCTAssertTrue(AgentFileWatcher.affectsAgents(["/home/.claude/sessions/a.json"], uncertain: false, home: "/home"))
    }
    @MainActor func testEventBurstDuringRefreshCoalescesAndStopPreventsRestart() async throws {
        var count = 0, concurrent = 0, maximum = 0
        let firstStarted = expectation(description: "first refresh started")
        let secondFinished = expectation(description: "one follow-up finished")
        let coordinator = AgentRefreshCoordinator(minimumInterval: 0.02) {
            count += 1; concurrent += 1; maximum = max(maximum, concurrent)
            if count == 1 { firstStarted.fulfill() }
            try? await Task.sleep(for: .milliseconds(50))
            concurrent -= 1
            if count == 2 { secondFinished.fulfill() }
            return 60
        }
        coordinator.start()
        await fulfillment(of: [firstStarted], timeout: 3)
        for _ in 0..<100 { coordinator.changed() }
        await fulfillment(of: [secondFinished], timeout: 3)
        XCTAssertEqual(count, 2); XCTAssertEqual(maximum, 1)
        coordinator.stop()
        coordinator.changed()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(count, 2)
    }
    @MainActor func testIdleFallbackKeepsUncertainOrActiveSessionsFrequent() {
        for state in [AgentState.working, .waiting, .unknown] {
            XCTAssertEqual(AgentRefreshCoordinator.interval(states: [state], warnings: false, watching: true), 3)
        }
        XCTAssertEqual(AgentRefreshCoordinator.interval(states: [.inactive, .idle], warnings: false, watching: true), 15)
        XCTAssertEqual(AgentRefreshCoordinator.interval(states: [], warnings: true, watching: true), 3)
        XCTAssertEqual(AgentRefreshCoordinator.interval(states: [], warnings: false, watching: false), 3)
    }
    func testRecursiveFileNotification() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("burro-watch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let changed = expectation(description: "nested file event")
        changed.assertForOverFulfill = false
        let watcher = AgentFileWatcher(paths: [root.path]) { changed.fulfill() }
        defer { watcher.stop() }
        XCTAssertTrue(watcher.isRunning)
        let nested = root.appendingPathComponent("new-session")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("changed".utf8).write(to: nested.appendingPathComponent("state.json"))
        await fulfillment(of: [changed], timeout: 5)
    }
}
