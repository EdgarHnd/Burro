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

    /// The sidebar said "7 working" while Home said "5 chats are working": the snapshot's raw counts
    /// include working sub-agents, Home's board leaves them out (they belong to their parent chat).
    func testSidebarLineCountsWhatHomesSentenceCounts() {
        let sessions = (0..<5).map { session("w\($0)", .working) }
            + [session("sub1", .working, subagent: true), session("sub2", .working, subagent: true),
               session("wait", .waiting), session("subwait", .waiting, subagent: true), session("asked", .idle)]
        let raw = activity(sessions)
        XCTAssertEqual(raw.workingCount, 7, "the old line's source")
        XCTAssertEqual(raw.waitingCount, 2)
        let briefNeeds = [BriefItem(chatID: "asked", kind: .decision, headline: "Which branch?", sourceHash: "h", createdAt: now)]
        // Home: HomeSummary's lists into HomeBoard, as HomeChatSections.board builds it.
        let summary = HomeSummary.build(sessions: sessions, worktrees: [], now: now)
        let home = HomeBoard.build(waiting: summary.needsYou, running: summary.running, unread: summary.unread,
                                   briefNeeds: briefNeeds, all: sessions)
        XCTAssertEqual(HomeBoard.sentence(needsYou: home.needsYou.count, working: home.working.count, toRead: home.toRead.count),
                       "2 chats need you and 5 are working.")
        // The sidebar: the same board straight from the sample.
        let sidebar = MenuBarStatus(HomeBoard.build(sessions: sessions, briefNeeds: briefNeeds, all: sessions))
        XCTAssertEqual(sidebar, .needsYou(waiting: home.needsYou.count, running: home.working.count))
        XCTAssertEqual(sidebar.summary, "2 need you · 5 working")
        // The menu-bar item leaves sub-agents out too (it doesn't count triage's questions).
        XCTAssertEqual(MenuBarStatus(raw), .needsYou(waiting: 1, running: 5))
    }
}
