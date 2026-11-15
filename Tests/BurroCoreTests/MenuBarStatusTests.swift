// The menu-bar item shows the icon alone when idle, the running count while agents work, and a
// "needs you" count while a chat waits; its menu lists the newest waiting chats.
import XCTest
@testable import BurroCore

final class MenuBarStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func session(_ id: String, _ state: AgentState, age: TimeInterval = 60, stale: Bool? = nil, subagent: Bool? = nil) -> AgentSession {
        var session = AgentSession(id: id, provider: .claude, title: id, cwd: "/dev/app", state: state,
                                   updatedAt: now.addingTimeInterval(-age), evidence: "Fixture")
        if let stale { session.remote = RemoteOrigin(hostID: UUID(), hostName: "mini", sampledAt: now, stale: stale) }
        session.isSubagent = subagent
        return session
    }
    private func activity(_ sessions: [AgentSession]) -> AgentActivitySnapshot {
        AgentActivitySnapshot(sessions: sessions, warnings: [], sampledAt: now)
    }

    func testIdleRunningAndNeedsYou() {
        XCTAssertEqual(MenuBarStatus(activity([session("a", .idle)])), .idle)
        XCTAssertNil(MenuBarStatus.idle.count)
        let running = MenuBarStatus(activity([session("a", .working), session("b", .working)]))
        XCTAssertEqual(running, .running(2))
        XCTAssertEqual(running.count, 2)
        let waiting = MenuBarStatus(activity([session("a", .working), session("b", .waiting)]))
        XCTAssertEqual(waiting, .needsYou(waiting: 1, running: 1))
        XCTAssertEqual(waiting.count, 1)
        XCTAssertEqual(waiting.accessibilityLabel, "Burro: 1 needs you, 1 running")
    }
    func testAStaleRemoteWaitDoesNotCount() {
        XCTAssertEqual(MenuBarStatus(activity([session("a", .waiting, stale: true)])), .idle)
    }
    func testNeedsYouListsNewestFiveOnce() {
        var sessions = (0..<7).map { session("w\($0)", .waiting, age: TimeInterval($0) * 60) }
        sessions += [session("w0", .waiting), session("run", .working), session("old", .waiting, stale: true),
                     session("sub", .waiting, subagent: true)]
        let listed = MenuBarStatus.needsYou(sessions)
        XCTAssertEqual(listed.map(\.id), ["w0", "w1", "w2", "w3", "w4"])
    }
}
