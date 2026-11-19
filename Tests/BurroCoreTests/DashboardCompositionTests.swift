// Worktrees' and Usage's dashboard rules: header sentences and strip cells on synthetic values, with
// a fixed calendar (UTC, a 24-hour English locale) and stubbed money and token formatters, so CI's locale and
// time zone don't matter.
import XCTest
@testable import BurroCore

final class DashboardCompositionTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }
    /// Monday 16 Nov 2026, 09:20 UTC.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 9, minute: 20))! }
    private let cost: (Double) -> String = { "$\(Int($0.rounded()))" }
    private let tokens: (Double) -> String = { "\(($0 / 1e5).rounded() / 10)M" }

    // MARK: Worktrees

    func testWorktreeSentenceFoldsInWhereAndWhen() {
        XCTAssertEqual(WorktreeComposition.scanned(didScan: true, scanning: false, scannedAt: now.addingTimeInterval(-120), now: now, calendar: calendar),
                       "This Mac · scanned 2 min ago")
        XCTAssertEqual(WorktreeComposition.scanned(didScan: true, scanning: false, scannedAt: now, now: now, calendar: calendar), "This Mac · scanned just now")
        XCTAssertEqual(WorktreeComposition.scanned(didScan: false, scanning: true, scannedAt: now, now: now, calendar: calendar), "This Mac · scanning…")
        let runs = WorktreeComposition.sentence(scanned: "This Mac · scanned 2 min ago")
        XCTAssertEqual(runs.plainText, WorktreeComposition.promise + " This Mac · scanned 2 min ago.")
        XCTAssertEqual(runs.last?.tone, .stuck)
    }

    func testWorktreeStripCells() {
        let summary = WorktreeBoardSummary(total: 21, inUse: 3, safe: 13, uncommitted: 6, reclaimable: 5_800_000_000)
        let cells = WorktreeComposition.stats(summary, idleUncommitted: 4)
        XCTAssertEqual(cells.map(\.label), ["Worktrees", "Safe to clean", "Reclaimable", "Uncommitted work"])
        XCTAssertEqual(cells.map(\.value), ["21", "13", "5.8 GB", "6"])
        XCTAssertEqual(cells.map(\.sub.plainText), ["3 in use", "branches are kept", "freed by emptying the Trash", "4 not in use"])
        XCTAssertEqual(cells.map(\.warning), [false, false, false, true])
    }

    func testReclaimableWaitsForMeasurementAndNothingIsEmpty() {
        let measuring = WorktreeComposition.stats(WorktreeBoardSummary(total: 5, inUse: 0, safe: 2, uncommitted: 0, reclaimable: nil), idleUncommitted: 0)
        XCTAssertEqual(measuring[2].value, "—")
        XCTAssertEqual(measuring[2].sub.plainText, "measuring the safe folders…")
        XCTAssertEqual(measuring[3].sub.plainText, "everything committed")
        XCTAssertFalse(measuring[3].warning)
        let none = WorktreeComposition.stats(WorktreeBoardSummary(total: 0, inUse: 0, safe: 0, uncommitted: 0, reclaimable: 0), idleUncommitted: 0)
        XCTAssertEqual(none.count, 4)
        XCTAssertTrue(none.allSatisfy { !$0.value.isEmpty && !$0.sub.isEmpty })
        XCTAssertEqual(none[2].sub.plainText, "nothing safe to clean")
    }

    // MARK: Usage

    private func window(_ id: String, _ title: String, left: Double?, resetIn: TimeInterval?, duration: TimeInterval?, model: String? = nil) -> UsageWindow {
        UsageWindow(id: id, title: title, remainingPercent: left, resetsAt: resetIn.map { now.addingTimeInterval($0) }, duration: duration, model: model)
    }
    private var providers: [ProviderUsage] {
        let hour: TimeInterval = 3600, day: TimeInterval = 86400
        return [
            ProviderUsage(id: .codex, updatedAt: now.addingTimeInterval(-60), windows: [
                window("codex:primary", "5 hours", left: 72, resetIn: 3 * hour, duration: 5 * hour),
                window("codex:secondary", "Weekly", left: 80, resetIn: 4 * day, duration: 7 * day)]),
            ProviderUsage(id: .claude, updatedAt: now.addingTimeInterval(-60), windows: [
                window("session", "Session", left: 58, resetIn: 2 * hour, duration: 5 * hour),
                window("weekly-model:fable", "Fable weekly", left: 6, resetIn: 3 * day, duration: 7 * day, model: "Fable")]),
        ]
    }
    private var week: UsageWeek {
        let days = (0..<7).map { UsageWeek.Day(date: now.addingTimeInterval(Double($0 - 6) * 86400), tokens: 7.6e6, apiValue: 70) }
        return UsageWeek(days: days, todayModels: [], records: 10, pricedRecords: 10, partial: false, scannedAt: now)
    }

    func testUsageStripTakesEachProvidersTightestWindowThenAPIValue() {
        let cells = UsageComposition.stats(providers: providers, enabled: true, modelLimits: true, pace: true, week: week, scanning: false,
                                           now: now, calendar: calendar, cost: cost, tokens: tokens)
        XCTAssertEqual(cells.map(\.label), ["Codex 5 hours", "Claude Fable weekly", "API value today"])
        XCTAssertEqual(cells.map(\.value), ["72%", "6%", "$70"])
        XCTAssertEqual(cells[0].sub.plainText, "resets in 3h 00m")
        XCTAssertEqual(cells[1].sub.first?.tone, .needsYou, "Low and running out before its reset")
        XCTAssertTrue(cells[1].sub.plainText.hasPrefix("runs out ~today "))
        XCTAssertTrue(cells[1].help.contains("At this pace: runs out"))
        XCTAssertEqual(cells[2].sub.plainText, "7.6M tokens on this Mac")
        XCTAssertFalse(cells.contains { $0.label.contains("Spent") })
    }

    func testUsageStripRespectsModelLimitsAndAddsASecondWindowForOneProvider() {
        let withoutModels = UsageComposition.stats(providers: providers, enabled: true, modelLimits: false, pace: true, week: week, scanning: false,
                                                   now: now, calendar: calendar, cost: cost, tokens: tokens)
        XCTAssertEqual(withoutModels[1].label, "Claude session")
        let single = UsageComposition.stats(providers: [providers[0]], enabled: true, modelLimits: true, pace: true, week: week, scanning: false,
                                            now: now, calendar: calendar, cost: cost, tokens: tokens)
        XCTAssertEqual(single.map(\.label), ["Codex 5 hours", "Codex weekly", "API value today"])
    }

    func testUsageRunsOutAndProblemStates() {
        var hot = providers[0]
        hot.windows = [window("codex:secondary", "Weekly", left: 20, resetIn: 5 * 86400, duration: 7 * 86400)]
        let signedOut = ProviderUsage.failure(.claude, .signInRequired)
        var stale = ProviderUsage(id: .grok, updatedAt: now.addingTimeInterval(-40 * 60), windows: [window("grok", "Credits", left: 52, resetIn: nil, duration: nil)])
        stale.identity = nil
        let cells = UsageComposition.stats(providers: [hot, signedOut, stale], enabled: true, modelLimits: true, pace: true, week: nil, scanning: true,
                                           now: now, calendar: calendar, cost: cost, tokens: tokens)
        XCTAssertEqual(cells.count, 4)
        XCTAssertTrue(cells[0].sub.plainText.hasPrefix("runs out ~"))
        XCTAssertEqual(cells[1].value, "—")
        XCTAssertEqual(cells[1].sub.plainText, "sign-in needs attention")
        XCTAssertEqual(cells[2].sub, [TextRun("last seen 40m ago", .stuck)])
        XCTAssertEqual(cells[3].value, "—")
        XCTAssertEqual(cells[3].sub.plainText, "reading this Mac's logs…")

        let noPace = UsageComposition.stats(providers: [hot], enabled: true, modelLimits: true, pace: false, week: week, scanning: false,
                                            now: now, calendar: calendar, cost: cost, tokens: tokens)
        XCTAssertEqual(noPace[0].sub.plainText, "resets Sat 09:20")
    }

    func testUsageOffOrPausedStillFillsThreeCells() {
        let off = UsageComposition.stats(providers: [], enabled: false, modelLimits: true, pace: true, week: nil, scanning: false,
                                         now: now, calendar: calendar, cost: cost, tokens: tokens)
        XCTAssertEqual(off.map(\.label), ["Limits", "API value today", "Last 7 days"])
        XCTAssertEqual(off[0].sub.plainText, "usage is paused")
        var unpriced = week
        unpriced.pricedRecords = 0
        let paused = UsageComposition.stats(providers: [], enabled: true, modelLimits: true, pace: true, week: unpriced, scanning: false,
                                            now: now, calendar: calendar, cost: cost, tokens: tokens)
        XCTAssertEqual(paused[0].sub.plainText, "every provider is paused")
        XCTAssertEqual(paused[1].value, "—", "No priced records: no value, never a guess")
        XCTAssertEqual(paused[2].sub.plainText, "tokens on this Mac")
    }

    func testUsageSentenceLeadsWithTheLowLimitInAmber() {
        let alerts = UsageAlert.alerts(providers, now: now)
        XCTAssertEqual(alerts.map(\.title), ["Claude Fable weekly"])
        let runs = UsageComposition.sentence(alerts: alerts, providers: providers, summary: "Today on this Mac: 7.6M tokens.", now: now, calendar: calendar)
        XCTAssertEqual(runs.first, TextRun("Claude Fable weekly: 6% left, resets Thu 09:20 · 3d.", .needsYou))
        XCTAssertEqual(runs.last?.text, " Today on this Mac: 7.6M tokens.")
        XCTAssertEqual(UsageComposition.sentence(alerts: [], providers: providers, summary: "Every limit in one place.", now: now, calendar: calendar),
                       [TextRun("Every limit in one place.")])
    }
}
