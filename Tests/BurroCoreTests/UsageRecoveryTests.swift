// Exercise wake/unlock recovery without reading real credentials, accounts, or history.
import AppKit
import XCTest
@testable import Burro
@testable import BurroCore

private actor RecoveryFixture {
    var calls: [(UsageProvider, String?, Bool)] = []
    let firstIssue: UsageIssue
    let holdFirst: Bool
    private var release: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    init(_ issue: UsageIssue = .keychainLocked, holdFirst: Bool = false) {
        firstIssue = issue; self.holdFirst = holdFirst
    }
    func read(_ provider: UsageProvider, _ profile: String?, _ prompt: Bool) async -> ProviderUsage {
        calls.append((provider, profile, prompt))
        let first = calls.filter { $0.0 == provider }.count == 1
        if first && holdFirst {
            await withCheckedContinuation { continuation in
                release = continuation; startWaiter?.resume(); startWaiter = nil
            }
        }
        if first { return .failure(provider, firstIssue) }
        return ProviderUsage(id: provider, updatedAt: Date(), windows: [])
    }
    func waitUntilStarted() async {
        if release != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func finishFirst() { release?.resume(); release = nil }
}

final class UsageRecoveryTests: XCTestCase {
    @MainActor private func store(_ fixture: RecoveryFixture, name: String) throws -> UsageStore {
        let defaults = UserDefaults(suiteName: name)!
        var prefs = UsagePreferences(); prefs.providers = [.claude]; prefs.interval = 900
        prefs.history = false; prefs.profiles = [.claude: "/fixture/profile"]
        defaults.set(try JSONEncoder().encode(prefs), forKey: "usagePreferences")
        return UsageStore(defaults: defaults, readUsage: { await fixture.read($0, $1, $2) })
    }
    @MainActor func testWakeRecoversExistingProfileWithoutPromptOrReconnect() async throws {
        let name = "burro-recovery-\(UUID().uuidString)", fixture = RecoveryFixture()
        let store = try store(fixture, name: name)
        defer { store.stop(); UserDefaults(suiteName: name)!.removePersistentDomain(forName: name) }
        await store.refresh()
        XCTAssertEqual(store.snapshot.providers.first?.issue, .keychainLocked)
        await store.recoverAfterResume()
        XCTAssertNil(store.snapshot.providers.first?.issue)
        let calls = await fixture.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.1 == "/fixture/profile" && !$0.2 })
        await store.recoverAfterResume()
        let count = await fixture.calls.count
        XCTAssertEqual(count, 2, "Wake/unlock bursts must coalesce")
    }
    @MainActor func testWakeDuringFetchDoesNotLoseTheRetry() async throws {
        let name = "burro-recovery-\(UUID().uuidString)", fixture = RecoveryFixture(.permissionRequired, holdFirst: true)
        let store = try store(fixture, name: name)
        defer { store.stop(); UserDefaults(suiteName: name)!.removePersistentDomain(forName: name) }
        let refresh = Task { await store.refresh() }
        await fixture.waitUntilStarted()
        await store.recoverAfterResume()
        await fixture.finishFirst()
        await refresh.value
        let calls = await fixture.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { !$0.2 })
        XCTAssertNil(store.snapshot.providers.first?.issue)
    }
    @MainActor func testRecoveryRespectsRateLimitAndDisabledUsage() async throws {
        let name = "burro-recovery-\(UUID().uuidString)", fixture = RecoveryFixture(.rateLimited)
        let store = try store(fixture, name: name)
        defer { store.stop(); UserDefaults(suiteName: name)!.removePersistentDomain(forName: name) }
        await store.refresh(); await store.recoverAfterResume()
        XCTAssertEqual(store.snapshot.providers.first?.issue, .rateLimited)
        store.enabled = false
        await store.recoverAfterResume()
        let count = await fixture.calls.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.snapshot.availability, .disabled)
    }
    @MainActor func testWakeNotificationTriggersSilentRecovery() async throws {
        let name = "burro-recovery-\(UUID().uuidString)", fixture = RecoveryFixture(.permissionRequired)
        let store = try store(fixture, name: name)
        defer { store.stop(); UserDefaults(suiteName: name)!.removePersistentDomain(forName: name) }
        await store.refresh(); store.start()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        for _ in 0..<30 {
            if await fixture.calls.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let calls = await fixture.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { !$0.2 })
    }
}
