import XCTest
@testable import BurroCore

final class HomeBoardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func chat(_ uuid: Int, _ state: AgentState, provider: AgentProvider = .codex, unread: Bool = false, age: TimeInterval = 60,
                      subagent: Bool = false, remote: RemoteOrigin? = nil) -> AgentSession {
        let id = String(format: "00000000-0000-0000-0000-%012d", uuid)
        let prefix = provider == .codex ? "codex:" : "claude:"
        let full = (remote.map { "remote:\($0.hostID.uuidString):" } ?? "") + prefix + id
        var session = AgentSession(id: full, provider: provider, title: "Chat \(uuid)", cwd: "/dev/app", state: state,
                                   updatedAt: now.addingTimeInterval(-age), evidence: "Fixture")
        session.hasUnreadResult = unread
        session.isSubagent = subagent
        session.remote = remote
        return session
    }
    private func item(_ chatID: String?, _ kind: BriefItem.Kind, headline: String = "Headline", question: String? = nil, age: TimeInterval = 30) -> BriefItem {
        BriefItem(chatID: chatID, chatTitle: "Triaged", kind: kind, headline: headline, question: question, sourceHash: "h",
                  createdAt: now.addingTimeInterval(-age))
    }

    func testNeedsYouMergesWaitingChatsWithTriageAndNeverRepeatsThemAsReadyToRead() {
        let waiting = chat(1, .waiting, age: 300)
        let asked = chat(2, .idle, unread: true, age: 600)      // ended a turn on a question
        let done = chat(3, .idle, unread: true, age: 900)
        let working = chat(4, .working)
        let sub = chat(5, .working, subagent: true)
        let board = HomeBoard.build(
            waiting: [waiting], running: [working, sub], unread: [asked, done],
            briefNeeds: [item(waiting.id.uppercased(), .decision, question: "Merge now?", age: 10),
                         item(asked.id, .blocked, question: "Which branch?", age: 120),
                         item(working.id, .decision, age: 5),               // works again: left out
                         item(nil, .failed, headline: "Gone chat", age: 2000)],
            briefFinished: [item(done.id, .done, headline: "Opened PR #12, tests pass.")],
            briefStuck: [item(working.id, .stuck, headline: "No new output for 50 min")],
            all: [waiting, asked, done, working],
            previews: [done.id: "ignored when triage has a headline"])

        XCTAssertEqual(board.needsYou.map(\.title), ["Chat 1", "Chat 2", "Triaged"])
        XCTAssertEqual(board.needsYou[0].item?.question, "Merge now?", "chat ids match case-insensitively")
        XCTAssertTrue(board.needsYou[0].waiting)
        XCTAssertFalse(board.needsYou[1].waiting)
        XCTAssertEqual(board.needsYou[1].since, now.addingTimeInterval(-120), "a triaged question dates from the reading")
        XCTAssertNil(board.needsYou[2].session)
        XCTAssertEqual(board.toRead.map(\.session.id), [done.id], "the asked chat is listed once, under Needs you")
        XCTAssertEqual(board.toRead[0].outcome, "Opened PR #12, tests pass.")
        XCTAssertEqual(board.working.map(\.id), [working.id], "subagents stay with their parent")
        XCTAssertEqual(board.working[0].stuck?.headline, "No new output for 50 min")
    }

    func testReadyToReadFallsBackToTheScannedPreviewThenNothing() {
        let a = chat(1, .idle, unread: true), b = chat(2, .idle, unread: true)
        let board = HomeBoard.build(waiting: [], running: [], unread: [a, b], previews: [a.id: "  Three   options\twritten up "])
        XCTAssertEqual(board.toRead.map(\.outcome), ["Three options written up", nil])
        XCTAssertTrue(HomeBoard.build(waiting: [], running: [], unread: []).isEmpty)
    }

    func testSentenceReadsLikeTheMockup() {
        XCTAssertEqual(HomeBoard.sentence(needsYou: 2, working: 3, toRead: 3, shipped: 4),
                       "2 chats need you, 3 are working, and 4 pull requests shipped today.")
        XCTAssertEqual(HomeBoard.sentence(needsYou: 1, working: 0, toRead: 2), "1 chat needs you.")
        XCTAssertEqual(HomeBoard.sentence(needsYou: 0, working: 1, toRead: 0, shipped: 1), "1 chat is working and 1 pull request shipped today.")
        XCTAssertEqual(HomeBoard.sentence(needsYou: 0, working: 0, toRead: 1), "1 result is ready to read.")
        XCTAssertEqual(HomeBoard.sentence(needsYou: 0, working: 0, toRead: 0), "All quiet. Nothing needs you and no agents are working.")
        XCTAssertEqual(HomeBoard.sentence(needsYou: 0, working: 0, toRead: 0, shipped: 2),
                       "Nothing needs you and no agents are working. 2 pull requests shipped today.")
        XCTAssertEqual(HomeBoard.sentence(needsYou: 1, working: 2, toRead: 0, usageLine: "Claude session has 12% left."),
                       "1 chat needs you and 2 are working. Claude session has 12% left.")
    }

    func testMachineLineUsesCountsAndTheStatusLine() {
        var counts = HomeCounts(); counts.running = 2; counts.waiting = 1
        XCTAssertEqual(HomeBoard.machineLine(counts: counts, status: nil), "2 working · 1 needs you")
        XCTAssertEqual(HomeBoard.machineLine(counts: HomeCounts(), status: nil), "Quiet")
        var one = HomeCounts(); one.running = 1
        XCTAssertEqual(HomeBoard.machineLine(counts: one, status: "Connected · checked 8 s ago"), "1 working · checked 8 s ago")
        XCTAssertEqual(HomeBoard.machineLine(counts: one, status: "Unreachable since 14:02 · retrying in 30 s"),
                       "Unreachable since 14:02 · retrying in 30 s", "counts from a machine Burro can't reach aren't current")
        XCTAssertEqual(HomeBoard.machineLine(counts: HomeCounts(), status: "Paused"), "Paused")
    }

    func testTimesAreShortAndPlain() {
        XCTAssertEqual(HomeBoard.turnText(20), "turn under 1 min")
        XCTAssertEqual(HomeBoard.turnText(18 * 60 + 30), "turn 18 min")
        XCTAssertEqual(HomeBoard.turnText(65 * 60), "turn 1 h 05 min")
        XCTAssertEqual(HomeBoard.activeText(now.addingTimeInterval(-240), now: now), "active 4 min ago")
        // The shortest form, for a footer with no room beside its action.
        XCTAssertEqual(HomeBoard.compactTime("turn under 1 min"), "<1m")
        XCTAssertEqual(HomeBoard.compactTime("turn 18 min"), "18m")
        XCTAssertEqual(HomeBoard.compactTime("turn 1 h 05 min"), "1h 05m")
        XCTAssertEqual(HomeBoard.compactTime("active just now"), "now")
        XCTAssertEqual(HomeBoard.compactTime("active 4 min ago"), "4m ago")
        XCTAssertEqual(HomeBoard.compactTime("active 2 h ago"), "2h ago")
        XCTAssertEqual(HomeBoard.waitText(now.addingTimeInterval(-60), waiting: true, now: now), "waiting 1 min")
        XCTAssertEqual(HomeBoard.waitText(now.addingTimeInterval(-240), waiting: false, now: now), "asked 4 min ago")
    }

    func testStopOfferIsHonestAboutWhoOwnsTheChat() {
        XCTAssertEqual(HomeBoard.stopOffer(chat(1, .working), host: nil, check: nil), .stop)
        var background = ChatReply.ClaudeCheck(); background.open = true; background.background = true; background.attach = "c0d2240d"
        XCTAssertEqual(HomeBoard.stopOffer(chat(2, .working, provider: .claude), host: nil, check: background), .stop)
        var desktop = chat(3, .working, provider: .claude); desktop.claudeDesktopSessionID = "local_abc-123"
        XCTAssertEqual(HomeBoard.stopOffer(desktop, host: nil, check: nil), .openInProvider)
        let devbox = RemoteHost(name: "Studio", destination: "me@studio")
        let live = RemoteOrigin(hostID: devbox.id, hostName: "Studio", sampledAt: now, stale: false)
        XCTAssertEqual(HomeBoard.stopOffer(chat(4, .working, remote: live), host: devbox, check: nil), .stop)
        XCTAssertEqual(HomeBoard.stopOffer(chat(4, .working, remote: live), host: nil, check: nil), .none)
        var stale = live; stale.stale = true
        XCTAssertEqual(HomeBoard.stopOffer(chat(5, .working, provider: .claude, remote: stale), host: devbox, check: background), .none)
        var odd = chat(6, .working); odd.id = "cursor:whatever"
        XCTAssertEqual(HomeBoard.stopOffer(odd, host: nil, check: nil), .none)
    }

    func testTurnClockOnlyTimesTurnsItSawBegin() {
        var clock = TurnClock()
        let early = chat(1, .working), idle = chat(2, .idle)
        clock.update([early, idle], now: now)
        XCTAssertNil(clock.turn(early.id, now: now), "already working when Burro started: unknown")

        var started = idle; started.state = .working
        var fresh = chat(3, .working); fresh.startedAt = now.addingTimeInterval(5)
        var old = chat(4, .working); old.startedAt = now.addingTimeInterval(-3600)
        clock.update([early, started, fresh, old], now: now.addingTimeInterval(10))
        XCTAssertEqual(clock.turn(started.id, now: now.addingTimeInterval(70)), 60, "seen idle, then working")
        XCTAssertEqual(clock.turn(fresh.id, now: now.addingTimeInterval(65)), 60, "a new chat starts at its own start")
        XCTAssertNil(clock.turn(old.id, now: now.addingTimeInterval(10)), "first seen mid-turn: unknown")
        XCTAssertNil(clock.turn(early.id, now: now.addingTimeInterval(10)))

        clock.update([early, started, fresh, old], now: now.addingTimeInterval(20))
        XCTAssertEqual(clock.turn(started.id, now: now.addingTimeInterval(70)), 60, "a running turn keeps its start")
        var done = started; done.state = .idle
        clock.update([early, done, fresh, old], now: now.addingTimeInterval(30))
        XCTAssertNil(clock.turn(started.id, now: now.addingTimeInterval(30)))
    }
}
