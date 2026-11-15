// Keep Awake: the policy and wording, the real watchdog script against a fake pmset and sudo,
// and the store against a fake system. Nothing here changes this Mac's sleep setting.
import XCTest
@testable import Burro
@testable import BurroCore

final class KeepAwakePolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testManualRequestsAndAgentsDecideWhetherTheMacStaysAwake() {
        XCTAssertEqual(KeepAwakePolicy.decide(KeepAwakeInputs(now: now)), .off)
        XCTAssertEqual(KeepAwakePolicy.decide(KeepAwakeInputs(now: now, manualUntil: now.addingTimeInterval(-1))), .off, "An ended request does nothing")
        let manual = KeepAwakePolicy.decide(KeepAwakeInputs(now: now, manualUntil: now.addingTimeInterval(3600)))
        XCTAssertEqual(manual, KeepAwakeDecision(awake: true, lidClosed: false, reason: .manual(until: now.addingTimeInterval(3600))))
        XCTAssertEqual(KeepAwakePolicy.decide(KeepAwakeInputs(now: now, manualUntil: .distantFuture)).reason, .manual(until: nil))

        XCTAssertEqual(KeepAwakePolicy.decide(KeepAwakeInputs(now: now, workingAgents: 3)), .off, "Agents count only in agents mode")
        XCTAssertEqual(KeepAwakePolicy.decide(KeepAwakeInputs(now: now, agentsMode: true, workingAgents: 3)).reason, .agents(3))
        let lingering = KeepAwakePolicy.decide(KeepAwakeInputs(now: now, agentsMode: true, lastWorkingAt: now.addingTimeInterval(-60), linger: 300))
        XCTAssertEqual(lingering.reason, .lingering(until: now.addingTimeInterval(240)))
        XCTAssertEqual(KeepAwakePolicy.decide(KeepAwakeInputs(now: now, agentsMode: true, lastWorkingAt: now.addingTimeInterval(-301), linger: 300)), .off)
        XCTAssertEqual(KeepAwakePolicy.decide(KeepAwakeInputs(now: now, agentsMode: true, lastWorkingAt: now, linger: 0)), .off)
        XCTAssertEqual(KeepAwakePolicy.decide(KeepAwakeInputs(now: now, manualUntil: .distantFuture, agentsMode: true, workingAgents: 2)).reason,
                       .manual(until: nil), "What you asked for is shown first")
    }

    func testClosedLidNeedsThePermissionOrAnAdministratorSessionForAManualRequest() {
        XCTAssertTrue(KeepAwakePolicy.decide(KeepAwakeInputs(now: now, agentsMode: true, workingAgents: 1, passwordless: true)).lidClosed)
        XCTAssertFalse(KeepAwakePolicy.decide(KeepAwakeInputs(now: now, agentsMode: true, workingAgents: 1, administratorSession: true)).lidClosed,
                       "An administrator session can't be restarted on its own, so it only serves the request it was started for")
        XCTAssertTrue(KeepAwakePolicy.decide(KeepAwakeInputs(now: now, manualUntil: .distantFuture, administratorSession: true)).lidClosed)
        XCTAssertFalse(KeepAwakePolicy.decide(KeepAwakeInputs(now: now, manualUntil: .distantFuture)).lidClosed)
    }

    func testANearlyEmptyBatteryLetsTheMacSleep() {
        let plugged = KeepAwakePolicy.decide(KeepAwakeInputs(now: now, manualUntil: .distantFuture, battery: BatteryState(onBattery: false, percent: 5), passwordless: true))
        XCTAssertTrue(plugged.awake && plugged.lidClosed)
        XCTAssertEqual(KeepAwakePolicy.decide(KeepAwakeInputs(now: now, manualUntil: .distantFuture, battery: BatteryState(onBattery: true, percent: 10), passwordless: true)),
                       KeepAwakeDecision(awake: false, lidClosed: false, reason: .lowBattery(10)))
        XCTAssertTrue(KeepAwakePolicy.decide(KeepAwakeInputs(now: now, manualUntil: .distantFuture, battery: BatteryState(onBattery: true, percent: 11))).awake)
        XCTAssertEqual(KeepAwakePolicy.decide(KeepAwakeInputs(now: now, battery: BatteryState(onBattery: true, percent: 3))), .off,
                       "Nothing to pause when nothing asked to stay awake")
    }

    func testWordingNamesWhatKeepsTheMacAwakeAndWhatItCovers() {
        let time: (Date) -> String = { _ in "TIME" }
        XCTAssertEqual(KeepAwakeText.headline(.off, time: time), "Off")
        XCTAssertEqual(KeepAwakeText.headline(KeepAwakeDecision(awake: true, lidClosed: true, reason: .manual(until: nil)), time: time), "Awake until you stop it")
        XCTAssertEqual(KeepAwakeText.headline(KeepAwakeDecision(awake: true, lidClosed: true, reason: .manual(until: now)), time: time), "Awake until TIME")
        XCTAssertEqual(KeepAwakeText.headline(KeepAwakeDecision(awake: true, lidClosed: true, reason: .agents(1)), time: time), "Awake while 1 agent works")
        XCTAssertEqual(KeepAwakeText.headline(KeepAwakeDecision(awake: true, lidClosed: true, reason: .agents(3)), time: time), "Awake while 3 agents work")
        XCTAssertEqual(KeepAwakeText.headline(KeepAwakeDecision(awake: true, lidClosed: true, reason: .lingering(until: now)), time: time),
                       "Awake until TIME, after the last agent finished")
        XCTAssertEqual(KeepAwakeText.headline(KeepAwakeDecision(awake: false, lidClosed: false, reason: .lowBattery(9)), time: time), "Paused at 9% battery")
        XCTAssertNil(KeepAwakeText.coverage(.off, lidClosedActive: false))
        let agents = KeepAwakeDecision(awake: true, lidClosed: true, reason: .agents(1))
        XCTAssertEqual(KeepAwakeText.coverage(agents, lidClosedActive: true), "Closing the lid won't put it to sleep.")
        XCTAssertEqual(KeepAwakeText.coverage(agents, lidClosedActive: false), "Only while the lid is open. Closing the lid still sleeps.")
    }

    func testPMSetOutputAndCommandErrors() {
        XCTAssertEqual(PowerReader.parsePMSet("System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 1\n"), true)
        XCTAssertEqual(PowerReader.parsePMSet("System-wide power settings:\n SleepDisabled\t\t0\n"), false)
        XCTAssertEqual(PowerReader.parsePMSet("System-wide power settings:\nCurrently in use:\n sleep 1\n"), false, "Never set reads as allowed")
        XCTAssertNil(PowerReader.parsePMSet("garbage"))
        XCTAssertNotNil(PowerReader.sleepDisabled(), "This Mac's setting is readable without a password")

        func result(_ code: Int32, _ error: String = "", timedOut: Bool = false) -> CommandResult {
            CommandResult(code: code, output: "", error: error, timedOut: timedOut)
        }
        XCTAssertNil(LiveKeepAwakeSystem.error(result(0)))
        XCTAssertEqual(LiveKeepAwakeSystem.error(result(1, "0:84: execution error: User canceled. (-128)")), .cancelled)
        XCTAssertEqual(LiveKeepAwakeSystem.error(result(3)), .notAllowed)
        XCTAssertEqual(LiveKeepAwakeSystem.error(result(4)), .busy)
        XCTAssertEqual(LiveKeepAwakeSystem.error(result(1, "0:84: execution error: Another keep-awake session is starting. (4)")), .busy)
        XCTAssertEqual(LiveKeepAwakeSystem.error(result(1, "0:84: execution error: Could not turn sleep off. (1)")), .failed("Could not turn sleep off. (1)"))
    }

    func testTheOpenLidAssertionRegistersWithMacOSAndGoesAway() {
        let system = LiveKeepAwakeSystem()
        func listed() -> Bool { CommandRunner().run("/usr/bin/pmset", ["-g", "assertions"], timeout: 10).output.contains("Burro is keeping this Mac awake") }
        system.setAssertion(true)
        defer { system.setAssertion(false) }
        XCTAssertTrue(listed())
        system.setAssertion(true)
        system.setAssertion(false)
        XCTAssertFalse(listed(), "One release undoes it, however often it was held")
    }

    func testShellQuotingPassesTextThroughUnexpanded() {
        let tricky = #"it's "$HOME" `id` \n $(echo no)"#
        let result = CommandRunner().run("/bin/sh", ["-c", "printf %s " + KeepAwakeScript.quoted(tricky)])
        XCTAssertEqual(result.output, tricky)
        let line = KeepAwakeScript.commandLine(#"printf '%s|' "$0" "$@""#, ["a b", "c'd"])
        XCTAssertEqual(CommandRunner().run("/bin/sh", ["-c", line]).output, "burro-keep-awake|a b|c'd|")
    }

    func testMacHealthNeverListsTheWatchdog() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let watchdog = ProcessSample(pid: 900, parentPID: 1, started: start, executable: "/bin/sh",
                                     arguments: ["/bin/sh", "-c", "# script", KeepAwakeScript.processName, "start", "1", "/x"])
        let orphan = ProcessSample(pid: 901, parentPID: 1, started: start, executable: "/bin/sh", arguments: ["/bin/sh", "loop.sh"])
        let report = LeftoverPolicy.report(ProcessInventory(processes: [watchdog, orphan], sampledAt: start.addingTimeInterval(7200)),
                                           cpu: [:], now: start.addingTimeInterval(7200), home: "/Users/tester")
        XCTAssertEqual(report.leftovers.compactMap(\.pid), [901])
    }
}

