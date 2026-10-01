// Synthetic queues prove immediate feedback, partial failure recovery, and scan-race isolation.
import XCTest
@testable import Burro
@testable import BurroCore

final class CleanupBatchTests: XCTestCase {
    actor Gate {
        private var open = false
        private var entered = false
        private var waits: [CheckedContinuation<Void, Never>] = []
        private var observers: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            entered = true
            for observer in observers { observer.resume() }; observers = []
            if !open { await withCheckedContinuation { waits.append($0) } }
        }
        func started() async {
            if !entered { await withCheckedContinuation { observers.append($0) } }
        }
        func release() { open = true; for waiter in waits { waiter.resume() }; waits = [] }
    }
    actor Calls {
        var ids: [String] = []
        func add(_ id: String) { ids.append(id) }
        func values() -> [String] { ids }
    }
    func tree(_ name: String) -> Worktree {
        var facts = GitFacts(); facts.base = "origin/main"; facts.retentionChecked = true
        facts.retainedBranch = "refs/heads/feature-" + name
        return Worktree(path: "/fixture/" + name, repository: "repo", repositoryPath: "/fixture/repo",
            branch: "feature-" + name, head: String(repeating: "a", count: 40), isPrimary: false,
            isLocked: false, isMissing: false, isPrunable: false, facts: facts, agents: [], processes: [],
            protectedByUser: false, assessment: Assessment(level: .keep, reasons: []))
    }
    func snapshot(_ trees: [Worktree]) -> ScanSnapshot {
        .init(worktrees: trees, agents: [], warnings: [], scannedAt: Date(), duration: 0)
    }
    func defaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "burro-bulk-test-" + UUID().uuidString)!
        defaults.set(false, forKey: "usageEnabled")
        defaults.set(false, forKey: "discover")
        defaults.set(false, forKey: "notchEnabled")
        return defaults
    }
    @MainActor func testOptimisticBatchRunsOnceAndRestoresFailedRows() async {
        let first = tree("first"), second = tree("second"), gate = Gate(), calls = Calls()
        let batch = CleanupBatchStore { tree, _ in
            await calls.add(tree.id)
            if tree.id == first.id { await gate.wait(); throw CleanupError.blocked("New local changes") }
            return URL(fileURLWithPath: "/fixture/Trash/" + tree.branch)
        }
        XCTAssertTrue(batch.begin([first, first, second]))
        XCTAssertEqual(batch.hiddenPaths, [first.id, second.id])
        XCTAssertEqual(batch.items.count, 2)
        XCTAssertFalse(batch.begin([second]))
        let run = Task { await batch.run(configuration: .init()) }
        await gate.started()
        XCTAssertEqual(batch.current?.id, first.id)
        let callsSoFar = await calls.values(); XCTAssertEqual(callsSoFar, [first.id])
        await batch.run(configuration: .init()) // A duplicate invocation cannot double-remove.
        await gate.release(); await run.value
        XCTAssertEqual(batch.failure(for: first.id), "New local changes")
        XCTAssertFalse(batch.hiddenPaths.contains(first.id))
        XCTAssertTrue(batch.hiddenPaths.contains(second.id)) // No stale snapshot resurrection.
        XCTAssertEqual(batch.failedCount, 1); XCTAssertEqual(batch.movedCount, 1)
        let allCalls = await calls.values(); XCTAssertEqual(allCalls, [first.id, second.id])
        batch.settle(); XCTAssertTrue(batch.hiddenPaths.isEmpty)
        batch.dismiss(); XCTAssertTrue(batch.items.isEmpty)
    }
    @MainActor func testStopRemainingFinishesCurrentAndRestoresQueuedRows() async {
        let first = tree("first"), second = tree("second"), gate = Gate(), calls = Calls()
        let batch = CleanupBatchStore { tree, _ in
            await calls.add(tree.id); await gate.wait()
            return URL(fileURLWithPath: "/fixture/Trash/" + tree.branch)
        }
        batch.begin([first, second])
        let run = Task { await batch.run(configuration: .init()) }
        await gate.started(); batch.stopRemaining()
        XCTAssertEqual(batch.hiddenPaths, [first.id]); XCTAssertEqual(batch.skippedCount, 1)
        batch.dismiss(); XCTAssertEqual(batch.items.count, 2)
        await gate.release(); await run.value
        XCTAssertEqual(batch.movedCount, 1)
        let invoked = await calls.values(); XCTAssertEqual(invoked, [first.id])
    }
    @MainActor func testSelectionAndConfirmationSkipBlockedOrChangedTrees() {
        let ready = tree("ready"); var dirty = tree("dirty"); dirty.facts.changed = 1
        let store = AppStore(defaults: defaults()); store.snapshot = snapshot([ready, dirty])
        store.filter = .cleanup
        store.selectReadyWorktrees(); XCTAssertEqual(store.worktreeSelection, [ready.id])
        store.worktreeSelection = [ready.id, dirty.id]
        XCTAssertEqual(store.selectedWorktrees.count, 2); XCTAssertNil(store.selected)
        XCTAssertEqual(store.selectedReadyCount, 1)
        XCTAssertNil(store.cleanupBlocker(ready)); XCTAssertNotNil(store.cleanupBlocker(dirty))
        store.search = "dirty"; store.reconcileSelection()
        XCTAssertEqual(store.worktreeSelection, [dirty.id])
        store.selectReadyWorktrees(); XCTAssertTrue(store.worktreeSelection.isEmpty)
        store.snapshot.worktrees[0].head = String(repeating: "b", count: 40)
        XCTAssertNotNil(store.cleanupBlocker(ready))
    }
    @MainActor func testBackgroundScanCannotResurrectOptimisticallyRemovedWorktree() async {
        let original = tree("ready"), stale = snapshot([tree("ready")]), oldScan = Gate(), freshScan = Gate(), removing = Gate()
        let scans = Calls(), removals = Calls()
        let batch = CleanupBatchStore { tree, _ in
            await removals.add(tree.id); await removing.wait()
            return URL(fileURLWithPath: "/fixture/Trash/ready")
        }
        let store = AppStore(defaults: defaults(), cleanupBatch: batch) { _ in
            await scans.add("scan")
            if await scans.values().count == 1 { await oldScan.wait(); return stale }
            await freshScan.wait()
            return .empty
        }
        store.snapshot = stale; store.selection = original.id
        let refreshing = Task { await store.refresh() }
        await oldScan.started()
        store.reviewCleanup([original]); let request = store.cleanupTarget!
        let cleanup = store.confirmCleanup(request)!
        XCTAssertNil(store.cleanupTarget); XCTAssertTrue(store.visibleWorktrees.isEmpty)
        XCTAssertTrue(store.worktreeSelection.isEmpty); XCTAssertTrue(store.cleaningWorktree)
        XCTAssertNil(store.confirmCleanup(request)) // A repeated action cannot submit twice.
        await removing.started(); await oldScan.release(); await refreshing.value
        XCTAssertTrue(store.visibleWorktrees.isEmpty); XCTAssertFalse(store.scanning)
        await removing.release(); await freshScan.started()
        XCTAssertTrue(store.visibleWorktrees.isEmpty)
        await freshScan.release()
        await cleanup.value
        XCTAssertFalse(store.cleaningWorktree); XCTAssertTrue(store.snapshot.worktrees.isEmpty)
        XCTAssertTrue(batch.hiddenPaths.isEmpty)
        let invoked = await removals.values(); XCTAssertEqual(invoked, [original.id])
    }
}
