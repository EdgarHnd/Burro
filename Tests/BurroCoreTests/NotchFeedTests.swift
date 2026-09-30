// Regressions protect attention priority, explicit worker ownership, and pointer-stable live updates.
import XCTest
@testable import BurroCore
@testable import Burro

final class NotchFeedTests: XCTestCase {
    private func agent(_ id: String, _ state: AgentState = .working, parent: String? = nil, child: Bool = false) -> AgentSession {
        AgentSession(id: id, provider: .codex, title: id, cwd: "/same/repo", state: state,
            updatedAt: Date(timeIntervalSince1970: 100), evidence: "fixture", isSubagent: child, parentSessionID: parent)
    }
    func testFinishedChatDoesNotInheritSharedCheckoutDirt() {
        var first = agent("finished", .idle), second = agent("other", .working)
        first.turnCompleted = true
        first.deliveryStatus = .uncommitted
        first.edits = ChatEdits(hasEdits: true, added: 1, removed: 0, exact: true)
        first.edits?.commit = ChatCommit(sha: "abc1234", onRemote: true)
        second.deliveryStatus = .uncommitted
        XCTAssertEqual(first.statusLabel, "Finished")
        XCTAssertEqual(first.chatDeliveryLabel, "Reported commit on remote")
        let workspaces = NotchWorkspace.grouped(NotchFeed(sessions: [first, second], includeIdle: false).groups) { $0.cwd }
        XCTAssertEqual(workspaces[0].status, .running)
        second.state = .idle; second.turnCompleted = true
        let completed = NotchWorkspace.grouped(NotchFeed(sessions: [first, second], includeIdle: false).groups) { $0.cwd }
        XCTAssertEqual(completed[0].status, .uncommitted)
        XCTAssertEqual(second.chatDeliveryLabel, "Delivery unverified")
    }
    func testCodeOnlyFeedHidesConversationsWithoutChangingSafetyInventory() {
        var edited = agent("edited")
        edited.edits = ChatEdits(hasEdits: true, added: 12, removed: 3, exact: true)
        var conversation = agent("conversation")
        conversation.edits = ChatEdits(hasEdits: false, added: 0, removed: 0, exact: true)
        let feed = NotchFeed(sessions: [edited, conversation], includeIdle: true, codeOnly: true)
        XCTAssertEqual(feed.groups.map(\.id), ["edited"])
        XCTAssertEqual(feed.inventory.count, 2)
    }
    func testCodeOnlyFeedKeepsActiveChatsWithIncompleteRemoteEdits() {
        var sessions: [AgentSession] = []
        for (id, state) in [("running", AgentState.working), ("waiting", .waiting), ("scheduled", .scheduled), ("idle", .idle), ("inactive", .inactive)] {
            var session = agent(id, state)
            session.remote = RemoteOrigin(hostID: UUID(), hostName: "Other Mac", sampledAt: Date(), stale: false)
            session.edits = ChatEdits(hasEdits: false, added: 0, removed: 0, exact: false)
            sessions.append(session)
        }
        sessions.append(agent("missing-log"))
        let feed = NotchFeed(sessions: sessions, includeIdle: true, codeOnly: true)
        XCTAssertEqual(Set(feed.groups.map(\.id)), Set(["running", "waiting", "scheduled", "missing-log"]))
        XCTAssertEqual(feed.inventory.count, 6)
        XCTAssertEqual(WorkspaceSummary(NotchWorkspace.grouped(feed.groups) { $0.cwd }).workingCount, 2)
    }
    func testHoverPreviewCapsAtFiveChatsAndReportsRemainder() {
        for count in [1, 5, 12] {
            let sessions = (0..<count).map { agent("chat-\($0)") }
            let workspace = NotchWorkspace.grouped(NotchFeed(sessions: sessions, includeIdle: false).groups) { $0.cwd }[0]
            XCTAssertEqual(workspace.previewGroups.count, min(5, count))
            XCTAssertEqual(workspace.previewOverflow, max(0, count - 5))
            XCTAssertEqual(workspace.groups.count, count)
        }
    }
    func testProjectSectionsKeepDistinctRepositoriesAndHostsSeparate() {
        var first = agent("first"), linked = agent("linked"), other = agent("other"), remote = agent("remote")
        first.cwd = "/repo/main"; linked.cwd = "/worktrees/feature"; other.cwd = "/other/main"; remote.cwd = first.cwd
        remote.remote = RemoteOrigin(hostID: UUID(), hostName: "Remote", sampledAt: Date(), stale: false)
        let workspaces = NotchWorkspace.grouped(NotchFeed(sessions: [first, linked, other, remote], includeIdle: false).groups) { $0.cwd }
        let projects = NotchProject.grouped(workspaces) { $0.id == "other" ? "/other/main" : "/repo/main" }
        XCTAssertEqual(projects.count, 3)
        XCTAssertEqual(projects.first { $0.path == "/repo/main" && $0.machine == "This Mac" }?.workspaces.count, 2)
        XCTAssertEqual(projects.first { $0.machine == "Remote" }?.workspaces.count, 1)
    }
    func testProjectsRankRunningWorktreesThenChatsThenRecency() {
        func session(_ id: String, _ project: String, _ checkout: String, _ state: AgentState, _ time: Double) -> AgentSession {
            var value = agent(id, state)
            value.cwd = project + "/" + checkout
            value.updatedAt = Date(timeIntervalSince1970: time)
            value.turnCompleted = state == .idle
            return value
        }
        let sessions = [
            session("old", "old", "main", .idle, 1),
            session("recent", "recent", "main", .idle, 1000),
            session("a1", "many-trees", "one", .working, 2),
            session("a2", "many-trees", "two", .working, 3),
            session("b1", "many-chats", "one", .working, 10),
            session("b2", "many-chats", "one", .working, 11),
            session("b3", "many-chats", "one", .working, 12),
            session("c1", "single", "one", .working, 500),
            session("a-old", "many-trees", "old", .idle, 900)
        ]
        let workspaces = NotchWorkspace.grouped(NotchFeed(sessions: sessions, includeIdle: true).groups) { $0.cwd }
        let projects = NotchProject.grouped(workspaces) { $0.cwd.components(separatedBy: "/")[0] }
        XCTAssertEqual(projects.map(\.path), ["many-trees", "many-chats", "single", "recent", "old"])
        XCTAssertEqual(projects[0].workspaces.map { $0.sessions[0].id }, ["a2", "a1", "a-old"])
        var stale = agent("stale")
        stale.remote = RemoteOrigin(hostID: UUID(), hostName: "Offline", sampledAt: Date(), stale: true)
        let staleTree = NotchWorkspace.grouped(NotchFeed(sessions: [stale], includeIdle: true).groups) { $0.cwd }[0]
        XCTAssertEqual(staleTree.runningChatCount, 0)
    }
    func testHeaderCountsWorkspacesOnceWithLiveStatePriority() {
        var first = agent("one", .idle), second = agent("two", .idle), running = agent("running", .working)
        for index in 0..<2 {
            if index == 0 { first.turnCompleted = true; first.deliveryStatus = .needsPush }
            else { second.turnCompleted = true; second.deliveryStatus = .needsPush }
        }
        func summary(_ sessions: [AgentSession]) -> WorkspaceSummary {
            WorkspaceSummary(NotchWorkspace.grouped(NotchFeed(sessions: sessions, includeIdle: false).groups) { $0.cwd })
        }
        XCTAssertEqual(summary([first, second]).count(.needsPush), 1)
        XCTAssertEqual(summary([first, second, running]).count(.needsPush), 0)
        XCTAssertEqual(summary([first, second, running]).workingCount, 1)
        running.id = "running-two"
        XCTAssertEqual(summary([agent("running"), running]).workingCount, 1)
        first.deliveryStatus = .synced; first.hasUnreadResult = true
        second.deliveryStatus = .synced; second.hasUnreadResult = true
        XCTAssertEqual(summary([first, second]).doneCount, 1)
        second.cwd = "/different-checkout"
        XCTAssertEqual(summary([first, second]).doneCount, 2)
        first.remote = RemoteOrigin(hostID: UUID(), hostName: "offline", sampledAt: Date(), stale: true)
        XCTAssertEqual(summary([first, second]).doneCount, 1)
    }
    func testWorkspacesGroupByCheckoutAndMachineNotBranchOrTitle() {
        var first = agent("one"), second = agent("two"), other = agent("other"), remote = agent("remote")
        first.cwd = "/repo/a"; second.cwd = "/repo/a"; other.cwd = "/repo/b"; remote.cwd = "/repo/a"
        remote.remote = RemoteOrigin(hostID: UUID(), hostName: "Other Mac", sampledAt: Date(), stale: false)
        let feed = NotchFeed(sessions: [first, second, other, remote], includeIdle: false)
        let workspaces = NotchWorkspace.grouped(feed.groups) { $0.cwd }
        XCTAssertEqual(workspaces.count, 3)
        XCTAssertEqual(workspaces.first { $0.sessions.contains { $0.id == "one" } }?.sessions.count, 2)
        XCTAssertEqual(workspaces.first { $0.sessions.contains { $0.id == "remote" } }?.sessions.count, 1)
    }
    func testReadCompletedWorkRemainsVisibleUntilMerged() {
        var session = agent("read-completion", .idle)
        session.turnCompleted = true
        session.hasUnreadResult = false
        session.deliveryStatus = .needsMerge
        XCTAssertFalse(session.isDone)
        XCTAssertTrue(session.showsCompletion)
        XCTAssertEqual(session.statusLabel, "Finished")
        XCTAssertEqual(NotchFeed(sessions: [session], includeIdle: false).groups.count, 1)
        let activity = AgentActivitySnapshot(sessions: [session], warnings: [], sampledAt: Date())
        XCTAssertEqual(activity.needsMergeCount, 1)
        XCTAssertEqual(activity.visibleSessions(includeIdle: false).count, 1)
        session.state = .inactive
        XCTAssertFalse(session.showsCompletion)
        session.state = .working
        XCTAssertFalse(session.showsCompletion)
        session.state = .idle
        session.deliveryStatus = .merged
        XCTAssertTrue(session.showsCompletion)
        session.hasUnreadResult = true
        XCTAssertEqual(session.statusLabel, "Finished")
        session.isSubagent = true
        XCTAssertFalse(session.showsCompletion)
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
        let feed = NotchFeed(sessions: sessions, includeIdle: false)
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
        let feed = NotchFeed(sessions: [root, child, grandchild, a, b], includeIdle: false)
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
        let feed = NotchFeed(sessions: [agent("chat"), waiting, unknown], includeIdle: false)
        XCTAssertNil(feed.groups.first?.root)
        XCTAssertEqual(feed.groups.first?.workers.count, 2)
        XCTAssertEqual(feed.groups.first?.priority, 0)
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
