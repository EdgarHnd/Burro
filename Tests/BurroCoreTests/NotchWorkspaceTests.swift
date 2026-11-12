// Grouping retains all active agents and only real unread completions.
import XCTest
@testable import BurroCore
@testable import Burro

final class NotchWorkspaceTests: XCTestCase {
    func session(_ id: String, state: AgentState, path: String = "/repo/tree") -> AgentSession {
        .init(id: id, provider: .codex, title: id, cwd: path, state: state, updatedAt: Date(), evidence: "Fixture")
    }
    func testGroupsByMachineAndPathNotBranchOrFolderName() {
        let a = session("a", state: .working)
        var b = session("b", state: .waiting); b.provider = .claude
        var remote = session("remote", state: .scheduled)
        remote.remote = RemoteOrigin(hostID: UUID(), hostName: "Other Mac", sampledAt: Date(), stale: false)
        let other = session("other", state: .working, path: "/different/tree")
        let feed = NotchFeed(sessions: [a,b,remote,other], includeIdle: false)
        let groups = NotchWorkspace.grouped(feed.groups, path: { $0.cwd })
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.flatMap(\.sessions).count, 4)
        XCTAssertEqual(Set(groups.first { $0.groups.count == 2 }!.sessions.map(\.id)), ["a", "b"])
    }
    func testUnreadCompletionAndEditFreeActivityRemainUnchanged() {
        var read = session("read", state: .idle); read.turnCompleted = true; read.hasUnreadResult = false
        var unread = session("unread", state: .idle); unread.turnCompleted = true; unread.hasUnreadResult = true
        let feed = NotchFeed(sessions: [read, unread, session("running", state: .working), session("input", state: .waiting), session("scheduled", state: .scheduled)], includeIdle: false)
        let groups = NotchWorkspace.grouped(feed.groups, path: { $0.cwd })
        XCTAssertEqual(Set(groups.flatMap(\.sessions).map(\.id)), ["unread", "running", "input", "scheduled"])
    }
    func testUnattachedWorkersAreNotMisrepresentedAsOneCheckout() {
        var a = session("a", state: .working); a.isSubagent = true
        var b = session("b", state: .working, path: "/other"); b.isSubagent = true
        let workspaces = NotchWorkspace.grouped(NotchFeed(sessions: [a,b], includeIdle: false).groups, path: { $0.cwd })
        XCTAssertEqual(workspaces.count, 1); XCTAssertEqual(workspaces[0].path, "")
        XCTAssertEqual(workspaces[0].sessions.count, 2)
    }
    private func chat(_ id: String, _ state: AgentState, _ time: TimeInterval, _ path: String) -> AgentSession {
        var value = session(id, state: state, path: path)
        value.updatedAt = Date(timeIntervalSince1970: time)
        return value
    }
    func testRunningProjectsAndChatsComeFirstThenLatestActivity() {
        var done = chat("done", .idle, 900, "/quiet"); done.hasUnreadResult = true
        let sessions = [done, chat("waiting", .waiting, 800, "/waiting"),
                        chat("older-running", .working, 100, "/older"),
                        chat("newer-running", .working, 200, "/newer"),
                        chat("recent-in-older-project", .waiting, 500, "/older"),
                        chat("second-running", .working, 300, "/older")]
        let feed = NotchFeed(sessions: sessions, includeIdle: false)
        let workspaces = NotchWorkspace.prioritized(feed.groups, path: { $0.cwd })
        XCTAssertEqual(workspaces.map(\.path), ["/older", "/newer", "/quiet", "/waiting"])
        XCTAssertEqual(workspaces[0].groups.map(\.id), ["second-running", "older-running", "recent-in-older-project"])
        XCTAssertEqual(Set(workspaces.flatMap(\.sessions).map(\.id)), Set(sessions.map(\.id)))
        XCTAssertTrue(workspaces[2].sessions[0].hasUnreadResult == true)
    }
    func testInteractionsReorderProjectsAndChatsWithoutOverridingNewerProviderActivity() {
        let sessions = [chat("running", .working, 100, "/running"),
                        chat("recent", .waiting, 300, "/recent"),
                        chat("opened", .waiting, 100, "/opened"),
                        chat("older", .waiting, 200, "/opened")]
        let feed = NotchFeed(sessions: sessions, includeIdle: false)
        let interactions = ["opened": Date(timeIntervalSince1970: 400), "recent": Date(timeIntervalSince1970: 50)]
        let workspaces = NotchWorkspace.prioritized(feed.groups, interactions: interactions, path: { $0.cwd })
        XCTAssertEqual(workspaces.map(\.path), ["/running", "/opened", "/recent"])
        XCTAssertEqual(workspaces[1].groups.map(\.id), ["opened", "older"])
    }
    func testWorkersPromoteTheirProjectButStaleAndUnavailableRunningSessionsDoNot() {
        let parent = chat("parent", .idle, 100, "/workers")
        var worker = chat("worker", .working, 200, "/workers")
        worker.isSubagent = true; worker.parentSessionID = parent.id
        var stale = chat("stale", .working, 900, "/stale")
        stale.remote = RemoteOrigin(hostID: UUID(), hostName: "Other", sampledAt: Date(), stale: true)
        let missing = chat("missing", .working, 800, "/missing")
        var feed = NotchFeed(sessions: [parent, worker, stale, missing], includeIdle: true)
        let index = feed.groups.firstIndex { $0.id == missing.id }!
        feed.groups[index].unavailableIDs.insert(missing.id)
        let workspaces = NotchWorkspace.prioritized(feed.groups, path: { $0.cwd })
        XCTAssertEqual(workspaces.map(\.path), ["/workers", "/stale", "/missing"])
        XCTAssertEqual(workspaces[0].groups[0].workers.map(\.id), [worker.id])
    }
    func testEqualActivityHasDeterministicProjectAndChatTies() {
        let sessions = [chat("b", .working, 100, "/a"), chat("a", .working, 100, "/a"), chat("c", .working, 100, "/b")]
        let groups = NotchFeed(sessions: sessions, includeIdle: false).groups
        for input in [groups, Array(groups.reversed())] {
            let workspaces = NotchWorkspace.prioritized(input, path: { $0.cwd })
            XCTAssertEqual(workspaces.map(\.path), ["/a", "/b"])
            XCTAssertEqual(workspaces[0].groups.map(\.id), ["a", "b"])
        }
    }
    func testProjectOrderStaysFixedDuringInteractionAndUpdatesOnRelease() {
        let sessions = [chat("a", .working, 200, "/a"), chat("b", .working, 100, "/b")]
        var feed = NotchFeed(sessions: sessions, includeIdle: false)
        feed.groups = NotchWorkspace.prioritized(feed.groups, path: { $0.cwd }).flatMap(\.groups)
        var list = NotchListState()
        list.reconcile(feed, holding: false)
        feed.groups = NotchWorkspace.prioritized(feed.groups, interactions: ["b": Date(timeIntervalSince1970: 300)],
                                                path: { $0.cwd }).flatMap(\.groups)
        list.reconcile(feed, holding: true)
        XCTAssertEqual(NotchWorkspace.grouped(list.groups, path: { $0.cwd }).map(\.path), ["/a", "/b"])
        XCTAssertGreaterThan(list.pendingChanges, 0)
        list.reconcile(feed, holding: false)
        XCTAssertEqual(NotchWorkspace.grouped(list.groups, path: { $0.cwd }).map(\.path), ["/b", "/a"])
        XCTAssertEqual(list.pendingChanges, 0)
    }
    @MainActor func testChatSelectionRecordsLocalInteractionAndSurvivesRelaunch() {
        let suite = "burro-chat-interactions-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults)
        let value = chat("selected", .idle, 100, "/selected")
        store.selectAgent(value)
        XCTAssertNotNil(store.chatInteractions[value.id])
        let date = Date(timeIntervalSince1970: 300)
        store.recordChatInteraction(value.id, at: date)
        let restored = AppStore(defaults: defaults)
        XCTAssertEqual(restored.chatInteractions[value.id], date)
        XCTAssertEqual(value.updatedAt, Date(timeIntervalSince1970: 100))
        XCTAssertNil(value.hasUnreadResult)
    }
    @MainActor func testInteractionHistoryRetainsOnlyTheMostRecent512Chats() {
        let suite = "burro-chat-interaction-limit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Dictionary(uniqueKeysWithValues: (0..<512).map { ("chat-\($0)", Double($0)) }),
                     forKey: "chats.interactions")
        let store = AppStore(defaults: defaults)
        store.recordChatInteraction("new", at: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(store.chatInteractions.count, 512)
        XCTAssertNil(store.chatInteractions["chat-0"])
        XCTAssertEqual(store.chatInteractions["new"], Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(AppStore(defaults: defaults).chatInteractions, store.chatInteractions)
    }
}
