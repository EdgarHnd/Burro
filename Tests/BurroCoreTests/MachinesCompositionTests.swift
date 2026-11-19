import XCTest
@testable import BurroCore

final class MachinesCompositionTests: XCTestCase {
    private typealias Machine = MachinesComposition.Machine

    func testSentenceSaysWhatTheHeadlineSaysWithNeedsYouInAmber() {
        let counts = MachinesOverview.Counts(working: 3, needYou: 2)
        let runs = MachinesComposition.sentence(reachable: 2, total: 3, counts: counts)
        XCTAssertEqual(runs.plainText, MachinesOverview.headline(reachable: 2, total: 3, counts: counts) + ".")
        XCTAssertEqual(runs.first?.tone, .strong)
        XCTAssertEqual(runs.last, TextRun("2 need you.", .needsYou))
        XCTAssertFalse(MachinesComposition.sentence(reachable: 1, total: 1, counts: .init(working: 1)).contains { $0.tone == .needsYou })
        XCTAssertEqual(MachinesComposition.sentence(reachable: 1, total: 1, counts: .init()).plainText, "This Mac only · no chats working.")
    }

    func testStatsCountReachWorkWaitingAndOutdatedTools() {
        let machines = [
            Machine(name: "This Mac", reach: .reachable, counts: .init(working: 2, needYou: 1), outdated: ["Claude Code"], versionsKnown: true),
            Machine(name: "Studio", reach: .reachable, counts: .init(working: 1, needYou: 1), outdated: ["Codex"], versionsKnown: true),
            Machine(name: "Build Mini", reach: .unreachable),
            Machine(name: "Old box", reach: .paused),
        ]
        XCTAssertTrue(MachinesComposition.reach(machines) == (2, 3))
        let stats = MachinesComposition.stats(machines)
        XCTAssertEqual(stats.map(\.id), ["reachable", "working", "waiting", "tools"])
        XCTAssertEqual(stats[0].value, "2 of 3")
        XCTAssertEqual(stats[0].sub, [TextRun("Build Mini unreachable", .stuck)])
        XCTAssertEqual(stats[1].value, "3")
        XCTAssertEqual(stats[1].sub.plainText, "on This Mac and Studio")
        XCTAssertEqual(stats[2].value, "2")
        XCTAssertTrue(stats[2].dot)
        XCTAssertEqual(stats[3].value, "2")
        XCTAssertEqual(stats[3].sub.plainText, "on This Mac and Studio")
    }

    func testQuietStatesNeverClaimWhatWasNotRead() {
        let fresh = MachinesComposition.stats([Machine(name: "This Mac", reach: .reachable, probing: true)])
        XCTAssertEqual(fresh[0].value, "1")
        XCTAssertEqual(fresh[0].sub.plainText, "this Mac only")
        XCTAssertEqual(fresh[1].sub.plainText, "nothing running")
        XCTAssertFalse(fresh[2].dot)
        XCTAssertEqual(fresh[2].sub.plainText, "nothing waiting")
        XCTAssertEqual(fresh[3].value, "—")
        XCTAssertEqual(fresh[3].sub.plainText, "checking versions…")

        let read = MachinesComposition.stats([Machine(name: "This Mac", reach: .reachable, versionsKnown: true),
                                              Machine(name: "Studio", reach: .checking)])
        XCTAssertEqual(read[0].value, "1 of 2")
        XCTAssertEqual(read[0].sub.plainText, "1 checking…")
        XCTAssertEqual(read[3].value, "0")
        XCTAssertEqual(read[3].sub.plainText, "all up to date")
    }

    func testManyNamesCollapseToACount() {
        XCTAssertEqual(MachinesComposition.names(["A", "B", "C"]), "A, B and C")
        XCTAssertEqual(MachinesComposition.names(["A", "B", "C", "D"]), "4 machines")
    }
}
