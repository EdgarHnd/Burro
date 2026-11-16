import XCTest
@testable import BurroCore

final class NotchAttentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func chat(_ id: String, _ state: AgentState, provider: AgentProvider = .codex, unread: Bool = false,
                      subagent: Bool = false, parent: String? = nil, updated: TimeInterval = 0) -> AgentSession {
        AgentSession(id: id, provider: provider, title: id, cwd: "/work/\(id)", state: state, updatedAt: now.addingTimeInterval(updated),
                     evidence: "test", hasUnreadResult: unread, isSubagent: subagent, parentSessionID: parent)
    }

    func testSectionsPutWaitingFirstAndLeaveUnreadResultsToTheFooter() {
        XCTAssertEqual(NotchAttentionList.section(NotchGroup(id: "a", root: chat("a", .waiting), workers: [])), .needsYou)
        XCTAssertEqual(NotchAttentionList.section(NotchGroup(id: "b", root: chat("b", .working), workers: [])), .working)
        XCTAssertEqual(NotchAttentionList.section(NotchGroup(id: "s", root: chat("s", .scheduled), workers: [])), .working)
        XCTAssertNil(NotchAttentionList.section(NotchGroup(id: "d", root: chat("d", .idle, unread: true), workers: [])))
        // A done parent whose worker still runs stays listed; a waiting worker makes it need you.
        let busy = NotchGroup(id: "d", root: chat("d", .idle, unread: true), workers: [chat("w", .working, subagent: true, parent: "d")])
        XCTAssertEqual(NotchAttentionList.section(busy), .working)
        let asks = NotchGroup(id: "p", root: chat("p", .working), workers: [chat("w", .waiting, subagent: true, parent: "p")])
        XCTAssertEqual(NotchAttentionList.section(asks), .needsYou)
        XCTAssertEqual(NotchAttentionList.target(asks)?.id, "w")
    }

    func testGoneOrQuietChatsDoNotClaimToNeedYou() {
        var gone = NotchGroup(id: "a", root: chat("a", .waiting), workers: [])
        gone.unavailableIDs = ["a"]
        XCTAssertEqual(NotchAttentionList.section(gone), .working)
        var stale = chat("r", .waiting)
        stale.remote = RemoteOrigin(hostID: UUID(), hostName: "Studio", sampledAt: now, stale: true)
        XCTAssertEqual(NotchAttentionList.section(NotchGroup(id: "r", root: stale, workers: [])), .working)
    }

    func testSlotsHoldTheContentExactlyInGeometryRows() {
        XCTAssertEqual(NotchListLayout.slots(cards: 0, lines: 0, headers: 0), 0)
        // A card and its header take two rows; two cards, both headers and two lines fill all five.
        XCTAssertEqual(NotchListLayout.slots(cards: 1, lines: 0, headers: 0), 2)
        XCTAssertEqual(NotchListLayout.slots(cards: 1, lines: 0, headers: 1), 2)
        XCTAssertEqual(NotchListLayout.slots(cards: 2, lines: 2, headers: 2), 5)
        // Three working lines and their header fit in two rows.
        XCTAssertEqual(NotchListLayout.slots(cards: 0, lines: 3, headers: 1), 2)
        XCTAssertEqual(NotchListLayout.slots(cards: 0, lines: 1, headers: 1), 1)
        XCTAssertEqual(NotchListLayout.slots(cards: 1, lines: 2, headers: 2), 4)
        // Every answer leaves room: the geometry's list height covers the content height.
        for cards in 0...3 { for lines in 0...6 { for headers in 0...2 where cards + lines + headers > 0 {
            let rows = NotchListLayout.slots(cards: cards, lines: lines, headers: headers)
            let items = cards + lines + headers
            let content: CGFloat = 16 + CGFloat(cards) * NotchListLayout.cardHeight + CGFloat(lines) * 25 + CGFloat(headers) * 16 + CGFloat(items - 1) * 6
            let available: CGFloat = 16 + CGFloat(rows) * 56 + CGFloat(rows - 1) * 6
            XCTAssertGreaterThanOrEqual(available, content)
            XCTAssertLessThan(available - 62, content, "never a whole spare row")
        } } }
    }

    func testReplyModeFollowsTheComposerPlan() {
        var plan = ComposerPlan()
        plan.canType = true; plan.canSend = true
        XCTAssertEqual(NotchReplyMode.decide(plan, provider: .codex, checked: true), .reply(stopsFirst: false))
        XCTAssertEqual(NotchReplyMode.decide(plan, provider: .claude, checked: false), .checking, "Claude waits for its open-session check")
        plan.sendStopsFirst = true
        XCTAssertEqual(NotchReplyMode.decide(plan, provider: .claude, checked: true), .reply(stopsFirst: true))
        let attach = ComposerPlan(reason: "Attach to answer.", action: .attachInTerminal(handle: "abc123"))
        XCTAssertEqual(NotchReplyMode.decide(attach, provider: .claude, checked: true), .handOff(.attachInTerminal(handle: "abc123")))
        XCTAssertEqual(NotchReplyMode.decide(ComposerPlan(reason: "Quiet", action: .queue), provider: .claude, checked: true), .handOff(nil))
        XCTAssertEqual(NotchReplyMode.decide(ComposerPlan(reason: "Quiet"), provider: .codex, checked: false), .handOff(nil))
    }

    func testSubagentsNeverGetAReplyField() {
        var plan = ComposerPlan()
        plan.canType = true; plan.canSend = true
        XCTAssertEqual(NotchReplyMode.decide(plan, provider: .codex, checked: true, subagent: true), .handOff(nil))
        XCTAssertEqual(NotchReplyMode.decide(plan, provider: .claude, checked: false, subagent: true), .handOff(nil))
        XCTAssertNotNil(NotchReplyMode.handOffReason(plan, subagent: true))
        XCTAssertNil(NotchReplyMode.handOffReason(plan, subagent: false))
    }

    func testReplyFieldFollowsAnUntouchedDraftAndKeepsTheOwnersText() {
        var field = NotchReplyField()
        field.follow(draftID: "d1", text: "Merge it")
        XCTAssertEqual(field.text, "Merge it"); XCTAssertFalse(field.edited)
        XCTAssertFalse(field.returnSends, "an untouched draft goes only by Send")
        XCTAssertEqual(field.draftForSend(currentDraftID: "d1"), "d1")
        // Untouched: a new draft replaces it, a gone draft clears it.
        field.follow(draftID: "d2", text: "Wait for CI")
        XCTAssertEqual(field.text, "Wait for CI")
        field.follow(draftID: nil, text: nil)
        XCTAssertEqual(field.text, ""); XCTAssertFalse(field.edited)
        XCTAssertNil(field.draftForSend(currentDraftID: nil))
        // Edited by the owner: kept through draft changes, and Return sends it.
        field.follow(draftID: "d3", text: "Ship")
        field.type("Ship it after tests")
        XCTAssertTrue(field.edited); XCTAssertTrue(field.returnSends)
        field.follow(draftID: nil, text: nil)
        XCTAssertEqual(field.text, "Ship it after tests")
        XCTAssertNil(field.draftForSend(currentDraftID: nil), "the vanished draft isn't recorded again")
        // Emptying the field isn't an edit; whitespace alone isn't either.
        var cleared = NotchReplyField()
        cleared.follow(draftID: "d1", text: "Merge it")
        cleared.type("   ")
        XCTAssertFalse(cleared.edited)
        // Typed with no draft at all.
        var typed = NotchReplyField()
        typed.type("Yes")
        XCTAssertTrue(typed.returnSends)
        XCTAssertNil(typed.draftForSend(currentDraftID: nil))
        // After a send the same draft isn't prefilled again.
        var sent = NotchReplyField()
        sent.follow(draftID: "d1", text: "Merge it")
        sent.clearAfterSend()
        sent.follow(draftID: "d1", text: "Merge it")
        XCTAssertEqual(sent.text, "")
    }

    func testReplyHoldsOnlyForChatsStillTargeted() {
        let parent = chat("p", .waiting), worker = chat("w", .waiting, subagent: true, parent: "p")
        let both = NotchGroup(id: "p", root: parent, workers: [worker])
        XCTAssertEqual(NotchAttentionList.liveReplyIDs(["p", "gone"], groups: [both]), ["p"])
        // The parent was answered elsewhere: the group now targets its worker, the old id drops.
        let answered = NotchGroup(id: "p", root: chat("p", .idle), workers: [worker])
        XCTAssertEqual(NotchAttentionList.target(answered)?.id, "w")
        XCTAssertEqual(NotchAttentionList.liveReplyIDs(["p"], groups: [answered]), [])
        XCTAssertEqual(NotchAttentionList.liveReplyIDs(["p"], groups: []), [])
    }

    func testCardWordsAreHonestAboutWhatBurroKnows() {
        XCTAssertEqual(NotchReplyMode.status(question: "  Merge #412 now?  ", mode: .reply(stopsFirst: false)), "Merge #412 now?")
        XCTAssertEqual(NotchReplyMode.status(question: nil, mode: .reply(stopsFirst: false)), "Waiting for your reply")
        XCTAssertEqual(NotchReplyMode.status(question: "", mode: .handOff(nil)), "Waiting for your approval or answer")
        XCTAssertEqual(NotchReplyMode.handOffTitle(.openInProvider, provider: .codex, machine: nil), "Open in Codex")
        XCTAssertEqual(NotchReplyMode.handOffTitle(.openInProvider, provider: .claude, machine: nil), "Open in Claude")
        XCTAssertEqual(NotchReplyMode.handOffTitle(.attachInTerminal(handle: "a1b2c3"), provider: .claude, machine: nil), "Attach in Terminal")
        XCTAssertEqual(NotchReplyMode.handOffTitle(.attachOnMachine(handle: "a1b2c3"), provider: .claude, machine: "Studio"), "Attach on Studio")
        XCTAssertNil(NotchReplyMode.handOffTitle(nil, provider: .codex, machine: nil))
    }

    /// Ported from the notch's former WorkingClock: the notch now reads AppStore's TurnClock.
    func testTurnClockCountsOnlyTurnsItSawStart() {
        var clock = TurnClock()
        clock.update([chat("old", .working), chat("new", .idle)], now: now)
        XCTAssertNil(clock.turn("old", now: now), "already working at first sight: unknown, not wrong")
        clock.update([chat("old", .working), chat("new", .working, updated: 30)], now: now.addingTimeInterval(40))
        XCTAssertEqual(clock.turn("new", now: now.addingTimeInterval(100)), 60, "starts at the sample that saw it working")
        clock.update([chat("old", .working), chat("new", .working, updated: 90)], now: now.addingTimeInterval(95))
        XCTAssertEqual(clock.turn("new", now: now.addingTimeInterval(100)), 60, "the start stays put while it works")
        clock.update([chat("old", .idle), chat("new", .waiting)], now: now.addingTimeInterval(200))
        XCTAssertNil(clock.turn("new", now: now.addingTimeInterval(200)))
        clock.update([chat("old", .working, updated: 210)], now: now.addingTimeInterval(220))
        XCTAssertEqual(clock.turn("old", now: now.addingTimeInterval(230)), 10)
    }

    func testTurnClockText() {
        XCTAssertEqual(TurnClock.text(45), "45s")
        XCTAssertEqual(TurnClock.text(134), "2m 14s")
        XCTAssertEqual(TurnClock.text(41 * 60 + 20), "41m")
        XCTAssertEqual(TurnClock.text(65 * 60), "1h 05m")
        XCTAssertEqual(TurnClock.text(-3), "0s")
    }

    func testCompactStatusShowsTheMockupsThreeStates() {
        XCTAssertEqual(NotchCompactStatus(working: 0, scheduled: 0, waiting: 0, done: 0), NotchCompactStatus(working: 0, scheduled: 0, waiting: 0, done: 0))
        let idle = NotchCompactStatus(working: 0, scheduled: 0, waiting: 0, done: 0)
        XCTAssertEqual(idle.left, .none); XCTAssertEqual(idle.right, .none)
        let working = NotchCompactStatus(working: 3, scheduled: 1, waiting: 0, done: 0)
        XCTAssertEqual(working.left, .working(3)); XCTAssertEqual(working.right, .none)
        let needs = NotchCompactStatus(working: 3, scheduled: 0, waiting: 2, done: 4)
        XCTAssertEqual(needs.right, .needsYou(2))
        XCTAssertEqual(NotchCompactStatus(working: 0, scheduled: 2, waiting: 0, done: 1).left, .scheduled(2))
        XCTAssertEqual(NotchCompactStatus(working: 0, scheduled: 0, waiting: 0, done: 1).right, .toRead(1))
    }
}
