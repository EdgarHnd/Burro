// Mac Health's verdict thresholds, headline sentence, bounded history, agent attribution and Keep awake segment,
// all on synthetic values; nothing reads the system.
import XCTest
@testable import BurroCore

final class MacHealthVitalsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let gigabyte: UInt64 = 1 << 30
    let bytes: (UInt64) -> String = { "\((Double($0) / Double(1 << 30) * 10).rounded() / 10) GB" }

    private func memory(used: UInt64, total: UInt64 = 36 << 30, swap: UInt64 = 0, pressure: MacHealthSnapshot.Pressure = .normal) -> MacHealthSnapshot.Memory {
        MacHealthSnapshot.Memory(total: total, app: used, wired: 0, compressed: 0, cached: 0, free: total - used,
                                 swapTotal: max(swap, 1 << 30), swapUsed: swap, pressure: pressure)
    }
    private func snapshot(busy: Double? = 0.2, load: Double = 2, cores: Int = 12, used: UInt64 = 18 << 30, swap: UInt64 = 0,
                          pressure: MacHealthSnapshot.Pressure = .normal, free: UInt64 = 500 << 30, thermal: MacHealthSnapshot.Thermal = .nominal,
                          at: Date? = nil) -> MacHealthSnapshot {
        MacHealthSnapshot(sampledAt: at ?? now, cores: cores, load: [load, load, load], cpuBusy: busy,
                          memory: memory(used: used, swap: swap, pressure: pressure),
                          storage: .init(total: 1000 << 30, available: free), thermal: thermal, bootedAt: now.addingTimeInterval(-86400))
    }

    // MARK: Verdicts

    func testCPUVerdictUsesBusyFractionAndLoadPerCore() {
        XCTAssertEqual(MacHealthVerdicts.cpu(busy: 0.38, load: 4, cores: 12), .fine)
        XCTAssertEqual(MacHealthVerdicts.cpu(busy: 0.6, load: 4, cores: 12), .moderate)
        XCTAssertEqual(MacHealthVerdicts.cpu(busy: 0.2, load: 11, cores: 12), .moderate, "Load near the core count is busy even between spikes")
        XCTAssertEqual(MacHealthVerdicts.cpu(busy: 0.9, load: 4, cores: 12), .high)
        XCTAssertEqual(MacHealthVerdicts.cpu(busy: nil, load: 18, cores: 12), .high)
        XCTAssertNil(MacHealthVerdicts.cpu(busy: nil, load: nil, cores: 12))
        XCTAssertEqual(VitalVerdict.moderate.word(for: .cpu), "Busy")
    }

    func testMemoryVerdictFollowsKernelPressureThenHowMuchIsUsed() {
        XCTAssertEqual(MacHealthVerdicts.memory(memory(used: 20 * gigabyte)), .fine)
        XCTAssertEqual(MacHealthVerdicts.memory(memory(used: 29 * gigabyte)), .moderate, "80% used with normal pressure")
        XCTAssertEqual(MacHealthVerdicts.memory(memory(used: 20 * gigabyte, pressure: .warning)), .high)
        XCTAssertEqual(MacHealthVerdicts.memory(memory(used: 20 * gigabyte, pressure: .critical)), .critical)
        XCTAssertNil(MacHealthVerdicts.memory(nil))
        XCTAssertEqual(VitalVerdict.moderate.word(for: .memory), "Moderate")
    }

    func testSwapVerdictThresholdsAreOneAndFourGigabytes() {
        XCTAssertEqual(MacHealthVerdicts.swap(memory(used: 1, swap: 0)), .fine)
        XCTAssertEqual(MacHealthVerdicts.swap(memory(used: 1, swap: gigabyte - 1)), .fine)
        XCTAssertEqual(MacHealthVerdicts.swap(memory(used: 1, swap: gigabyte)), .moderate)
        XCTAssertEqual(MacHealthVerdicts.swap(memory(used: 1, swap: 4 * gigabyte)), .high)
        XCTAssertEqual(VitalVerdict.high.word(for: .swap), "High")
    }

    func testDiskVerdictFollowsFreeSpace() {
        func disk(_ free: UInt64, of total: UInt64 = 1000 << 30) -> VitalVerdict? { MacHealthVerdicts.disk(.init(total: total, available: free)) }
        XCTAssertEqual(disk(400 * gigabyte), .fine)
        XCTAssertEqual(disk(200 * gigabyte), .moderate)
        XCTAssertEqual(disk(100 * gigabyte), .high)
        XCTAssertEqual(disk(40 * gigabyte), .critical, "Under 5%")
        XCTAssertEqual(disk(9 * gigabyte, of: 100 << 30), .critical, "Under 10 GB even on a small disk")
        XCTAssertNil(MacHealthVerdicts.disk(.init(total: 0, available: 0)))
        XCTAssertEqual(VitalVerdict.high.word(for: .disk), "Low")
        XCTAssertEqual(VitalVerdict.moderate.word(for: .disk), "Filling up")
    }

    // MARK: Headline

    func testHeadlineIsHealthyWithLeftoversAndNamesHighSwapWithoutBlamingIt() {
        let headline = MacHealthHeadline.make(snapshot: snapshot(swap: 6 * gigabyte), leftovers: 5, leftoverMemory: 3 * gigabyte + gigabyte / 2,
                                              leftoversKnown: true, bytes: bytes)
        XCTAssertEqual(headline.title, "Healthy, with 5 things left running")
        XCTAssertEqual(headline.detail, "Swap is high at 6.0 GB; stopping them frees about 3.5 GB.")
    }

    func testHeadlineWhenAllIsCalm() {
        let calm = MacHealthHeadline.make(snapshot: snapshot(), leftovers: 0, leftoverMemory: 0, leftoversKnown: true, bytes: bytes)
        XCTAssertEqual(calm, MacHealthHeadline(title: "Healthy", detail: "CPU, memory and disk are fine; nothing is left running."))
        let one = MacHealthHeadline.make(snapshot: snapshot(), leftovers: 1, leftoverMemory: gigabyte, leftoversKnown: true, bytes: bytes)
        XCTAssertEqual(one.title, "Healthy, with 1 thing left running")
        XCTAssertEqual(one.detail, "CPU, memory and disk are fine; stopping it frees about 1.0 GB.")
        let scanning = MacHealthHeadline.make(snapshot: snapshot(busy: 0.7), leftovers: 0, leftoverMemory: 0, leftoversKnown: false, bytes: bytes)
        XCTAssertEqual(scanning.detail, "Nothing is under strain.", "Busy is not a problem, and an unfinished scan claims nothing")
        XCTAssertEqual(MacHealthHeadline.make(snapshot: nil, leftovers: 0, leftoverMemory: 0, leftoversKnown: false, bytes: bytes).title, "Checking this Mac…")
    }

    func testHeadlineEscalatesForPressureDiskAndHeat() {
        let pressure = MacHealthHeadline.make(snapshot: snapshot(pressure: .warning), leftovers: 0, leftoverMemory: 0, leftoversKnown: true, bytes: bytes)
        XCTAssertEqual(pressure.title, "Under pressure")
        XCTAssertEqual(pressure.detail, "Memory pressure is high; nothing is left running.")
        let disk = MacHealthHeadline.make(snapshot: snapshot(free: 8 * gigabyte), leftovers: 0, leftoverMemory: 0, leftoversKnown: true, bytes: bytes)
        XCTAssertEqual(disk.title, "Needs attention")
        XCTAssertEqual(disk.detail, "The startup disk has only 8.0 GB free; nothing is left running.")
        let hot = MacHealthHeadline.make(snapshot: snapshot(thermal: .serious), leftovers: 0, leftoverMemory: 0, leftoversKnown: false, bytes: bytes)
        XCTAssertEqual(hot, MacHealthHeadline(title: "Under pressure", detail: "It is running hot, so macOS may slow it down."))
        let swapOnly = MacHealthHeadline.make(snapshot: snapshot(swap: 9 * gigabyte), leftovers: 0, leftoverMemory: 0, leftoversKnown: true, bytes: bytes)
        XCTAssertEqual(swapOnly.title, "Healthy", "Swap alone never changes the title")
    }

    func testHeadlineSuggestsARestartAfterLongUptimeWithHeavySwap() {
        var value = snapshot(swap: 9 * gigabyte)
        value.bootedAt = now.addingTimeInterval(-20 * 86400)
        let headline = MacHealthHeadline.make(snapshot: value, leftovers: 0, leftoverMemory: 0, leftoversKnown: true, bytes: bytes)
        XCTAssertTrue(headline.detail.hasSuffix(" Up 20 days; a restart clears swap and stale memory."), headline.detail)
    }

    // MARK: History

    func testHistoryIsABoundedRingThatKeepsTheNewestInOrder() {
        var history = MacHealthHistory(capacity: 4, window: 3600)
        XCTAssertTrue(history.isEmpty)
        for index in 0..<10 { history.append(MacHealthPoint(at: now.addingTimeInterval(Double(index) * 5), cpu: Double(index) / 10)) }
        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(history.points.compactMap(\.cpu), [0.6, 0.7, 0.8, 0.9])
        XCTAssertEqual(history.last?.cpu, 0.9)
        XCTAssertEqual(history.span, 15)
    }

    func testHistoryDropsPointsOlderThanItsWindowAndRestartsWhenTheClockGoesBack() {
        var history = MacHealthHistory(capacity: 100, window: 600)
        history.append(MacHealthPoint(at: now, cpu: 0.1))
        history.append(MacHealthPoint(at: now.addingTimeInterval(60), cpu: 0.2))
        history.append(MacHealthPoint(at: now.addingTimeInterval(3600), cpu: 0.3))
        XCTAssertEqual(history.points.compactMap(\.cpu), [0.3], "A long pause doesn't stretch the chart")
        history.append(MacHealthPoint(at: now, cpu: 0.4))
        XCTAssertEqual(history.points.compactMap(\.cpu), [0.4])
        history.removeAll()
        XCTAssertTrue(history.isEmpty)
    }

    func testHistoryBarsAverageIntoGroups() {
        var history = MacHealthHistory(capacity: 10)
        for index in 0..<8 { history.append(MacHealthPoint(at: now.addingTimeInterval(Double(index)), cpu: index < 4 ? 0.2 : 0.6)) }
        let bars = history.bars(.cpu, count: 2).compactMap { $0 }
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars[0], 0.2, accuracy: 1e-9)
        XCTAssertEqual(bars[1], 0.6, accuracy: 1e-9)
        XCTAssertEqual(history.bars(.cpu, count: 20).count, 8, "Fewer points than bars draws one bar per point")
        XCTAssertEqual(history.bars(.disk, count: 4), [nil, nil, nil, nil])
        XCTAssertEqual(MacHealthHistory().bars(.cpu, count: 4), [])
    }

    func testPointValuesAreFractionsExceptSwap() {
        let point = MacHealthPoint(snapshot(used: 18 << 30, swap: 2 << 30, free: 250 << 30))
        XCTAssertEqual(point.value(.memory), 0.5)
        XCTAssertEqual(point.value(.disk), 0.75)
        XCTAssertEqual(point.value(.swap), Double(2 * gigabyte))
        XCTAssertEqual(point.value(.cpu), 0.2)
    }

    func testCaptionsSayHowFarBackAndWhatChanged() {
        var history = MacHealthHistory()
        XCTAssertEqual(history.caption(.cpu, bytes: bytes), "Measuring")
        for (index, value) in [0.3, 0.7, 0.4, 0.38].enumerated() {
            history.append(MacHealthPoint(at: now.addingTimeInterval(Double(index) * 240), cpu: value, memoryUsed: 27 * gigabyte + UInt64(index) * gigabyte,
                                          memoryTotal: 36 * gigabyte, swapUsed: index == 3 ? 6 * gigabyte : gigabyte, diskFree: 212 * gigabyte, diskTotal: 1000 << 30))
        }
        XCTAssertEqual(history.caption(.cpu, bytes: bytes), "last 12 min · peak 70%")
        XCTAssertEqual(history.caption(.memory, bytes: bytes), "last 12 min · was 27.0 GB")
        XCTAssertEqual(history.caption(.swap, bytes: bytes), "last 12 min · was 1.0 GB")
        XCTAssertEqual(history.caption(.disk, bytes: bytes), "last 12 min · steady")

        var steady = MacHealthHistory(capacity: 1000, window: 3600)
        for index in 0...720 { steady.append(MacHealthPoint(at: now.addingTimeInterval(Double(index) * 5), cpu: 0.2)) }
        XCTAssertEqual(steady.caption(.cpu, bytes: bytes), "last hour · steady")
    }

    // MARK: Agents

    private func process(_ pid: Int, parent: Int, _ executable: String, arguments: [String] = [], cwd: String = "/Users/t/Dev/app", memory: UInt64 = 100 << 20) -> ProcessSample {
        ProcessSample(pid: pid, parentPID: parent, started: now.addingTimeInterval(-3600), executable: executable,
                      arguments: arguments.isEmpty ? [executable] : arguments, cwd: cwd, cpuTime: 10, memory: memory)
    }

    func testAgentProcessesAreTheChatsVerifiedProcessAndEverythingUnderIt() {
        let claude = process(100, parent: 50, "/Users/t/.local/share/claude/versions/2.1.0", memory: 300 << 20)
        let shell = process(101, parent: 100, "/bin/zsh", arguments: ["/bin/zsh", "-c", "xcodebuild test"])
        let xcodebuild = process(102, parent: 101, "/usr/bin/xcodebuild", memory: 3 << 30)
        let other = process(200, parent: 1, "/opt/homebrew/bin/node", arguments: ["node", "server.js"])
        let reused = process(300, parent: 1, "/usr/bin/python3")
        let inventory = ProcessInventory(processes: [claude, shell, xcodebuild, other, reused], sampledAt: now)
        let chats = [AgentChatRef(id: "claude:a", title: "iOS hang on resume", pid: 100),
                     AgentChatRef(id: "claude:b", title: "A reused pid", pid: 300),
                     AgentChatRef(id: "codex:c", title: "No pid", pid: nil)]
        let summary = AgentProcessAttribution.summarize(inventory, cpu: [claude.id: 6, shell.id: 0, xcodebuild.id: 142, other.id: 90], chats: chats)
        XCTAssertEqual(summary.top.map(\.id), [xcodebuild.id, claude.id, shell.id])
        XCTAssertEqual(summary.top.map(\.chat.title), Array(repeating: "iOS hang on resume", count: 3))
        XCTAssertEqual(summary.top.first?.name, "xcodebuild")
        XCTAssertEqual(summary.processes, 3)
        XCTAssertEqual(summary.cpuPercent, 148)
        XCTAssertEqual(summary.memory, (300 << 20) + (100 << 20) + (3 << 30))
        XCTAssertEqual(AgentProcessAttribution.summarize(inventory, cpu: [:], chats: [chats[1]]), .empty, "A pid that isn't an agent CLI is ignored")
        XCTAssertEqual(AgentProcessAttribution.summarize(inventory, cpu: [:], chats: chats, limit: 1).top.map(\.id), [xcodebuild.id], "Memory breaks ties")
    }

    func testALeftoverBelongsToTheChatAboveItOrWhoseTemporaryFolderItRunsIn() {
        let claude = process(100, parent: 50, "/Users/t/.local/share/claude/versions/2.1.0")
        let server = process(110, parent: 100, "/opt/homebrew/bin/node", arguments: ["node", "vite"])
        let session = "5715C5C5-B974-4961-8FDE-6A2F649F8515"
        let script = process(120, parent: 1, "/opt/homebrew/bin/python3",
                             arguments: ["python3", "/private/tmp/claude-501/-Users-t-Dev-app/\(session)/scratchpad/serve.py"], cwd: "/Users/t")
        let stray = process(130, parent: 1, "/opt/homebrew/bin/node", cwd: "/private/tmp/claude-501/-Users-t-Dev-app")
        let inventory = ProcessInventory(processes: [claude, server, script, stray], sampledAt: now)
        let live = AgentChatRef(id: "claude:live", title: "Study with friends layout", pid: 100)
        let finished = AgentChatRef(id: "claude:\(session.lowercased())", title: "Serve the mockups", pid: nil)
        func leftover(_ sample: ProcessSample) -> Leftover {
            Leftover(kind: .orphan, name: "x", folder: "", reason: "", started: sample.started, children: 0,
                     target: .process(pid: sample.pid, started: sample.started, executable: sample.executable), signature: "x")
        }
        XCTAssertEqual(AgentProcessAttribution.chat(for: leftover(server), inventory: inventory, chats: [live, finished]), live)
        XCTAssertEqual(AgentProcessAttribution.chat(for: leftover(script), inventory: inventory, chats: [live, finished]), finished)
        XCTAssertNil(AgentProcessAttribution.chat(for: leftover(stray), inventory: inventory, chats: [live, finished]), "A project folder alone names no chat")
        XCTAssertNil(AgentProcessAttribution.chat(for: leftover(script), inventory: inventory, chats: [live]), "Only chats Burro knows are linked")
        XCTAssertEqual(AgentProcessAttribution.claudeTemporarySession("/tmp/claude-501/-Users-t/\(session)/x"), session.lowercased())
        XCTAssertNil(AgentProcessAttribution.claudeTemporarySession("/Users/t/\(session)"))
    }

    // MARK: Keep awake

    func testKeepAwakeSegmentShowsWhatIsOnAndNeverMislabelsAMenuBarDuration() {
        let picked = now.addingTimeInterval(-600)
        XCTAssertEqual(KeepAwakeChoice.all.map(\.title), ["1 hour", "2 hours", "4 hours", "Until I stop", "While agents work"])
        XCTAssertNil(KeepAwakeChoice.selected(manualUntil: nil, agentsMode: false, picked: nil, pickedAt: nil, now: now))
        XCTAssertEqual(KeepAwakeChoice.selected(manualUntil: nil, agentsMode: true, picked: nil, pickedAt: nil, now: now), .agents)
        XCTAssertEqual(KeepAwakeChoice.selected(manualUntil: .distantFuture, agentsMode: true, picked: nil, pickedAt: nil, now: now), .untilStopped)
        XCTAssertEqual(KeepAwakeChoice.selected(manualUntil: picked.addingTimeInterval(7200), agentsMode: false, picked: 7200, pickedAt: picked, now: now),
                       .duration(7200))
        XCTAssertNil(KeepAwakeChoice.selected(manualUntil: now.addingTimeInterval(3600), agentsMode: true, picked: 7200, pickedAt: picked, now: now),
                     "Set elsewhere: no segment claims it")
        XCTAssertEqual(KeepAwakeChoice.selected(manualUntil: now.addingTimeInterval(-1), agentsMode: true, picked: 3600, pickedAt: picked, now: now), .agents,
                       "An expired request falls back to the standing mode")
    }
}
