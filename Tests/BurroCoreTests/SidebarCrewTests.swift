import XCTest
@testable import BurroCore

/// The sidebar's crew: Needs you, Working, Ready to read in the Chats page's order, sub-agents and
/// idle chats left out, a cap with the rest counted; and the brand line's summary.
final class SidebarCrewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func chat(_ id: String, _ state: AgentState, minutesAgo: Double, unread: Bool = false, subagent: Bool = false) -> AgentSession {
        var session = AgentSession(id: id, provider: .claude, title: id, cwd: "/tmp", state: state,
                                   updatedAt: now.addingTimeInterval(-minutesAgo * 60), evidence: "fixture", hasUnreadResult: unread)
        if subagent { session.isSubagent = true }
        return session
    }

    func testOrderIsNeedsYouThenWorkingThenReadyNewestFirst() {
        let crew = SidebarCrew.make([
            chat("idle", .idle, minutesAgo: 1),
            chat("read-old", .idle, minutesAgo: 90, unread: true),
            chat("work-old", .working, minutesAgo: 30),
            chat("ask-old", .waiting, minutesAgo: 20),
            chat("read-new", .idle, minutesAgo: 5, unread: true),
            chat("work-new", .working, minutesAgo: 2),
            chat("ask-new", .waiting, minutesAgo: 3),
        ], cap: 12)
        XCTAssertEqual(crew.members.map(\.id), ["ask-new", "ask-old", "work-new", "work-old", "read-new", "read-old"])
        XCTAssertEqual(crew.members.map(\.status), [.needsYou, .needsYou, .working, .working, .readyToRead, .readyToRead])
        XCTAssertEqual(crew.total, 6)
        XCTAssertEqual(crew.overflow, 0)
    }

    func testSubagentsAndDuplicatesAreLeftOut() {
        let crew = SidebarCrew.make([chat("parent", .working, minutesAgo: 1), chat("helper", .waiting, minutesAgo: 0, subagent: true),
                                     chat("parent", .working, minutesAgo: 1)], cap: 12)
        XCTAssertEqual(crew.members.map(\.id), ["parent"])
    }

    func testCapCountsTheRest() {
        let sessions = (0..<15).map { chat("w\($0)", .working, minutesAgo: Double($0)) }
        let crew = SidebarCrew.make(sessions, cap: 12)
        XCTAssertEqual(crew.members.count, 12)
        XCTAssertEqual(crew.total, 15)
        XCTAssertEqual(crew.overflow, 3)
        XCTAssertEqual(crew.members.first?.id, "w0")
        XCTAssertEqual(SidebarCrew.make(sessions, cap: 0).members.count, 0)
        XCTAssertEqual(SidebarCrew.make([], cap: 12), .empty)
    }

    func testSummaryLine() {
        XCTAssertEqual(MenuBarStatus.idle.summary, "All quiet")
        XCTAssertEqual(MenuBarStatus.running(5).summary, "5 working")
        XCTAssertEqual(MenuBarStatus.needsYou(waiting: 1, running: 0).summary, "1 needs you")
        XCTAssertEqual(MenuBarStatus.needsYou(waiting: 2, running: 5).summary, "2 need you · 5 working")
    }
}
