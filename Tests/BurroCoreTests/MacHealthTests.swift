// Mac Health levels and leftover rules use synthetic processes; stopping is checked against a real child process.
import XCTest
@testable import BurroCore

final class MacHealthTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let home = "/Users/tester"
    let gigabyte: UInt64 = 1 << 30

    func testLevelsFollowPressureSwapStorageAndLoad() {
        var snapshot = health(pressure: .normal, swapUsed: 0, swapTotal: 0, available: 500 * gigabyte, load: 4)
        XCTAssertEqual(snapshot.level, .normal)
        snapshot.memory?.pressure = .warning
        XCTAssertEqual(snapshot.memoryLevel, .elevated)
        snapshot.memory?.pressure = .critical
        XCTAssertEqual(snapshot.memoryLevel, .critical)

        let nearlyFullSwap = health(pressure: .normal, swapUsed: 18 * gigabyte, swapTotal: 19 * gigabyte, available: 500 * gigabyte, load: 4)
        XCTAssertEqual(nearlyFullSwap.swapLevel, .elevated)
        XCTAssertEqual(nearlyFullSwap.memoryLevel, .elevated, "Nearly full swap counts as memory pressure")
        XCTAssertEqual(health(pressure: .normal, swapUsed: 1 * gigabyte, swapTotal: 1 * gigabyte, available: 500 * gigabyte, load: 4).swapLevel,
                       .normal, "A small swap file can be full without pressure")

        XCTAssertEqual(health(pressure: .normal, swapUsed: 0, swapTotal: 0, available: 8 * gigabyte, load: 4).storageLevel, .critical)
        XCTAssertEqual(health(pressure: .normal, swapUsed: 0, swapTotal: 0, available: 200 * gigabyte, load: 4).storageLevel, .elevated)
        XCTAssertEqual(health(pressure: .normal, swapUsed: 0, swapTotal: 0, available: 500 * gigabyte, load: 18).cpuLevel, .elevated)
        XCTAssertEqual(health(pressure: .normal, swapUsed: 0, swapTotal: 0, available: 500 * gigabyte, load: 41).cpuLevel, .critical)
    }

    func testRestartIsSuggestedOnlyForLongUptimeWithHeavySwap() {
        var snapshot = health(pressure: .normal, swapUsed: 9 * gigabyte, swapTotal: 10 * gigabyte, available: 500 * gigabyte, load: 4)
        snapshot.bootedAt = now.addingTimeInterval(-23 * 86400)
        XCTAssertTrue(snapshot.restartSuggested(now: now))
        snapshot.bootedAt = now.addingTimeInterval(-2 * 86400)
        XCTAssertFalse(snapshot.restartSuggested(now: now))
    }

    func testCPUBusyUsesTickDeltas() {
        XCTAssertEqual(MacHealthSampler.busy(from: CPUTicks(busy: 100, total: 400), to: CPUTicks(busy: 400, total: 1000)), 0.5)
        XCTAssertNil(MacHealthSampler.busy(from: nil, to: CPUTicks(busy: 1, total: 2)))
        XCTAssertNil(MacHealthSampler.busy(from: CPUTicks(busy: 5, total: 10), to: CPUTicks(busy: 5, total: 10)))
    }

    func testOrphanedHomebrewPythonStillBurningCPUIsFlaggedAsBusy() {
        // Homebrew Python lives inside Python.app but is a command-line tool, not an app someone has open.
        let python = process(89317, parent: 1, age: 6 * 86400,
            executable: "/opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python",
            arguments: ["/opt/homebrew/.../Python", "-"], cwd: "\(home)/Dev/app-worktrees/virality-day", cpuTime: 99 * 3600, resident: 1_400_000_000)
        let report = LeftoverPolicy.report(ProcessInventory(processes: [python], sampledAt: now), cpu: [python.id: 80], now: now, home: home)
        XCTAssertEqual(report.leftovers.map(\.kind), [.runaway])
        XCTAssertEqual(report.leftovers.first?.name, "Python · stdin script")
        XCTAssertEqual(report.leftovers.first?.folder, "~/Dev/app-worktrees/virality-day")
        XCTAssertEqual(report.leftovers.first?.pid, 89317)

        let quiet = LeftoverPolicy.report(ProcessInventory(processes: [python], sampledAt: now), cpu: [python.id: 0], now: now, home: home)
        XCTAssertEqual(quiet.leftovers.map(\.kind), [.orphan], "An idle orphan is still reported, just not as busy")
    }

    func testAppsSystemServicesAgentsAndRecentOrphansAreNotLeftovers() {
        let processes = [
            process(10, parent: 1, age: 9 * 86400, executable: "/Applications/Notion.app/Contents/MacOS/Notion"),
            process(11, parent: 1, age: 9 * 86400, executable: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"),
            process(12, parent: 1, age: 9 * 86400, executable: "/usr/libexec/rapportd"),
            process(13, parent: 1, age: 9 * 86400, executable: "/opt/homebrew/bin/watchman", arguments: ["watchman", "--foreground"]),
            process(14, parent: 1, age: 9 * 86400, executable: "\(home)/Library/Application Support/Claude/claude-code/2.1/x/claude.app/Contents/MacOS/claude",
                    cpuTime: 5 * 3600, resident: 400_000_000),
            process(15, parent: 1, age: 20 * 60, executable: "/usr/bin/tail", arguments: ["tail", "-n", "+1", "app.log"]),
            // Chromium relaunches from a code-sign clone outside /Applications.
            process(16, parent: 1, age: 2 * 86400, executable: "/private/var/folders/x/X/com.brave.Browser.code_sign_clone/c/Brave Browser.app.bundle/Contents/MacOS/Brave Browser"),
            // Servers spawned directly by an open app or agent session belong to it.
            process(17, parent: 20, age: 5 * 86400, executable: "\(home)/Library/Application Support/com.raycast.macos/node/bin/node",
                    arguments: ["node", "backend.js"], listening: [7265]),
            process(18, parent: 14, age: 2 * 86400, executable: "\(home)/.local/bin/codebase-memory-mcp", listening: [9749]),
            process(20, parent: 1, age: 9 * 86400, executable: "/Applications/Raycast.app/Contents/MacOS/Raycast"),
        ]
        let report = LeftoverPolicy.report(ProcessInventory(processes: processes, sampledAt: now), cpu: [processes[4].id: 40], now: now, home: home)
        XCTAssertTrue(report.leftovers.isEmpty, "\(report.leftovers.map(\.name))")
        XCTAssertEqual(report.agentProcesses, 1, "Open agent CLIs are summarized, never offered for stopping")
        XCTAssertEqual(report.agentMemory, 400_000_000)
    }

    func testIdleDevServerIsFlaggedButOneWithClientsIsNot() {
        let idle = process(73469, parent: 1, age: 38 * 3600, executable: "/opt/homebrew/bin/python3",
            arguments: ["python3", "\(home)/Dev/site/work/progress/server.py"], cwd: "\(home)/Dev/site", listening: [8769])
        var expo = process(41104, parent: 900, age: 26 * 3600, executable: "/opt/homebrew/bin/node",
            arguments: ["node", "\(home)/Dev/app/node_modules/.bin/expo", "start"], cwd: "\(home)/Dev/app", listening: [8085])
        expo.connections = 5
        var report = LeftoverPolicy.report(ProcessInventory(processes: [idle, expo], sampledAt: now), cpu: [:], now: now, home: home)
        XCTAssertEqual(report.leftovers.map(\.name), ["Python · server.py"], "A dev server with a connected app is in use")
        XCTAssertEqual(report.leftovers.map(\.kind), [.devServer])
        XCTAssertTrue(report.leftovers[0].reason.contains(":8769"))

        expo.connections = 0
        report = LeftoverPolicy.report(ProcessInventory(processes: [expo], sampledAt: now), cpu: [:], now: now, home: home)
        XCTAssertEqual(report.leftovers.map(\.kind), [.devServer], "A serving runner is judged as a server, not a watcher")
        expo.started = now.addingTimeInterval(-3 * 3600)
        report = LeftoverPolicy.report(ProcessInventory(processes: [expo], sampledAt: now), cpu: [:], now: now, home: home)
        XCTAssertTrue(report.leftovers.isEmpty, "An unused dev server gets a workday before it is reported")
    }

    func testLongTestRunnerGroupsItsWorkers() {
        let jest = process(500, parent: 400, age: 3 * 3600, executable: "/usr/local/bin/node",
            arguments: ["node", "\(home)/Dev/app/node_modules/.bin/jest", "--silent"], cwd: "\(home)/Dev/app", resident: 50_000_000)
        let workers = (0..<17).map { offset in
            process(600 + offset, parent: 500, age: 3 * 3600, executable: "/usr/local/bin/node",
                arguments: ["node", "\(home)/Dev/app/node_modules/jest-worker/build/workers/processChild.js"], resident: 300_000_000)
        }
        let report = LeftoverPolicy.report(ProcessInventory(processes: [jest] + workers, sampledAt: now), cpu: [:], now: now, home: home)
        XCTAssertEqual(report.leftovers.count, 1)
        XCTAssertEqual(report.leftovers.first?.name, "node · jest")
        XCTAssertEqual(report.leftovers.first?.children, 17)
        XCTAssertEqual(report.leftovers.first?.resident, 50_000_000 + 17 * 300_000_000)

        let fresh = LeftoverPolicy.report(ProcessInventory(processes: [process(501, parent: 400, age: 20 * 60, executable: "/usr/local/bin/node",
            arguments: ["node", "jest"])], sampledAt: now), cpu: [:], now: now, home: home)
        XCTAssertTrue(fresh.leftovers.isEmpty, "A test run that just started is in use")
    }

    func testAgentScratchScriptsAreFlaggedButShellWrappersAreNot() {
        let script = process(95618, parent: 1, age: 4 * 86400, executable: "/bin/bash",
            arguments: ["bash", "/private/tmp/claude-501/project/session/scratchpad/watch.sh"], cwd: "\(home)/Dev/app")
        let wrapper = process(95619, parent: 300, age: 8 * 3600, executable: "/bin/zsh",
            arguments: ["/bin/zsh", "-c", "source \(home)/.claude/shell-snapshots/snapshot.sh && eval 'sleep 1'"], cwd: "/private/tmp/claude-501/x")
        var report = LeftoverPolicy.report(ProcessInventory(processes: [script, wrapper], sampledAt: now), cpu: [:], now: now, home: home)
        XCTAssertEqual(report.leftovers.map(\.name), ["bash · watch.sh"])
        XCTAssertEqual(report.leftovers.map(\.kind), [.agentScript])

        report = LeftoverPolicy.report(ProcessInventory(processes: [script], sampledAt: now), cpu: [:], now: now, home: home,
            ignored: [report.leftovers[0].signature])
        XCTAssertTrue(report.leftovers.isEmpty, "Ignored tools stay hidden")
    }

    func testHeadlessSimulatorIsReportedWithNameAppsAndMemory() {
        let udid = "06C07A39-925A-4999-89EE-6A99C6A3E8C4"
        let device = "\(home)/Library/Developer/CoreSimulator/Devices/\(udid)"
        let launchd = process(86106, parent: 1, age: 20 * 3600, executable: "/Library/Developer/CoreSimulator/Volumes/iOS/RuntimeRoot/sbin/launchd_sim",
            arguments: ["launchd_sim", "\(device)/data/var/run/launchd_bootstrap.plist"], resident: 10_000_000)
        let app = process(86200, parent: 86106, age: 19 * 3600,
            executable: "\(device)/data/Containers/Bundle/Application/ABC/Maurice.app/Maurice", resident: 400_000_000)
        let daemon = process(86201, parent: 86106, age: 20 * 3600, executable: "/Library/Developer/CoreSimulator/Volumes/iOS/RuntimeRoot/usr/libexec/backboardd",
            resident: 90_000_000)
        let inventory = ProcessInventory(processes: [launchd, app, daemon], sampledAt: now)
        let report = LeftoverPolicy.report(inventory, cpu: [:], now: now, home: home, deviceName: { $0 == udid ? "iPhone 17 Pro" : nil })
        XCTAssertEqual(report.leftovers.count, 1)
        XCTAssertEqual(report.leftovers.first?.kind, .simulator)
        XCTAssertEqual(report.leftovers.first?.name, "iPhone 17 Pro")
        XCTAssertEqual(report.leftovers.first?.folder, "Running Maurice")
        XCTAssertEqual(report.leftovers.first?.resident, 500_000_000)
        XCTAssertEqual(report.leftovers.first?.target, .simulator(udid: udid))

        let window = process(700, parent: 1, age: 3600, executable: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator")
        let visible = LeftoverPolicy.report(ProcessInventory(processes: inventory.processes + [window], sampledAt: now), cpu: [:], now: now, home: home)
        XCTAssertTrue(visible.leftovers.isEmpty, "A simulator with its window open is in use")
    }

    func testLabelsNeverExposeArgumentsBeyondTheScriptName() {
        XCTAssertEqual(LeftoverPolicy.label(executable: "/usr/bin/python3", arguments: ["python3", "-u", "-c", "print('token=abc')"]), "Python · inline command")
        XCTAssertEqual(LeftoverPolicy.label(executable: "/opt/homebrew/bin/node", arguments: ["node", "--max-old-space-size=4096", "/srv/app/server.js", "--token=secret"]),
                       "node · server.js")
        XCTAssertEqual(LeftoverPolicy.label(executable: "/usr/bin/python3", arguments: ["python3", "-m", "http.server", "8000"]), "Python · http.server")
        XCTAssertEqual(LeftoverPolicy.label(executable: "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)",
                                            arguments: ["--type=renderer"]), "Claude Helper (Renderer)")
    }

    func testCPUPercentUsesTheSameProcessIdentity() {
        let started = now.addingTimeInterval(-600)
        let before = ProcessInventory(processes: [ProcessSample(pid: 7, parentPID: 1, started: started, executable: "/bin/x", cpuTime: 10)], sampledAt: now)
        let after = ProcessInventory(processes: [ProcessSample(pid: 7, parentPID: 1, started: started, executable: "/bin/x", cpuTime: 13),
                                                 ProcessSample(pid: 8, parentPID: 1, started: started, executable: "/bin/y", cpuTime: 50)],
                                     sampledAt: now.addingTimeInterval(4))
        XCTAssertEqual(after.cpuPercent(since: before), ["7@\(Int(started.timeIntervalSince1970))": 75])
    }

    func testLiveSampleAndInventoryAreReadable() {
        let (snapshot, ticks) = MacHealthSampler.sample(previous: nil)
        XCTAssertGreaterThan(snapshot.cores, 0)
        XCTAssertNotNil(ticks)
        XCTAssertGreaterThan(snapshot.memory?.total ?? 0, 0)
        XCTAssertGreaterThan(snapshot.storage?.total ?? 0, 0)
        let inventory = ProcessInventory.read()
        XCTAssertTrue(inventory.complete)
        XCTAssertFalse(inventory.processes.contains { $0.pid == Int(getpid()) }, "Burro never reports itself")
    }

    func testRoutineSamplesSkipTheCostlyReads() {
        let (snapshot, _) = MacHealthSampler.sample(previous: nil, storage: false)
        XCTAssertNil(snapshot.storage, "Purgeable-space accounting runs on its own slower clock")
        XCTAssertGreaterThan(snapshot.memory?.total ?? 0, 0)
        let apps = ProcessInventory.read().processes.filter { LeftoverPolicy.isApp($0.executable) }
        XCTAssertFalse(apps.isEmpty)
        XCTAssertTrue(apps.allSatisfy { $0.arguments.isEmpty }, "App arguments are never needed, so they are never read")
        XCTAssertEqual(LeftoverPolicy.baseName("/opt/homebrew/bin/node"), "node")
        XCTAssertEqual(LeftoverPolicy.baseName("node"), "node")
    }

    func testStopSignalsOnlyTheSameProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let pid = Int(child.processIdentifier)
        var info = LeftoverActions.identity(of: pid)
        for _ in 0..<50 where info?.executable != "/bin/sleep" { Thread.sleep(forTimeInterval: 0.02); info = LeftoverActions.identity(of: pid) }
        let (started, executable) = try XCTUnwrap(info)
        XCTAssertEqual(executable, "/bin/sleep")
        XCTAssertEqual(LeftoverActions.stop(pid: pid, started: started.addingTimeInterval(-5), executable: executable, force: false), .changed)
        XCTAssertTrue(child.isRunning, "A different start time must not be signaled")
        XCTAssertEqual(LeftoverActions.stop(pid: pid, started: started, executable: "/bin/other", force: false), .changed)
        XCTAssertEqual(LeftoverActions.stop(pid: pid, started: started, executable: executable, force: false), .done)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(LeftoverActions.stop(pid: Int(getpid()), started: started, executable: executable, force: false),
                       .failed("Burro cannot stop this process."))
        XCTAssertEqual(LeftoverActions.shutdownSimulator("not-a-udid; rm -rf /"), .failed("Invalid simulator identifier."))
    }

    private func health(pressure: MacHealthSnapshot.Pressure, swapUsed: UInt64, swapTotal: UInt64, available: UInt64, load: Double) -> MacHealthSnapshot {
        MacHealthSnapshot(sampledAt: now, cores: 18, load: [load, load, load], cpuBusy: 0.2,
            memory: .init(total: 48 * gigabyte, app: 20 * gigabyte, wired: 6 * gigabyte, compressed: 2 * gigabyte, cached: 10 * gigabyte,
                          free: 10 * gigabyte, swapTotal: swapTotal, swapUsed: swapUsed, pressure: pressure),
            storage: .init(total: 2000 * gigabyte, available: available), thermal: .nominal, bootedAt: now.addingTimeInterval(-86400))
    }
    private func process(_ pid: Int, parent: Int, age: TimeInterval, executable: String, arguments: [String] = [], cwd: String = "",
                         cpuTime: TimeInterval? = 1, resident: UInt64? = 10_000_000, listening: [Int] = []) -> ProcessSample {
        ProcessSample(pid: pid, parentPID: parent, started: now.addingTimeInterval(-age), executable: executable,
                      arguments: arguments.isEmpty ? [executable] : arguments, cwd: cwd, cpuTime: cpuTime, resident: resident, listeningPorts: listening)
    }
}
