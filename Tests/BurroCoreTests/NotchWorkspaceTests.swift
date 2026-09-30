// Grouping retains all active agents and only real unread completions.
import XCTest
@testable import BurroCore

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
}