/// The real session script, with pmset and sudo replaced by fakes and short timings.
final class KeepAwakeScriptTests: XCTestCase {
    var root: URL!
    var owners: [Process] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("burro-keep-awake-\(UUID().uuidString)")
        for folder in ["bin", "tmp", "burro"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try write("bin/pmset", """
            #!/bin/sh
            [ "$1 $2" = "-a disablesleep" ] || exit 1
            printf '%s\\n' "$3" > "$(dirname "$0")/state"
            printf '%s\\n' "$3" >> "$(dirname "$0")/history"
            """, executable: true)
        try write("bin/sudo", """
            #!/bin/sh
            dir=$(dirname "$0")
            while [ $# -gt 0 ]; do
                case "$1" in
                -n|-k) shift;;
                -l) [ -f "$dir/deny" ] && exit 1; exit 0;;
                *) break;;
                esac
            done
            [ -f "$dir/deny" ] && exit 1
            exec "$@"
            """, executable: true)
    }
    override func tearDown() {
        owners.forEach { $0.terminate() }
        // Remove markers first so any watchdog still running exits and cleans up.
        try? FileManager.default.removeItem(at: root.appendingPathComponent("burro"))
        Thread.sleep(forTimeInterval: 0.5)
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String, executable: Bool = false) throws {
        let url = root.appendingPathComponent(path)
        try Data(text.utf8).write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }
    private var script: String {
        var text = KeepAwakeScript.session
        for (line, replacement) in [("PMSET=/usr/bin/pmset", "PMSET=\(root.path)/bin/pmset"), ("SUDO=/usr/bin/sudo", "SUDO=\(root.path)/bin/sudo"),
                                    ("TICK=2", "TICK=0.2"), ("GRACE=30", "GRACE=1")] {
            precondition(text.contains(line), "The script no longer sets \(line)")
            text = text.replacingOccurrences(of: line, with: replacement)
        }
        return text
    }
    private var state: String? {
        (try? String(contentsOf: root.appendingPathComponent("bin/state"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var lock: URL { root.appendingPathComponent("tmp/local.burro.keepawake") }
    private func marker(_ name: String = "session-1", age: TimeInterval = 0) -> URL {
        let url = root.appendingPathComponent("burro/\(name)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        if age > 0 { try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path) }
        return url
    }
    private func owner() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["600"]
        try process.run()
        owners.append(process)
        return process
    }
    private func start(_ owner: Process, _ marker: URL) throws -> (code: Int32, output: String) {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = KeepAwakeScript.shellArguments(script, ["start", "\(owner.processIdentifier)", marker.path])
        process.environment = ["TMPDIR": root.appendingPathComponent("tmp").path]
        process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run()
        // The watchdog keeps no copy of stdout, so reading to the end returns when start exits.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    private func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if condition() { return true }; Thread.sleep(forTimeInterval: 0.05) }
        return condition()
    }

    func testStartTurnsSleepOffAndRemovingTheMarkerTurnsItBackOn() throws {
        let marker = marker(), owner = try owner()
        let result = try start(owner, marker)
        XCTAssertEqual(result.code, 0)
        let fields = result.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1)
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields.last.map(String.init), lock.path)
        XCTAssertEqual(state, "1")
        XCTAssertEqual(try start(owner, self.marker("session-2")).code, 4, "Only one session at a time")
        try FileManager.default.removeItem(at: marker)
        XCTAssertTrue(eventually { state == "0" && !FileManager.default.fileExists(atPath: lock.path) })
        XCTAssertEqual(try start(owner, self.marker("session-3")).code, 0, "The lock is free again")
    }

    func testSleepComesBackOnWhenBurroExitsAndNothingTakesOver() throws {
        let owner = try owner()
        XCTAssertEqual(try start(owner, marker()).code, 0)
        owner.terminate()
        XCTAssertTrue(eventually { state == "0" && !FileManager.default.fileExists(atPath: lock.path) }, "Restored after the grace period")
    }

    func testARelaunchedBurroTakesTheSessionOver() throws {
        let marker = marker(), first = try owner()
        XCTAssertEqual(try start(first, marker).code, 0)
        first.terminate()
        let second = try owner()
        try Data("\(second.processIdentifier)\n".utf8).write(to: root.appendingPathComponent("burro/adopt"))
        XCTAssertTrue(eventually {
            (try? String(contentsOf: lock.appendingPathComponent("owner"), encoding: .utf8)) == "\(second.processIdentifier)\n"
        })
        Thread.sleep(forTimeInterval: 1.5) // past the grace period
        XCTAssertEqual(state, "1", "Adopted sessions keep sleep off")
        second.terminate()
        XCTAssertTrue(eventually { state == "0" })
    }

    func testAMarkerNobodyTouchedForFifteenMinutesEndsTheSession() throws {
        XCTAssertEqual(try start(try owner(), marker(age: 20 * 60)).code, 0)
        XCTAssertTrue(eventually { state == "0" && !FileManager.default.fileExists(atPath: lock.path) })
    }

    func testWithoutThePermissionNothingChanges() throws {
        try write("bin/deny", "")
        XCTAssertEqual(try start(try owner(), marker()).code, 3)
        XCTAssertNil(state)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
    }

    /// The administrator path runs the same command line through `do shell script`; the watchdog must outlive it.
    func testTheWatchdogOutlivesDoShellScript() throws {
        let marker = marker(), owner = try owner()
        let command = "TMPDIR=\(KeepAwakeScript.quoted(root.appendingPathComponent("tmp").path)) "
            + KeepAwakeScript.commandLine(script, ["start", "\(owner.processIdentifier)", marker.path])
        let result = CommandRunner().run("/usr/bin/osascript", ["-e", "on run argv", "-e", "do shell script (item 1 of argv) without altering line endings",
                                                                "-e", "end run", command], timeout: 30)
        guard result.succeeded else { throw XCTSkip("osascript unavailable here: \(result.error)") }
        let watcher = Int32(result.output.split(separator: " ").first ?? "") ?? 0
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(kill(watcher, 0), 0, "Watchdog still running after do shell script returned")
        XCTAssertEqual(state, "1")
        try FileManager.default.removeItem(at: marker)
        XCTAssertTrue(eventually { state == "0" })
    }
}

/// Records what the store asks for; never touches the real sleep setting.
final class FakeKeepAwakeSystem: KeepAwakeSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var values: (passwordless: Bool, rule: Bool, sleep: Bool?, battery: BatteryState?, alive: Bool, adopt: Bool, failure: KeepAwakeError?)
    private(set) var started: [KeepAwakeAuthorization] = []
    private(set) var stopped = 0, stopAllCalls = 0, restored = 0, assertion = false
    init(passwordless: Bool = false, sleep: Bool? = false) {
        values = (passwordless, passwordless, sleep, nil, true, true, nil)
    }
    private func with<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var batteryState: BatteryState? { get { with { values.battery } } set { with { values.battery = newValue } } }
    var alive: Bool { get { with { values.alive } } set { with { values.alive = newValue } } }
    var adoptResult: Bool { get { with { values.adopt } } set { with { values.adopt = newValue } } }
    var failure: KeepAwakeError? { get { with { values.failure } } set { with { values.failure = newValue } } }
    var sleep: Bool? { get { with { values.sleep } } set { with { values.sleep = newValue } } }

    func sleepDisabled() -> Bool? { sleep }
    func battery() -> BatteryState? { batteryState }
    func passwordlessAllowed() -> Bool { with { values.passwordless } }
    func ruleInstalled() -> Bool { with { values.rule } }
    func startSession(owner: Int32, marker: URL, authorization: KeepAwakeAuthorization) -> Result<KeepAwakeSession, KeepAwakeError> {
        with {
            started.append(authorization)
            if let failure = values.failure { return .failure(failure) }
            values.sleep = true; values.alive = true
            return .success(KeepAwakeSession(watcher: 4242, watcherStarted: 1, lock: "/tmp/none", marker: marker.path,
                                             authorization: authorization, startedAt: Date()))
        }
    }
    func isAlive(_ session: KeepAwakeSession) -> Bool { alive }
    func adopt(_ session: KeepAwakeSession, owner: Int32) -> Bool { adoptResult }
    func stop(_ session: KeepAwakeSession) { with { stopped += 1; values.sleep = false } }
    func stopAll(in folder: URL) { with { stopAllCalls += 1 } }
    func touch(_ session: KeepAwakeSession) {}
    func restoreSleep(authorization: KeepAwakeAuthorization) -> Result<Void, KeepAwakeError> { with { restored += 1; values.sleep = false }; return .success(()) }
    func installRule(user: String) -> Result<Void, KeepAwakeError> { with { values.passwordless = true; values.rule = true }; return .success(()) }
    func removeRule() -> Result<Void, KeepAwakeError> { with { values.passwordless = false; values.rule = false }; return .success(()) }
    func setAssertion(_ held: Bool) { with { assertion = held } }
}

@MainActor final class KeepAwakeStoreTests: XCTestCase {

