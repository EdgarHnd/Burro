import Foundation
import XCTest
@testable import Burro
@testable import BurroCore

/// The Orchestrator page's Brief tab: its summary line, Budget numbers, "Run triage now" (gated
/// exactly like automatic triage, with a fake runner that never reaches Claude), the memory
/// preview and the column count.
final class OrchestratorBriefPageTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }
    /// Sunday 15 November 2026, 14:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_794_751_200)

    func testSummaryLineShowsOnlyCountsThatExistAndWhenTriageRan() {
        XCTAssertEqual(OrchestratorPageSummary.line(needs: 2, finished: 3, stuck: 1, lastTriage: now.addingTimeInterval(-180), triaging: 0, now: now),
                       "2 need you, 3 finished, 1 stuck · last triage 3 min ago")
        XCTAssertEqual(OrchestratorPageSummary.line(needs: 1, finished: 0, stuck: 0, lastTriage: nil, triaging: 0, now: now), "1 needs you")
        XCTAssertEqual(OrchestratorPageSummary.line(needs: 0, finished: 0, stuck: 0, lastTriage: now.addingTimeInterval(-7200), triaging: 0, now: now),
                       "Nothing waiting on you · last triage 2 h ago")
        XCTAssertEqual(OrchestratorPageSummary.line(needs: 0, finished: 1, stuck: 0, lastTriage: now, triaging: 3, now: now),
                       "1 finished · reading 3 chats…")
    }

    func testBudgetReadsClaudeWindowsRunsAndTheGate() {
        let windows = [UsageWindow(id: "session", title: "Session", remainingPercent: 62, resetsAt: now.addingTimeInterval(9 * 3600)),
                       UsageWindow(id: "weekly", title: "Weekly", remainingPercent: 8, resetsAt: now.addingTimeInterval(4 * 86_400))]
        let runs = [OrchestratorRun(at: now, trigger: "triage", model: "haiku", costUSD: 0.12),
                    OrchestratorRun(at: now, trigger: "ask", model: "fable", costUSD: 0.30)]
        let budget = OrchestratorBudget(runsToday: 9, cap: 150, runs: runs, claude: windows, enabled: true, gate: .weekly(8))
        XCTAssertEqual(budget.cost, "$0.42")
        XCTAssertEqual(budget.session?.left, "62% left")
        XCTAssertEqual(budget.session?.paused, false)
        XCTAssertEqual(budget.weekly?.paused, true, "Below the 10% weekly floor")
        XCTAssertEqual(budget.pausedReason, "Paused: Claude weekly limit 8% left")
        XCTAssertEqual(budget.floorsLine, "Triage pauses below 15% session or 10% weekly left.")
        XCTAssertEqual(budget.session?.resetText(now: now, calendar: calendar), "Resets 23:00")
        XCTAssertEqual(budget.weekly?.resetText(now: now, calendar: calendar), "Resets Thursday")

        let unknown = OrchestratorBudget(runsToday: 0, cap: 50, runs: [], claude: nil, enabled: false, gate: .off)
        XCTAssertNil(unknown.session)
        XCTAssertNil(unknown.weekly)
        XCTAssertNil(unknown.pausedReason, "Off is the switch, not a pause")
        XCTAssertEqual(unknown.cost, "$0.00")
    }

    func testResetTextForTomorrowLaterAndPast() {
        let meter = { (date: Date?) in OrchestratorBudget.Meter(title: "x", remaining: 50, floor: 15, resetsAt: date) }
        XCTAssertEqual(meter(now.addingTimeInterval(19 * 3600)).resetText(now: now, calendar: calendar), "Resets tomorrow 09:00")
        XCTAssertEqual(meter(now.addingTimeInterval(10 * 86_400)).resetText(now: now, calendar: calendar), "Resets 25 Nov")
        XCTAssertNil(meter(now.addingTimeInterval(-60)).resetText(now: now, calendar: calendar))
        XCTAssertNil(meter(nil).resetText(now: now, calendar: calendar))
    }

    func testRunNowPlanReadsNewestWaitingOrUnreadChatsOnlyThroughTheGate() {
        let chats = [BriefChatState(id: "working", working: true, updatedAt: now),
                     BriefChatState(id: "old-wait", waiting: true, updatedAt: now.addingTimeInterval(-600)),
                     BriefChatState(id: "unread", unread: true, updatedAt: now.addingTimeInterval(-60)),
                     BriefChatState(id: "idle", updatedAt: now)]
        let open = TriageNow.plan(chats: chats, gate: .open)
        XCTAssertNil(open.outcome, "the candidates are read before it says anything")
        XCTAssertEqual(open.chatIDs, ["unread", "old-wait"])
        XCTAssertEqual(TriageNow.plan(chats: chats, gate: .off).outcome, .paused("Triage is off"))
        XCTAssertEqual(TriageNow.plan(chats: chats, gate: .dailyCap(150)).outcome, .paused("Paused: 150 runs today, the daily cap"))
        XCTAssertEqual(TriageNow.plan(chats: chats, gate: .session(9)).chatIDs, [])
        XCTAssertEqual(TriageNow.plan(chats: [chats[0]], gate: .open).outcome, .nothing)
        let many = (0..<40).map { BriefChatState(id: "c\($0)", waiting: true, updatedAt: now.addingTimeInterval(Double($0))) }
        let read = TriageNow.plan(chats: many, gate: .open).chatIDs
        XCTAssertEqual(read.count, TriageNow.lookLimit, "reads at most the newest thirty")
        XCTAssertEqual(read.first, "c39")
        XCTAssertEqual(TriageNow.Outcome.queued(1).message, "Triaging 1 chat now")
    }

    func testMemoryPreviewPutsGlobalThenMainProjectFirst() {
        let date = Date(timeIntervalSince1970: 0)
        let entries = [OrchestratorMemoryEntry(id: "other", scope: "/x/other", text: "o", source: .user, createdAt: date),
                       OrchestratorMemoryEntry(id: "main", scope: "/x/main", text: "m", source: .user, createdAt: date),
                       OrchestratorMemoryEntry(id: "g1", scope: OrchestratorMemoryEntry.global, text: "g", source: .user, createdAt: date),
                       OrchestratorMemoryEntry(id: "g2", scope: OrchestratorMemoryEntry.global, text: "h", source: .orchestrator, createdAt: date)]
        XCTAssertEqual(OrchestratorMemory.preview(entries, mainProject: "/x/main").map(\.id), ["g1", "g2", "main", "other"])
        XCTAssertEqual(OrchestratorMemory.preview(entries, mainProject: nil, limit: 2).map(\.id), ["g1", "g2"])
    }

    func testColumnsCollapseAtNarrowWidths() {
        XCTAssertEqual(OrchestratorPageColumns.count(width: 1143), 2)
        XCTAssertEqual(OrchestratorPageColumns.count(width: 863), 2)
        XCTAssertEqual(OrchestratorPageColumns.count(width: 700), 1)
        XCTAssertEqual(OrchestratorPageColumns.sideWidth(width: 1143), 380)
        XCTAssertEqual(OrchestratorPageColumns.sideWidth(width: 863), 360)
    }

    // MARK: The store's "Run triage now"

    @MainActor func testRunNowGoesThroughTheGateAndNeverCallsClaudeWithoutATranscript() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-runnow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let suite = "burro.runnow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: OrchestratorBriefStore.morningKey)
        let runs = OrchestratorRuns(url: folder.appendingPathComponent("runs.jsonl"))
        let called = CallFlag()
        let runner = TriageRunner(executable: { "/fake/claude" }, run: { _, _, _, _ in called.set(); return (0, "{\"results\":[]}") })
        let brief = OrchestratorBriefStore(defaults: defaults, store: BriefStore(url: folder.appendingPathComponent("brief.json")),
                                           actions: OrchestratorActionStore(url: folder.appendingPathComponent("actions.json")),
                                           runs: runs, runner: runner)

        let inert = await brief.runNow()
        XCTAssertEqual(inert, .paused("Triage hasn't started yet"), "Inert until started")
        brief.start()
        let date = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        // Ids that aren't provider chats, so no transcript is ever read for them.
        brief.update([AgentSession(id: "t-wait", provider: .codex, title: "Waits", cwd: "/tmp/a", state: .waiting, updatedAt: date, evidence: "Fixture"),
                      AgentSession(id: "t-work", provider: .codex, title: "Works", cwd: "/tmp/b", state: .working, updatedAt: date, evidence: "Fixture")],
                     now: date)
        XCTAssertEqual(brief.triaging, 0, "A chat already waiting when first seen isn't queued by itself")

        // Its transcript can't be read, so there is nothing new to triage: no run, no call.
        let unreadable = await brief.runNow(now: date)
        XCTAssertEqual(unreadable, .nothingNew(more: false))
        XCTAssertEqual(unreadable.message, "Nothing new to triage")
        XCTAssertEqual(brief.triaging, 0)
        XCTAssertFalse(called.value, "Nothing could be read, so Claude is never called")

        brief.autoTriage = false
        let off = await brief.runNow(now: date)
        XCTAssertEqual(off, .paused("Triage is off"))
        XCTAssertEqual(brief.triaging, 0)

        // The daily cap: one triage run already logged today with a cap of one.
        brief.autoTriage = true
        try runs.append(OrchestratorRun(at: date, trigger: "triage", model: "haiku"))
        let capped = OrchestratorBriefStore(defaults: defaults, store: BriefStore(url: folder.appendingPathComponent("brief.json")),
                                            actions: OrchestratorActionStore(url: folder.appendingPathComponent("actions.json")),
                                            runs: runs, runner: runner)
        capped.dailyCap = 1
        capped.start()
        capped.update([AgentSession(id: "t-wait", provider: .codex, title: "Waits", cwd: "/tmp/a", state: .waiting, updatedAt: date, evidence: "Fixture")],
                      now: date)
        let cappedOutcome = await capped.runNow(now: date)
        XCTAssertEqual(cappedOutcome, .paused("Paused: 1 runs today, the daily cap"))
        XCTAssertEqual(capped.triaging, 0)
        XCTAssertFalse(called.value)
    }
}

private final class CallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func set() { lock.lock(); raised = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return raised }
}
