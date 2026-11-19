import XCTest
@testable import BurroCore

final class OrchestratorCompositionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSentenceIsTheSummaryLineWithNeedsYouInAmber() {
        let last = now.addingTimeInterval(-180)
        let runs = OrchestratorComposition.sentence(needs: 2, finished: 3, stuck: 1, lastTriage: last, triaging: 0, now: now)
        XCTAssertEqual(runs.plainText, OrchestratorPageSummary.line(needs: 2, finished: 3, stuck: 1, lastTriage: last, triaging: 0, now: now) + ".")
        XCTAssertEqual(runs.first, TextRun("2 need you", .needsYou))
        let quiet = OrchestratorComposition.sentence(needs: 0, finished: 0, stuck: 0, lastTriage: nil, triaging: 0, now: now)
        XCTAssertEqual(quiet, [TextRun("Nothing waiting on you.")])
        XCTAssertEqual(OrchestratorComposition.sentence(needs: 1, finished: 0, stuck: 0, lastTriage: nil, triaging: 0, now: now).first?.text, "1 needs you")
    }

    private func budget(runs: Int = 9, enabled: Bool = true, session: Double? = 62) -> OrchestratorBudget {
        OrchestratorBudget(runsToday: runs, cap: 150, costToday: 0.42,
                           session: session.map { .init(title: "Claude session limit", remaining: $0, floor: 15, resetsAt: nil) },
                           weekly: nil, enabled: enabled, pausedReason: nil)
    }

    func testStatsFromWhatThePageShows() {
        let stats = OrchestratorComposition.stats(needs: 2, oldestNeed: now.addingTimeInterval(-240), finished: 3, stuck: 1,
                                                  budget: budget(), gate: .open, now: now)
        XCTAssertEqual(stats.map(\.id), ["needs", "finished", "stuck", "triage"])
        XCTAssertEqual(stats[0].value, "2")
        XCTAssertTrue(stats[0].dot)
        XCTAssertEqual(stats[0].sub.plainText, "oldest 4 min ago")
        XCTAssertEqual(stats[1].sub.plainText, "results to read")
        XCTAssertEqual(stats[2].sub, [TextRun("no new output", .stuck)])
        XCTAssertEqual(stats[3].value, "9 of 150")
        XCTAssertEqual(stats[3].sub.plainText, "$0.42 today")
        XCTAssertEqual(stats[3].footnote, "session 62% left")
    }

    func testEmptyPausedAndOffTriage() {
        let empty = OrchestratorComposition.stats(needs: 0, oldestNeed: nil, finished: 0, stuck: 0, budget: budget(runs: 0, session: nil),
                                                  gate: .open, now: now)
        XCTAssertFalse(empty[0].dot)
        XCTAssertEqual(empty.map { $0.sub.plainText }, ["nothing waiting", "nothing new", "none stuck", "$0.42 today"])
        XCTAssertNil(empty[3].footnote)

        let paused = OrchestratorComposition.stats(needs: 0, oldestNeed: nil, finished: 0, stuck: 0, budget: budget(runs: 150),
                                                   gate: .dailyCap(150), now: now)[3]
        XCTAssertEqual(paused.sub, [TextRun("paused at the daily cap", .needsYou)])
        XCTAssertEqual(paused.footnote, "$0.42 today")
        XCTAssertTrue(paused.help.hasPrefix("Paused: 150 runs today, the daily cap."))

        let off = OrchestratorComposition.stats(needs: 0, oldestNeed: nil, finished: 0, stuck: 0, budget: budget(enabled: false),
                                                gate: .off, now: now)[3]
        XCTAssertEqual(off.sub, [TextRun("automatic triage off", .stuck)])
    }
}