    private func store(_ system: FakeKeepAwakeSystem, defaults: UserDefaults? = nil) async -> KeepAwakeStore {
        let store = KeepAwakeStore(defaults: defaults ?? fresh(), system: system,
                                   folder: FileManager.default.temporaryDirectory.appendingPathComponent("burro-ka-\(UUID().uuidString)"), owner: 4321)
        await store.launch()
        return store
    }
    private func fresh() -> UserDefaults {
        let name = "burro-keep-awake-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testAgentsModeWithThePermissionCoversAClosedLidUntilTheAgentsAreDone() async {
        let system = FakeKeepAwakeSystem(passwordless: true), store = await store(system)
        let start = Date()
        store.agentsMode = true; store.lingerMinutes = 5
        store.agentsChanged(working: 2, now: start)
        await store.pending?.value
        XCTAssertEqual(system.started, [.passwordless])
        XCTAssertTrue(store.lidClosedActive && system.assertion)
        XCTAssertEqual(store.decision.reason, .agents(2))

        store.agentsChanged(working: 0, now: start.addingTimeInterval(60))
        XCTAssertTrue(store.lidClosedActive, "Stays awake a little after the last agent")
        XCTAssertEqual(store.decision.reason, .lingering(until: start.addingTimeInterval(300)))

        store.agentsChanged(working: 0, now: start.addingTimeInterval(301))
        XCTAssertFalse(store.lidClosedActive)
        XCTAssertEqual(system.stopped, 1)
        XCTAssertFalse(system.assertion)
        XCTAssertEqual(store.decision, .off)
    }

