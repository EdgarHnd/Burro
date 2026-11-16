// The last review's safety rules, one test per layer: sub-agents never take a reply (Home's
// Needs you, the composer plan, ChatReply, an Orchestrator proposal), the notch's draft-sending
// decision, unconfirmed sends as a terminal proposal state (pure transitions and the store),
// Codex's refusal vs unknown outcome, the notch panel's focus guard, a dismissed start's worktree
// leftovers, the Ask prefill, Home's Stop offer and note key, and "Run triage now" picking.
// Nothing here sends, starts or stops anything: proposals live in a temporary folder.
import AppKit
import XCTest
@testable import Burro
@testable import BurroCore

final class ReviewFindingsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func chat(_ n: Int, _ state: AgentState, provider: AgentProvider = .codex, subagent: Bool = false) -> AgentSession {
        let id = String(format: "00000000-0000-4000-8000-%012d", n)
        var session = AgentSession(id: (provider == .codex ? "codex:" : "claude:") + id, provider: provider, title: "Chat \(n)",
                                   cwd: "/dev/app", state: state, updatedAt: now.addingTimeInterval(-Double(n)), evidence: "fixture")
        session.isSubagent = subagent
        return session
    }

    // MARK: 1. Sub-agents

    func testSubagentsNeverNeedYouOnHome() {
        let parent = chat(1, .waiting), worker = chat(2, .waiting, subagent: true)
        let summary = HomeSummary.build(sessions: [parent, worker], worktrees: [], now: now)
        XCTAssertEqual(summary.needsYou.map(\.id), [parent.id])
        XCTAssertEqual(summary.counts.waiting, 1, "a waiting sub-agent isn't counted")
        let item = BriefItem(chatID: worker.id, chatTitle: "Worker", kind: .decision, headline: "Asks", question: "Go?", sourceHash: "h", createdAt: now)
        let board = HomeBoard.build(waiting: [parent, worker], running: [], unread: [], briefNeeds: [item], all: [parent, worker])
        XCTAssertEqual(board.needsYou.map(\.id), [parent.id], "neither as a waiting chat nor through a Brief item")
    }

    func testSubagentsTakeNoReplyAnywhere() {
        let worker = chat(3, .waiting, subagent: true)
        XCTAssertEqual(ChatReply.unavailable(worker, host: nil), ChatReply.subagentReason)
        let plan = ChatReply.composerPlan(worker, host: nil, check: nil, setupProblem: nil, queued: false, hasURL: true)
        XCTAssertFalse(plan.canType || plan.canSend || plan.canQueue || plan.canSteer || plan.showPickers)
        XCTAssertNil(plan.action)
        XCTAssertEqual(plan.reason, ChatReply.subagentReason)
        // A working Codex sub-agent keeps its Stop.
        let busy = chat(4, .working, subagent: true)
        XCTAssertEqual(ChatReply.composerPlan(busy, host: nil, check: nil, setupProblem: nil, queued: false, hasURL: false).stop, .codex)
        // ChatReply.send refuses before anything runs.
        XCTAssertThrowsError(try ChatReply.send(ReplyRequest(text: "Yes"), to: worker, host: nil)) {
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, ChatReply.subagentReason)
        }
    }

    // MARK: 2. Notch draft sending

    func testNotchRefusesADraftSentOrChangedElsewhere() {
        var field = NotchReplyField()
        field.follow(draftID: "d1", text: "Merge it")
        XCTAssertEqual(field.sendDecision(currentDraftID: "d1"), .draft("d1"))
        field.type("Merge it after CI")
        // Sent from Home: the draft is gone, the edited text stays.
        field.follow(draftID: nil, text: nil)
        XCTAssertEqual(field.text, "Merge it after CI")
        XCTAssertEqual(field.sendDecision(currentDraftID: nil), .stale)
        XCTAssertEqual(NotchReplyField.gate(.stale, began: false, alreadySending: false), NotchReplyField.staleDraft)
        field.dropStaleDraft()
        XCTAssertEqual(field.sendDecision(currentDraftID: nil), .stale, "a second click doesn't deliver the same text")
        XCTAssertFalse(field.sendable); XCTAssertFalse(field.returnSends)
        // A deliberate change is a fresh message.
        field.type("Merge it after CI, then tag")
        XCTAssertEqual(field.sendDecision(currentDraftID: nil), .fresh)
        XCTAssertTrue(field.sendable); XCTAssertTrue(field.returnSends)
        // Changed elsewhere (a new draft replaced the one edited) is refused the same way.
        var replaced = NotchReplyField()
        replaced.follow(draftID: "d1", text: "A"); replaced.type("A, edited")
        replaced.follow(draftID: "d2", text: "B")
        XCTAssertEqual(replaced.sendDecision(currentDraftID: "d2"), .stale)
    }

    func testNotchSendsNothingWhenTheDraftCantBeMarked() {
        XCTAssertNil(NotchReplyField.gate(.fresh, began: false, alreadySending: false))
        XCTAssertNil(NotchReplyField.gate(.draft("d"), began: true, alreadySending: false))
        XCTAssertEqual(NotchReplyField.gate(.draft("d"), began: false, alreadySending: true), NotchReplyField.alreadySending)
        XCTAssertEqual(NotchReplyField.gate(.draft("d"), began: false, alreadySending: false), NotchReplyField.notMarked)
        // After a successful send the next typed text is fresh, not refused as stale.
        var field = NotchReplyField()
        field.follow(draftID: "d1", text: "Merge it")
        field.clearAfterSend()
        field.follow(draftID: nil, text: nil)
        field.type("Thanks")
        XCTAssertEqual(field.sendDecision(currentDraftID: nil), .fresh)
    }

    // MARK: 3. Unconfirmed sends

    private struct Plain: Error, LocalizedError { var errorDescription: String? { "Refused." } }

    func testAnUnconfirmedSendIsTerminalAndOnlySendAgainLeavesIt() {
        var action = OrchestratorAction(kind: .start, createdAt: now, text: "Fix it", machine: "Studio", agent: "claude", folder: "/srv/app")
        action.hostID = UUID().uuidString
        XCTAssertTrue(action.maySend(again: false, now: now))
        action.recordSend(text: "Fix it", outcome: .failure(RemoteLaunchError.notConfirmed(host: "Studio")), now: now)
        XCTAssertEqual(action.status, .unconfirmed)
        XCTAssertFalse(action.isWaiting(now: now))
        XCTAssertFalse(action.maySend(again: false, now: now), "no one-click Send")
        XCTAssertTrue(action.maySend(again: true, now: now), "Send again, after the confirmation")
        XCTAssertTrue(action.unconfirmedNote.contains("may have started") && action.unconfirmedNote.contains("Studio"))
        XCTAssertTrue(action.sendAgainWarning.contains("second chat"))
        // A failed Send again stays unconfirmed, never back to plain pending.
        action.recordSend(text: "Fix it", outcome: .failure(Plain()), now: now)
        XCTAssertEqual(action.status, .unconfirmed)
        XCTAssertEqual(action.error, "Refused.")
        action.recordSend(text: "Fix it", outcome: .success((message: "Started", chatID: "claude:x")), now: now)
        XCTAssertEqual(action.status, .sent)
        // An ordinary failure keeps a waiting proposal waiting.
        var reply = OrchestratorAction(kind: .reply, createdAt: now, text: "Yes", chatID: "codex:x")
        reply.recordSend(text: "Yes", outcome: .failure(Plain()), now: now)
        XCTAssertEqual(reply.status, .pending)
        reply.recordSend(text: "Yes", outcome: .failure(ReplyNotConfirmed("Studio didn't answer in time")), now: now)
        XCTAssertEqual(reply.status, .unconfirmed)
        XCTAssertTrue(reply.sendAgainWarning.contains("twice"))
    }

    func testAnUnconfirmedProposalIsntProposedAgain() throws {
        let store = OrchestratorActionStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("burro-actions-\(UUID().uuidString)/actions.json"))
        var first = OrchestratorAction(kind: .reply, createdAt: now, text: "Ship it", chatID: "codex:x")
        first.status = .unconfirmed
        _ = try store.propose(first, now: now)
        let again = try store.propose(OrchestratorAction(kind: .reply, createdAt: now, text: "Ship it", chatID: "codex:x"), now: now)
        XCTAssertTrue(again.duplicate)
        XCTAssertEqual(store.load().count, 1)
    }

    @MainActor func testTheStoreRecordsUnconfirmedAndGatesSendAgain() throws {
        let suite = "burro-review-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let actions = OrchestratorActionStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("burro-actions-\(UUID().uuidString)/actions.json"))
        let proposal = try actions.propose(OrchestratorAction(kind: .reply, createdAt: Date(), text: "Yes", chatID: "codex:x")).action
        let store = OrchestratorStore(defaults: defaults, actionStore: actions)
        XCTAssertTrue(store.beginSending(proposal.id))
        XCTAssertFalse(store.beginSending(proposal.id), "not twice at once")
        store.finishSending(proposal.id, text: "Yes", outcome: .failure(ReplyNotConfirmed("no answer")))
        XCTAssertEqual(store.actions.first?.status, .unconfirmed)
        XCTAssertFalse(store.beginSending(proposal.id), "a plain Send can't start it again")
        XCTAssertTrue(store.beginSending(proposal.id, again: true))
        store.finishSending(proposal.id, text: "Yes", outcome: .failure(Plain()))
        XCTAssertEqual(store.actions.first?.status, .unconfirmed, "a failed Send again stays unconfirmed")
        XCTAssertTrue(store.waitingActions.isEmpty)
    }

    func testCodexRefusalsAndUnsentRequestsAreFailuresAndTheRestUnknown() {
        XCTAssertTrue(ChatReply.codexTurnFailure(CodexRPCRefusal(message: "no such thread")) is CodexRPCRefusal)
        XCTAssertTrue(ChatReply.codexTurnFailure(CodexRequestNotSent()) is CodexRequestNotSent)
        let lost = ChatReply.codexTurnFailure(LaunchError.failed("Codex's app server didn't answer in time."))
        XCTAssertTrue(lost is ReplyNotConfirmed)
        XCTAssertTrue(SendOutcome.isUnconfirmed(lost))
        XCTAssertTrue(SendOutcome.isUnconfirmed(ProcessTimedOut(name: "claude")))
        XCTAssertFalse(SendOutcome.isUnconfirmed(LaunchError.failed("Refused.")))
        XCTAssertEqual(RemoteLaunchError.timedOut(host: "Studio").errorDescription, "Studio didn't answer in time.")
    }

    // MARK: 4. Notch focus guard

    @MainActor func testARefusedFocusRequestLeavesFocusWhereItWas() {
        let panel = AgentNotchPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        let other = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        panel.contentView?.addSubview(field); panel.contentView?.addSubview(other)
        let before = panel.firstResponder
        XCTAssertFalse(panel.makeFirstResponder(field), "no owner event: refused")
        XCTAssertTrue(panel.firstResponder === before, "and nothing resigned")
    }

    // MARK: 5. Worktree leftovers

    func testADismissedStartWhoseWorktreeStaysComesBackFailedNamingIt() {
        var launches = PendingLaunches()
        let request = LaunchRequest(provider: .claude, prompt: "Fix it", folder: "/dev/app")
        let row = launches.begin(request, follow: false, now: now, worktreeBranch: "claude/fix-it")
        launches.remove(row.id)
        launches.leftBehind(row, leftovers: [])
        XCTAssertTrue(launches.isEmpty, "a clean undo leaves nothing")
        launches.leftBehind(row, leftovers: ["the worktree registration /dev/app-fix-it", "the branch claude/fix-it"])
        let back = launches.launch(row.id)
        XCTAssertEqual(back?.isFailed, true)
        XCTAssertTrue(back?.failure?.contains("/dev/app-fix-it") == true && back?.failure?.contains("claude/fix-it") == true)
        XCTAssertTrue(back?.failure?.contains("Worktrees") == true)
        XCTAssertEqual(back?.request.folder, "/dev/app")
        XCTAssertEqual(back?.retryInNewWorktree, true)
    }

    // MARK: 6. Ask about this chat

    func testAskPrefillKeepsAHalfWrittenQuestionAndReturnSendsOnlyTypedText() {
        let question = OrchestratorAskAbout.question(title: "Fix login", machine: nil)
        XCTAssertEqual(OrchestratorAskAbout.prefilled(existing: "", question: question), question)
        XCTAssertEqual(OrchestratorAskAbout.prefilled(existing: "  \n", question: question), question)
        XCTAssertEqual(OrchestratorAskAbout.prefilled(existing: "Also, what about CI \n", question: question), "Also, what about CI\n" + question)
        XCTAssertFalse(OrchestratorAskAbout.returnSends(draft: question, prefilled: question), "untouched: only Ask sends it")
        XCTAssertTrue(OrchestratorAskAbout.returnSends(draft: question + " And CI?", prefilled: question))
        XCTAssertTrue(OrchestratorAskAbout.returnSends(draft: "Typed", prefilled: nil))
        XCTAssertFalse(OrchestratorAskAbout.returnSends(draft: "  ", prefilled: nil))
    }

    // MARK: 7. Home Stop

    func testHomeStopFollowsTheHeadersDecision() {
        let claude = chat(5, .working, provider: .claude)
        XCTAssertEqual(HomeBoard.stopOffer(claude, host: nil, check: nil), .none, "no Stop until the check answers")
        var terminal = ChatReply.ClaudeCheck(); terminal.open = true; terminal.busy = true
        XCTAssertEqual(HomeBoard.stopOffer(claude, host: nil, check: terminal), .elsewhere, "a terminal chat: stop it there")
        var background = ChatReply.ClaudeCheck(); background.open = true; background.background = true; background.attach = "c0d2240d"
        XCTAssertEqual(HomeBoard.stopOffer(claude, host: nil, check: background), .stop)
        XCTAssertEqual(HomeBoard.stopOffer(chat(6, .working), host: nil, check: nil), .stop, "Codex turns")
        let start = now
        XCTAssertNotEqual(HomeBoard.turnKey(claude, turnStart: start), HomeBoard.turnKey(claude, turnStart: start.addingTimeInterval(60)))
        XCTAssertNotEqual(HomeBoard.turnKey(claude, turnStart: start), HomeBoard.turnKey(chat(5, .waiting, provider: .claude), turnStart: start))
    }

    // MARK: 8. Run triage now

    private func input(_ id: String, _ text: String) -> TriageInput {
        TriageInput.build(chatID: id, title: "", project: "", machine: "", stop: .finished,
                          messages: [ChatMessage(id: 0, kind: .assistant, text: text, at: now)], notes: [])
    }

    func testRunNowPicksUntriagedChatsNewestFirst() {
        let inputs: [(id: String, input: TriageInput?)] = (0..<8).map { ("c\($0)", input("c\($0)", "text \($0)")) }
        // The five newest were triaged as they stand; older ones weren't.
        let triaged = Dictionary(uniqueKeysWithValues: inputs.prefix(5).map { ($0.id, $0.input!.sourceHash) })
        let picked = TriageNow.pick(inputs, triaged: triaged, total: 8)
        XCTAssertEqual(picked.chatIDs, ["c5", "c6", "c7"])
        XCTAssertEqual(picked.outcome.message, "Triaging 3 chats now")
        // Everything triaged: says so; past the look limit it says how far it looked.
        let all = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0.input!.sourceHash) })
        XCTAssertEqual(TriageNow.pick(inputs, triaged: all, total: 8).outcome.message, "Nothing new to triage")
        XCTAssertEqual(TriageNow.pick(inputs, triaged: all, total: 40).outcome, .nothingNew(more: true))
        // Unreadable and empty transcripts are skipped by the same rule a run uses.
        XCTAssertFalse(TriageNow.needsTriage(nil, triaged: [:]))
        XCTAssertFalse(TriageNow.needsTriage(TriageInput.build(chatID: "e", title: "", project: "", machine: "", stop: .finished, messages: [], notes: []), triaged: [:]))
        // The gate still decides first.
        let chats = [BriefChatState(id: "w", waiting: true, updatedAt: now)]
        XCTAssertEqual(TriageNow.plan(chats: chats, gate: .off).outcome, .paused("Triage is off"))
        XCTAssertEqual(TriageNow.plan(chats: chats, gate: .dailyCap(150)).chatIDs, [])
        XCTAssertNil(TriageNow.plan(chats: chats, gate: .open).outcome)
        XCTAssertEqual(TriageNow.plan(chats: [], gate: .open).outcome, .nothing)
    }

    func testAManualRunGoesFirstAndIsDueAtOnce() {
        var scheduler = TriageScheduler()
        for index in 0..<5 { scheduler.enqueue("auto\(index)", at: now) }
        XCTAssertFalse(scheduler.isDue(now: now))
        scheduler.prioritize(["auto3", "manual"], at: now)
        XCTAssertTrue(scheduler.isDue(now: now), "due immediately")
        XCTAssertEqual(scheduler.pending.count, 6, "an already-queued chat moves up, not twice")
        XCTAssertEqual(scheduler.takeBatch().map(\.chatID), ["auto3", "manual", "auto0", "auto1", "auto2"])
        // A re-click with chats already queued makes them due again.
        var again = TriageScheduler()
        again.enqueue("a", at: now)
        again.prioritize(["a"], at: now)
        XCTAssertTrue(again.isDue(now: now))
    }
}
