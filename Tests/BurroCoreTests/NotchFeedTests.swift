// Regressions protect attention priority, explicit worker ownership, and pointer-stable live updates.
import XCTest
@testable import BurroCore
@testable import Burro

final class NotchFeedTests: XCTestCase {
    func testTodayIncludesQuietChatsAndSortsAcrossProvidersAndProjectsByLastActivity() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var olderWaiting = agent("waiting", .waiting); olderWaiting.updatedAt = now.addingTimeInterval(-600)
        var closed = agent("closed", .inactive); closed.updatedAt = now.addingTimeInterval(-60); closed.cwd = "/other"
        var idle = agent("idle", .idle); idle.updatedAt = now.addingTimeInterval(-120); idle.provider = .claude
        var worker = agent("worker", .working, child: true); worker.updatedAt = now
        var yesterday = agent("yesterday"); yesterday.updatedAt = calendar.startOfDay(for: now).addingTimeInterval(-1)
        var future = agent("future"); future.updatedAt = now.addingTimeInterval(60)
        let feed = NotchFeed(sessions: [olderWaiting, closed, idle, worker, yesterday, future, closed],
                             includeIdle: false, scope: .today, now: now, calendar: calendar)
        XCTAssertEqual(feed.groups.map(\.id), ["closed", "idle", "waiting"])
        XCTAssertTrue(feed.groups.allSatisfy { $0.workers.isEmpty })
        XCTAssertEqual(feed.inventory.count, 6, "Browsing must not filter the safety inventory")
        XCTAssertEqual(feed.inventory["closed"]?.state, .inactive)
    }

    func testTodayUsesLocalCalendarBoundaryIncludingDSTAndStableTies() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // The fall-back day lasts 25 hours; today's early chat is over 24 hours old.
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 23, minute: 30))!
        let start = calendar.startOfDay(for: now)
        var first = agent("a", .inactive); first.updatedAt = start
        var second = first; second.id = "b"
        var previous = first; previous.id = "previous"; previous.updatedAt = start.addingTimeInterval(-1)
        XCTAssertGreaterThan(now.timeIntervalSince(start), 24 * 3600)
        let feed = NotchFeed(sessions: [second, previous, first], includeIdle: false, scope: .today, now: now, calendar: calendar)
        XCTAssertEqual(feed.groups.map(\.id), ["a", "b"])
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: start)!
        XCTAssertTrue(NotchFeed(sessions: [first], includeIdle: false, scope: .today, now: tomorrow, calendar: calendar).groups.isEmpty)
    }

    func testTodayDefersReorderingUntilInteractionEndsAndOffersUpdate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var first = agent("first", .idle); first.updatedAt = now.addingTimeInterval(-10)
        var second = agent("second", .idle); second.updatedAt = now.addingTimeInterval(-20)
        var list = NotchListState()
        list.reconcile(NotchFeed(sessions: [first, second], includeIdle: false, scope: .today, now: now), holding: false)
        second.updatedAt = now
        let latest = NotchFeed(sessions: [first, second], includeIdle: false, scope: .today, now: now)
        list.reconcile(latest, holding: true)
        XCTAssertEqual(list.groups.map(\.id), ["first", "second"])
        XCTAssertGreaterThan(list.pendingChanges, 0)
        XCTAssertEqual(list.groups[1].root?.updatedAt, now)
        list.reconcile(latest, holding: false)
        XCTAssertEqual(list.groups.map(\.id), ["second", "first"])
        XCTAssertEqual(list.pendingChanges, 0)
    }

    private func agent(_ id: String, _ state: AgentState = .working, parent: String? = nil, child: Bool = false) -> AgentSession {
        AgentSession(id: id, provider: .codex, title: id, cwd: "/same/repo", state: state,
            updatedAt: Date(timeIntervalSince1970: 100), evidence: "fixture", isSubagent: child, parentSessionID: parent)
    }
    func testNeedsInputThenUnreadThenRunningAndDeduplicatedCounts() {
        var done = agent("done", .idle); done.hasUnreadResult = true
        let sessions = [agent("running"), done, agent("waiting", .waiting), agent("running"), agent("idle", .idle)]
        let feed = NotchFeed(sessions: sessions, includeIdle: false)
        XCTAssertEqual(feed.groups.map(\.id), ["waiting", "done", "running"])
        let snapshot = AgentActivitySnapshot(sessions: sessions, warnings: [], sampledAt: Date())
        XCTAssertEqual(snapshot.workingCount, 1)
        XCTAssertEqual(snapshot.attentionCount, 2)
        XCTAssertEqual(snapshot.visibleSessions(includeIdle: false).map(\.id), ["waiting", "done", "running"])
    }
    func testWorkersUseOnlyExplicitParentAndPreserveSafetyEvidence() {
        let parent = agent("parent", .inactive)
        let child = agent("child", .working, parent: "parent", child: true)
        let guardian = agent("guardian", .unknown, child: true)
        let sessions = [parent, child, guardian, agent("unrelated")]
        let feed = NotchFeed(sessions: sessions, includeIdle: true)
        XCTAssertEqual(feed.groups.first { $0.id == "parent" }?.workers.map(\.id), ["child"])
        XCTAssertEqual(feed.groups.first { $0.root == nil }?.workers.map(\.id), ["guardian"])
        XCTAssertTrue(feed.groups.first { $0.id == "unrelated" }!.workers.isEmpty)
        XCTAssertEqual(sessions[1].state, .working)
        XCTAssertTrue(sessions[2].state.keepsWorktree)
    }
    func testNestedWorkersReachRootAndCyclesRemainInspectable() {
        let root = agent("root", .idle)
        let child = agent("child", .inactive, parent: "root", child: true)
        let grandchild = agent("grandchild", .waiting, parent: "child", child: true)
        let a = agent("a", .unknown, parent: "b", child: true)
        let b = agent("b", .unknown, parent: "a", child: true)
        let feed = NotchFeed(sessions: [root, child, grandchild, a, b], includeIdle: true)
        XCTAssertEqual(feed.groups.first?.root?.id, "root")
        XCTAssertEqual(feed.groups.first?.workers.map(\.id), ["grandchild"])
        XCTAssertEqual(Set(feed.groups.last!.workers.map(\.id)), ["a", "b"])
    }
    func testWorkerCannotJoinDifferentMachineOrProvider() {
        let local = agent("local")
        var remote = agent("remote", parent: "local", child: true)
        remote.remote = RemoteOrigin(hostID: UUID(), hostName: "Other", sampledAt: Date(), stale: false)
        var differentProvider = agent("claude", parent: "local", child: true); differentProvider.provider = .claude
        let feed = NotchFeed(sessions: [local, remote, differentProvider], includeIdle: false)
        XCTAssertTrue(feed.groups.first { $0.id == "local" }!.workers.isEmpty)
        XCTAssertEqual(feed.groups.filter { $0.root == nil }.count, 2)
    }
    func testQuietWorkersAreCollapsedButWaitingWorkersHaveHighestPriority() {
        let waiting = agent("waiting", .waiting, child: true)
        let unknown = agent("unknown", .unknown, child: true)
        let feed = NotchFeed(sessions: [agent("chat"), waiting, unknown], includeIdle: true)
        XCTAssertNil(feed.groups.first?.root)
        XCTAssertEqual(feed.groups.first?.workers.count, 2)
        XCTAssertEqual(feed.groups.first?.priority, 0)
    }
    func testUnverifiedChatsStayProtectedAndInspectableOutsideActiveQueue() {
        let uncertain = agent("uncertain", .unknown)
        let worker = agent("worker", .unknown, child: true)
        let sessions = [agent("active"), uncertain, worker]
        let feed = NotchFeed(sessions: sessions, includeIdle: false)
        XCTAssertEqual(feed.groups.map(\.id), ["active"])
        XCTAssertTrue(feed.inventory["uncertain"]!.state.keepsWorktree)
        XCTAssertTrue(feed.inventory["worker"]!.state.keepsWorktree)
        XCTAssertEqual(NotchFeed(sessions: sessions, includeIdle: true).groups.count, 3)
        let activity = AgentActivitySnapshot(sessions: sessions + [uncertain], warnings: [], sampledAt: Date())
        XCTAssertEqual(activity.unverifiedSessions.map(\.id), ["uncertain", "worker"])
        XCTAssertEqual(activity.attentionCount, 0)
    }
    func testHeldListUpdatesBadgesWithoutMovingOrReplacingTargets() {
        var list = NotchListState()
        list.reconcile(NotchFeed(sessions: [agent("a"), agent("b")], includeIdle: false), holding: false)
        let latest = NotchFeed(sessions: [agent("b", .waiting), agent("new", .working)], includeIdle: false)
        list.reconcile(latest, holding: true)
        XCTAssertEqual(list.groups.map(\.id), ["a", "b"])
        XCTAssertEqual(list.groups[1].root?.state, .waiting)
        XCTAssertEqual(list.groups[0].unavailableIDs, ["a"])
        XCTAssertEqual(list.pendingChanges, 2)
        list.reconcile(latest, holding: false)
        XCTAssertEqual(list.groups.map(\.id), ["b", "new"])
        XCTAssertEqual(list.pendingChanges, 0)
    }
    func testReadCompletionRemainsIdleUntilInteractionEnds() {
        var done = agent("done", .idle); done.hasUnreadResult = true
        var list = NotchListState()
        list.reconcile(NotchFeed(sessions: [done], includeIdle: false), holding: false)
        done.hasUnreadResult = false
        let latest = NotchFeed(sessions: [done], includeIdle: false)
        list.reconcile(latest, holding: true)
        XCTAssertFalse(list.groups[0].root!.isDone)
        XCTAssertTrue(list.groups[0].unavailableIDs.isEmpty)
        XCTAssertEqual(list.pendingChanges, 1)
        list.reconcile(latest, holding: false)
        XCTAssertTrue(list.groups.isEmpty)
    }
    func testHeldExpandedWorkerMembershipRemainsStable() {
        let root = agent("root"), worker = agent("one", parent: "root", child: true)
        var list = NotchListState()
        list.reconcile(NotchFeed(sessions: [root, worker], includeIdle: false), holding: false)
        list.reconcile(NotchFeed(sessions: [root, agent("two", parent: "root", child: true)], includeIdle: false), holding: true)
        XCTAssertEqual(list.groups[0].workers.map(\.id), ["one"])
        XCTAssertTrue(list.groups[0].unavailableIDs.contains("one"))
        XCTAssertEqual(list.pendingChanges, 2)
    }
    func testParentMetadataIsValidatedAndRemoteParentUsesSameNamespace() throws {
        let id = UUID().uuidString
        let source = "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"\(id)\"}}}"
        XCTAssertEqual(AgentParsing.codexParentID(source: source), "codex:" + id)
        XCTAssertNil(AgentParsing.codexParentID(source: source.replacingOccurrences(of: id, with: "../bad")))
        XCTAssertNil(AgentParsing.codexParentID(source: #"{"subagent":{"other":"guardian"}}"#))
        let host = RemoteHost(name: "Laptop", destination: "laptop")
        let worker = agent("codex:child", parent: "codex:" + id, child: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        let record = try JSONSerialization.jsonObject(with: encoder.encode(worker))
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": [record], "warnings": []])
        let decoded = try RemoteAgentMonitor.decode(data, host: host, receivedAt: Date()).sessions[0]
        XCTAssertEqual(decoded.parentSessionID, "remote:\(host.id.uuidString):codex:" + id)
    }
    @MainActor func testHistoryCoverageAndConnectionNoticesStayHostScoped() {
        let suite = "burro-notice-\(UUID().uuidString)", host = RemoteHost(name: "Other Mac", destination: "test")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults)
        store.remoteHosts = [host]
        store.remoteSnapshots[host.id] = RemoteHostSnapshot(host: host,
            warnings: ["Codex history exceeds the inspection limit; some sessions may be absent."], sampledAt: Date(), state: .online)
        XCTAssertEqual(store.notchNotices.first?.summary, "Other Mac: history limited")
        XCTAssertFalse(store.notchNotices.first!.connectionIssue)
        store.remoteSnapshots[host.id] = .mergeFailure(host: host, error: "Timed out", previous: store.remoteSnapshots[host.id], now: Date())
        XCTAssertEqual(store.notchNotices.first?.summary, "Other Mac: status unavailable")
        XCTAssertTrue(store.notchNotices.first!.connectionIssue)
    }
}