    func testWithoutThePermissionAgentsOnlyKeepAnOpenLidAwake() async {
        let system = FakeKeepAwakeSystem(), store = await store(system)
        store.agentsMode = true
        store.agentsChanged(working: 1)
        XCTAssertTrue(system.started.isEmpty, "Never prompts on its own")
        XCTAssertTrue(system.assertion)
        XCTAssertEqual(store.coverage, "Only while the lid is open. Closing the lid still sleeps.")
        XCTAssertFalse(store.canIncludeClosedLid, "A prompt only serves a request you made")
    }

    func testAManualRequestAsksOnceAndStopEndsIt() async {
        let system = FakeKeepAwakeSystem(), store = await store(system)
        store.keepAwake(for: 3600)
        await store.pending?.value
        XCTAssertEqual(system.started, [.administrator])
        XCTAssertTrue(store.lidClosedActive)
        store.keepAwake(for: nil)
        XCTAssertEqual(system.started.count, 1, "Changing the duration keeps the running session")
        store.stopManual()
        XCTAssertEqual(system.stopped, 1)
        XCTAssertFalse(store.awake)
    }

    func testCancellingThePromptStillKeepsAnOpenLidAwake() async {
        let system = FakeKeepAwakeSystem(), store = await store(system)
        system.failure = .cancelled
        store.keepAwake(for: nil)
        await store.pending?.value
        XCTAssertFalse(store.lidClosedActive)
        XCTAssertTrue(system.assertion)
        XCTAssertTrue(store.canIncludeClosedLid)
        XCTAssertEqual(store.message?.contains("cancelled"), true)
    }

