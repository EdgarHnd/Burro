// Mac Health's dashboard rules: the header's toned sentence and the four strip cells, on synthetic
// snapshots with byte counts stubbed, so nothing depends on this Mac or its locale.
import XCTest
@testable import BurroCore

final class MacHealthCompositionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let gb: (UInt64) -> String = { "\($0 >> 30) GB" }

    private func snapshot(busy: Double = 0.38, used: UInt64 = 18 << 30, swap: UInt64 = 0, pressure: MacHealthSnapshot.Pressure = .normal,
                          free: UInt64 = 500 << 30) -> MacHealthSnapshot {
        let memory = MacHealthSnapshot.Memory(total: 36 << 30, app: used, wired: 0, compressed: 0, cached: 0, free: (36 << 30) - used,
                                              swapTotal: max(swap, 1 << 30), swapUsed: swap, pressure: pressure)
        return MacHealthSnapshot(sampledAt: now, cores: 12, load: [2, 2, 2], cpuBusy: busy, memory: memory,
                                 storage: .init(total: 1000 << 30, available: free), thermal: .nominal, bootedAt: now)
    }

    func testStripHasFourCellsWithVerdictAndUnit() {
        let cells = MacHealthComposition.stats(snapshot(swap: 6 << 30), bytes: gb, fileBytes: gb)
        XCTAssertEqual(cells.map(\.label), ["CPU", "Memory pressure", "Swap", "Disk"])
        XCTAssertEqual(cells.map(\.value), ["38%", "18 GB", "6 GB", "500 GB"])
        XCTAssertEqual(cells.map(\.sub.plainText), ["Fine", "Fine", "High", "Fine"])
        XCTAssertEqual(cells[2].sub.first?.tone, .needsYou, "High swap is the page's amber warning")
        XCTAssertEqual(cells.map { $0.footnote ?? "" }, ["of 12 cores", "of 36 GB used", "in use", "free of 1000 GB"])
        XCTAssertTrue(cells[0].help.contains("Load 2.0 · 2.0 · 2.0"))
    }

    func testNoSwapReadsNoneAndNothingIsEverEmpty() {
        let cells = MacHealthComposition.stats(snapshot(), bytes: gb, fileBytes: gb)
        XCTAssertEqual(cells[2].value, "None")
        let loading = MacHealthComposition.stats(nil, bytes: gb, fileBytes: gb)
        XCTAssertEqual(loading.count, 4)
        XCTAssertTrue(loading.allSatisfy { $0.unknown && $0.sub.plainText == "Measuring" })
    }

    func testCriticalStaysAmberNeverAnotherTone() {
        let cells = MacHealthComposition.stats(snapshot(pressure: .critical, free: 5 << 30), bytes: gb, fileBytes: gb)
        XCTAssertEqual(cells[1].sub, [TextRun("Critical", .needsYou)])
        XCTAssertEqual(cells[3].sub, [TextRun("Critical", .needsYou)])
    }

    func testSentenceTonesTheTitleOnlyUnderStrain() {
        let calm = MacHealthHeadline.make(snapshot: snapshot(), leftovers: 0, leftoverMemory: 0, leftoversKnown: true, bytes: gb)
        XCTAssertFalse(MacHealthComposition.strained(snapshot()))
        let runs = MacHealthComposition.sentence(calm, strained: false)
        XCTAssertEqual(runs.first, TextRun("Healthy. ", .strong))
        XCTAssertEqual(runs.plainText, "Healthy. CPU, memory and disk are fine; nothing is left running.")

        let tight = snapshot(pressure: .warning)
        XCTAssertTrue(MacHealthComposition.strained(tight))
        let headline = MacHealthHeadline.make(snapshot: tight, leftovers: 2, leftoverMemory: 2 << 30, leftoversKnown: true, bytes: gb)
        XCTAssertEqual(MacHealthComposition.sentence(headline, strained: true).first?.tone, .needsYou)
        XCTAssertEqual(MacHealthComposition.sentence(MacHealthHeadline(title: "Checking this Mac…", detail: ""), strained: false),
                       [TextRun("Checking this Mac…", .strong)])
    }
}
