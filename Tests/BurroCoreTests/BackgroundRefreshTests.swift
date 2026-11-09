import XCTest
@testable import Burro
@testable import BurroCore

final class BackgroundRefreshTests: XCTestCase {
    func testVisibleAndBackgroundScanDeadlines() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(WorktreeRefreshPolicy.isDue(lastScan: nil, now: now, visible: false))
        XCTAssertTrue(WorktreeRefreshPolicy.isDue(lastScan: nil, now: now, visible: true))
        for (age, visible, due) in [(29.0, true, false), (30, true, true), (299, false, false), (300, false, false), (3600, false, false), (-1, false, false), (-1, true, true)] {
            XCTAssertEqual(WorktreeRefreshPolicy.isDue(lastScan: now.addingTimeInterval(-age), now: now, visible: visible), due)
        }
    }
    actor Calls {
        private var count = 0
        private var incremental: [Bool] = []
        func scan(_ config: ScanConfiguration) -> ScanSnapshot { count += 1; incremental.append(config.incremental); return .empty }
        func value() -> Int { count }
        func modes() -> [Bool] { incremental }
    }
    @MainActor func testVisibleDashboardDoesNotRepeatRepositoryScans() async {
        let suite = "burro-no-poll-test-" + UUID().uuidString, calls = Calls()
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "usageEnabled")
        let first = expectation(description: "opening refresh")
        let repeated = expectation(description: "no timed repository refresh")
        repeated.isInverted = true
        let store = AppStore(defaults: defaults, scan: { config in
            let result = await calls.scan(config)
            if await calls.value() == 1 { first.fulfill() } else { repeated.fulfill() }
            return result
        })
        defer { store.stop(); defaults.removePersistentDomain(forName: suite) }
        let window = NSObject()
        store.dashboardVisibilityChanged(ObjectIdentifier(window), true)
        store.startWorktreeRefresh()
        await fulfillment(of: [first], timeout: 3)
        store.startWorktreeRefresh() // Starting an already running store is idempotent.
        // Cross the former 30-second polling deadline with stale evidence and
        // an exposed dashboard: neither condition may start another scan.
        await fulfillment(of: [repeated], timeout: 32)
        let count = await calls.value()
        XCTAssertEqual(count, 1)
    }
    @MainActor func testDashboardReopenAndManualRefresh() async {
        let suite = "burro-energy-test-" + UUID().uuidString, calls = Calls()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "usageEnabled")
        let store = AppStore(defaults: defaults, scan: { config in await calls.scan(config) })
        let now = Date()
        store.didScan = true; store.snapshot.scannedAt = now.addingTimeInterval(-60)
        await store.refreshWorktreesIfDue(now: now)
        var count = await calls.value(); XCTAssertEqual(count, 0)
        store.snapshot.scannedAt = now.addingTimeInterval(-3600)
        await store.refreshWorktreesIfDue(now: now)
        count = await calls.value(); XCTAssertEqual(count, 0, "Hidden dashboards must not start periodic full Git scans")
        let window = NSObject(), second = NSObject()
        store.dashboardVisibilityChanged(ObjectIdentifier(window), true)
        store.dashboardVisibilityChanged(ObjectIdentifier(second), true)
        store.dashboardVisibilityChanged(ObjectIdentifier(window), false)
        await store.refreshWorktreesIfDue(now: now)
        count = await calls.value(); XCTAssertEqual(count, 1)
        store.snapshot.scannedAt = now.addingTimeInterval(-60)
        store.page = .usage
        await store.refreshWorktreesIfDue(now: now)
        count = await calls.value(); XCTAssertEqual(count, 1)
        store.dashboardVisibilityChanged(ObjectIdentifier(second), false)
        store.page = .worktrees
        await store.refreshWorktreesIfDue(now: now)
        count = await calls.value(); XCTAssertEqual(count, 1)
        // An explicit refresh must not inherit the background delay.
        await store.refresh()
        count = await calls.value(); XCTAssertEqual(count, 2)
        await store.refresh(afterCleanup: true, incremental: true)
        let modes = await calls.modes()
        XCTAssertEqual(modes, [true, false, false], "Manual and post-cleanup refresh cannot reuse automatic facts")
    }
}