    func testAllowingThePermissionStartsTheSessionAnAgentNeeds() async {
        let system = FakeKeepAwakeSystem(), store = await store(system)
        store.agentsMode = true
        store.agentsChanged(working: 1)
        store.allowWithoutPassword()
        await store.pending?.value
        await store.pending?.value
        XCTAssertTrue(store.passwordless && store.ruleInstalled)
        XCTAssertEqual(system.started, [.passwordless])
    }

    func testARelaunchTakesTheLastSessionOverOrLetsItEnd() async throws {
        let defaults = fresh()
        let saved = KeepAwakeSession(watcher: 7, watcherStarted: 1, lock: "/tmp/none", marker: "/tmp/none/session-x",
                                     authorization: .passwordless, startedAt: Date())
        defaults.set(try JSONEncoder().encode(saved), forKey: "keepAwake.session")
        defaults.set(true, forKey: "keepAwake.agents")

        let adopting = FakeKeepAwakeSystem(passwordless: true)
        let kept = await store(adopting, defaults: defaults)
        XCTAssertEqual(kept.session, saved)
        XCTAssertEqual(adopting.stopAllCalls, 0)
        kept.agentsChanged(working: 1)
        XCTAssertTrue(adopting.started.isEmpty, "The adopted session is reused")

        let failing = FakeKeepAwakeSystem(passwordless: true)
        failing.adoptResult = false
        let dropped = await store(failing, defaults: defaults)
        XCTAssertNil(dropped.session)
        XCTAssertEqual(failing.stopAllCalls, 1, "Markers nobody took over are removed so their watchdogs restore sleep")
    }

