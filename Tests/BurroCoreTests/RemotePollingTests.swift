import XCTest
@testable import BurroCore

final class RemotePollingTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let host = UUID()

    func testANewHostIsDueAtOnce() {
        XCTAssertTrue(RemotePollSchedule().isDue(host, now: start, fast: false))
    }
    func testFastAndSlowCadence() {
        var schedule = RemotePollSchedule()
        schedule.recordSuccess(host, at: start)
        XCTAssertEqual(schedule.nextDue(host, fast: true), start.addingTimeInterval(10))
        XCTAssertEqual(schedule.nextDue(host, fast: false), start.addingTimeInterval(60))
        XCTAssertFalse(schedule.isDue(host, now: start.addingTimeInterval(30), fast: false))
        XCTAssertTrue(schedule.isDue(host, now: start.addingTimeInterval(30), fast: true))
    }
    func testFailuresBackOffAndASuccessResets() {
        var schedule = RemotePollSchedule()
        var steps: [TimeInterval] = []
        for _ in 0..<6 {
            schedule.recordFailure(host, at: start)
            steps.append(schedule.nextDue(host, fast: true).timeIntervalSince(start))
        }
        XCTAssertEqual(steps, [15, 30, 60, 120, 120, 120])
        schedule.recordSuccess(host, at: start)
        XCTAssertEqual(schedule.failures(host), 0)
        XCTAssertEqual(schedule.nextDue(host, fast: true), start.addingTimeInterval(10))
    }
    func testBackoffNeverPollsFasterThanTheSlowCadence() {
        var schedule = RemotePollSchedule()
        schedule.recordFailure(host, at: start)
        XCTAssertEqual(schedule.nextDue(host, fast: false), start.addingTimeInterval(60))
        for _ in 0..<3 { schedule.recordFailure(host, at: start) }
        XCTAssertEqual(schedule.nextDue(host, fast: false), start.addingTimeInterval(120))
    }
    func testManualRefreshProbesNowAndForgetsBackoff() {
        var schedule = RemotePollSchedule()
        for _ in 0..<4 { schedule.recordFailure(host, at: start) }
        schedule.requestNow([host])
        XCTAssertEqual(schedule.failures(host), 0)
        XCTAssertTrue(schedule.isDue(host, now: start, fast: false))
        schedule.recordFailure(host, at: start)
        XCTAssertEqual(schedule.nextDue(host, fast: true), start.addingTimeInterval(15), "backoff starts again from the first step")
    }
    func testDueListAndSleepAreBoundedByTheTick() {
        var schedule = RemotePollSchedule()
        let other = UUID()
        schedule.recordSuccess(host, at: start)
        XCTAssertEqual(schedule.due([host, other], now: start, fast: true), [other])
        schedule.recordSuccess(other, at: start)
        XCTAssertEqual(schedule.sleepInterval([host, other], now: start, fast: false, tick: 5), 5)
        XCTAssertEqual(schedule.sleepInterval([host, other], now: start.addingTimeInterval(8), fast: true, tick: 5), 2, accuracy: 0.001)
        XCTAssertEqual(schedule.sleepInterval([host], now: start.addingTimeInterval(100), fast: true, tick: 5), 0.5)
        schedule.keep(only: [other])
        XCTAssertTrue(schedule.isDue(host, now: start, fast: true), "a removed host is forgotten")
    }
    func testFastWhileLookingOrWhileARemoteChatIsBusy() {
        XCTAssertTrue(RemotePollSchedule.wantsFast(surfaceVisible: true, remoteStates: []))
        XCTAssertTrue(RemotePollSchedule.wantsFast(surfaceVisible: false, remoteStates: [.idle, .working]))
        XCTAssertTrue(RemotePollSchedule.wantsFast(surfaceVisible: false, remoteStates: [.waiting]))
        XCTAssertFalse(RemotePollSchedule.wantsFast(surfaceVisible: false, remoteStates: [.idle, .inactive]))
    }

    // MARK: Publishing activity

    private func session(_ id: String, state: AgentState = .idle, remoteAt: Date? = nil) -> AgentSession {
        var value = AgentSession(id: id, provider: .codex, title: id, cwd: "/repo", attachedPaths: [], state: state,
                                 updatedAt: start, pinned: false, evidence: "")
        if let remoteAt { value.remote = RemoteOrigin(hostID: host, hostName: "Laptop", sampledAt: remoteAt, stale: false) }
        return value
    }
    func testActivityIsRepublishedOnlyWhenSomethingShownChanges() {
        let current = AgentActivitySnapshot(sessions: [session("a"), session("b", remoteAt: start)], warnings: [], sampledAt: start)
        let sameLater = AgentActivitySnapshot(sessions: [session("a"), session("b", remoteAt: start.addingTimeInterval(14))],
                                              warnings: [], sampledAt: start.addingTimeInterval(3))
        XCTAssertFalse(current.shouldPublish(sameLater))
        var changed = sameLater; changed.sessions[0].state = .working
        XCTAssertTrue(current.shouldPublish(changed))
        let warned = AgentActivitySnapshot(sessions: sameLater.sessions, warnings: ["Laptop: connection unavailable"], sampledAt: sameLater.sampledAt)
        XCTAssertTrue(current.shouldPublish(warned))
        let old = AgentActivitySnapshot(sessions: sameLater.sessions, warnings: [], sampledAt: start.addingTimeInterval(30))
        XCTAssertTrue(current.shouldPublish(old), "the shown sample time is refreshed before it would read as stale")
        XCTAssertTrue(AgentActivitySnapshot.empty.shouldPublish(AgentActivitySnapshot(sessions: [], warnings: [], sampledAt: start)))
    }

    // MARK: SSH

    func testSSHKeepsStrictOptionsAndSharesAConnectionInAPrivateFolder() {
        let args = RemoteAgentMonitor.arguments(for: RemoteHost(name: "Laptop", destination: "user@laptop", port: 2222))
        for option in ["BatchMode=yes", "StrictHostKeyChecking=yes", "ConnectTimeout=5", "ConnectionAttempts=1", "ServerAliveInterval=5",
                       "ServerAliveCountMax=1", "ClearAllForwardings=yes", "ForwardAgent=no", "ForwardX11=no", "PermitLocalCommand=no"] {
            XCTAssertTrue(args.contains(option), option)
        }
        XCTAssertEqual(Array(args.suffix(3)), ["--", "user@laptop", "python3 -"])
        guard let directory = SSHControlSocket.directory else { return XCTFail("no usable control folder") }
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        XCTAssertTrue(args.contains("ControlPersist=120"))
        XCTAssertTrue(args.contains("ControlPath=\(directory)/%C"))
        XCTAssertLessThanOrEqual(directory.utf8.count, SSHControlSocket.maxDirectoryLength)
        var info = stat()
        XCTAssertEqual(lstat(directory, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(info.st_uid, getuid())
    }
    func testSSHAcceptsTheSharingOptions() {
        // `ssh -G` only prints the resolved configuration; it never connects.
        let args = RemoteAgentMonitor.arguments(for: RemoteHost(name: "Laptop", destination: "user@laptop.invalid"))
        let options = Array(args.prefix { $0 != "--" }).filter { $0 != "-T" }
        let result = CommandRunner().run("/usr/bin/ssh", ["-G"] + options + ["user@laptop.invalid"], timeout: 10)
        XCTAssertTrue(result.succeeded, result.error)
        if SSHControlSocket.directory != nil {
            XCTAssertTrue(result.output.contains("controlmaster auto"), result.output)
            XCTAssertTrue(result.output.contains("controlpersist 120"), result.output)
            XCTAssertTrue(result.output.contains("batchmode yes"))
        }
    }
    func testControlFolderRejectsLongPathsSymlinksAndLooseFolders() throws {
        let base = URL(fileURLWithPath: "/tmp").appendingPathComponent("bt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let long = base.appendingPathComponent(String(repeating: "x", count: 60)).path
        let link = base.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: base.path)
        let loose = base.appendingPathComponent("loose").path
        XCTAssertEqual(mkdir(loose, 0o755), 0)
        XCTAssertNil(SSHControlSocket.prepare(candidates: [long, link]))
        XCTAssertEqual(SSHControlSocket.prepare(candidates: [long, link, loose]), loose)
        var info = stat()
        XCTAssertEqual(lstat(loose, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700, "an existing folder is tightened to owner-only")
        XCTAssertEqual(SSHControlSocket.options(directory: nil), [])
    }

    // MARK: Commands

    func testCommandTimesOut() {
        let started = Date()
        let result = CommandRunner().run("/bin/sleep", ["5"], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
    func testAsyncCommandReturnsOutputAndExitCode() async {
        let result = await CommandRunner().run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        XCTAssertEqual(result.code, 3)
        XCTAssertEqual(result.output, "out\n")
        XCTAssertEqual(result.error, "err\n")
        XCTAssertFalse(result.timedOut)
        let input = await CommandRunner().run("/bin/cat", [], input: Data("literal $(x)".utf8))
        XCTAssertEqual(input.output, "literal $(x)")
    }
    func testAsyncCommandTimesOutAndBoundsOutput() async {
        let slow = await CommandRunner().run("/bin/sleep", ["5"], timeout: 0.5)
        XCTAssertTrue(slow.timedOut)
        let loud = await CommandRunner().run("/usr/bin/yes", ["bounded output"], timeout: 5)
        XCTAssertEqual(loud.code, -2)
        XCTAssertFalse(loud.timedOut)
    }
    func testCancellingTheTaskStopsTheCommand() async {
        let started = Date()
        let task = Task { await CommandRunner().run("/bin/sleep", ["5"], timeout: 10) }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.code, -3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
    func testMissingExecutableReportsAnError() async {
        let result = await CommandRunner().run("/nonexistent/tool", [])
        XCTAssertEqual(result.code, -1)
    }
    func testMissingExecutableReportsAnErrorSynchronously() {
        XCTAssertEqual(CommandRunner().run("/nonexistent/tool", []).code, -1)
    }
}