    func testALowBatteryEndsTheSession() async {
        let system = FakeKeepAwakeSystem(passwordless: true), store = await store(system)
        store.keepAwake(for: nil)
        await store.pending?.value
        XCTAssertTrue(store.lidClosedActive)
        system.batteryState = BatteryState(onBattery: true, percent: 8)
        await store.refreshState()
        XCTAssertFalse(store.lidClosedActive)
        XCTAssertEqual(store.decision.reason, .lowBattery(8))
        XCTAssertTrue(store.manualActive, "Plugging in resumes the request")
    }

    func testSleepLeftOffIsReportedAndBurroOnlyFixesItsOwn() async {
        let outside = FakeKeepAwakeSystem(passwordless: true, sleep: true)
        let other = await store(outside)
        XCTAssertEqual(other.leftover, .outside)
        await other.refreshState()
        XCTAssertEqual(outside.restored, 0, "Something else's setting is only reported")

        let defaults = fresh()
        defaults.set(true, forKey: "keepAwake.turnedSleepOff")
        let ours = FakeKeepAwakeSystem(passwordless: true, sleep: true)
        let store = await store(ours, defaults: defaults)
        XCTAssertEqual(store.leftover, .burro)
        await store.refreshState()
        await store.pending?.value
        XCTAssertEqual(ours.restored, 1)
        XCTAssertNil(store.leftover)
    }
}
