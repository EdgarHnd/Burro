// Synthetic ownership/lifecycle regressions plus native read-only descriptor inspection.
import XCTest
import CSystem
import Darwin
@testable import BurroCore

final class ClaudeDelegatedActivityTests: XCTestCase {
    let sid = "11111111-2222-4333-8444-555555555555"
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var deadline: Double { ProcessInfo.processInfo.systemUptime + 5 }
    var path: String { "/private/tmp/claude-\(getuid())/fixture/\(sid)/tasks/task_1.output" }
    func process(_ pid: Int, _ name: String, parent: Int? = nil) -> LocalProcess {
        LocalProcess(pid: pid, name: name, cwd: "/fixture", started: now.addingTimeInterval(-600), parentPID: parent)
    }
    func inspect(_ children: [LocalProcess], paths: [Int: String], identity: (LocalProcess) -> Bool = { _ in true }, fail: Bool = false) -> ClaudeDelegatedActivity? {
        let parent = process(100, "claude")
        return ClaudeDelegatedActivity.inspect(home: "/nonexistent-burro-fixture", sessionID: sid, parent: parent,
            incarnation: nil, processes: [parent] + children, now: now, deadline: deadline, identity: identity,
            descriptor: { pid, _ in
                if fail { throw ClaudeDelegatedActivity.InspectionError.incomplete }
                return paths[pid]
            })
    }
    func testDelayedTaskIsScheduledAndChangesToRunningThenIdle() {
        let shell = process(101, "zsh", parent: 100), sleep = process(102, "sleep", parent: 101)
        XCTAssertEqual(inspect([shell, sleep], paths: [101: path, 102: path])?.state, .scheduled)
        XCTAssertEqual(inspect([shell, process(102, "python3", parent: 101)], paths: [101: path, 102: path])?.state, .working)
        XCTAssertNil(inspect([], paths: [:]))
    }
    func testUnrelatedSleepHelpersAndForeignTaskFilesDoNotCount() {
        let sleep = process(101, "sleep", parent: 100)
        XCTAssertNil(inspect([sleep], paths: [:]))
        XCTAssertNil(inspect([sleep], paths: [101: path.replacingOccurrences(of: sid, with: UUID().uuidString)]))
        XCTAssertNil(inspect([process(101, "sleep", parent: 999)], paths: [101: path]))
        XCTAssertNil(inspect([process(101, "mcp-helper", parent: 100)], paths: [101: "/tmp/arbitrary.output"]))
    }
    func testMixedTasksAndNonShellParentsStayRunning() {
        let shell = process(101, "zsh", parent: 100), sleep = process(102, "sleep", parent: 101)
        XCTAssertEqual(inspect([shell, sleep, process(103, "python3", parent: 100)], paths: [101: path, 102: path, 103: path.replacingOccurrences(of: "task_1", with: "task_2")])?.state, .working)
        XCTAssertEqual(inspect([process(101, "node", parent: 100), sleep], paths: [101: path, 102: path])?.state, .working)
        XCTAssertEqual(inspect([shell, sleep, process(103, "python3", parent: 101)], paths: [101: path, 102: path])?.state, .working,
                       "An active child with redirected output also prevents Scheduled")
    }
    func testInvalidIdentityAndDeniedInspectionCannotBecomeDone() {
        let child = process(101, "sleep", parent: 100)
        XCTAssertEqual(inspect([child], paths: [101: path], identity: { $0.pid != 100 })?.state, .unknown)
        XCTAssertNil(inspect([child], paths: [101: path], identity: { $0.pid != 101 }))
        XCTAssertEqual(inspect([child], paths: [:], fail: true)?.state, .unknown)
    }
    func testTaskPathRequiresExactUserSessionAndSafeID() {
        XCTAssertEqual(ClaudeDelegatedActivity.taskID(path: path, sessionID: sid), "task_1")
        XCTAssertEqual(ClaudeDelegatedActivity.taskID(path: path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"), sessionID: sid), "task_1")
        for invalid in [path.replacingOccurrences(of: "claude-\(getuid())", with: "claude-99999"),
                        path.replacingOccurrences(of: "/fixture/", with: "/../"), path + "/nested", path.replacingOccurrences(of: "task_1", with: "bad id")] {
            XCTAssertNil(ClaudeDelegatedActivity.taskID(path: invalid, sessionID: sid), invalid)
        }
    }
    func testTraversalLimitFailsClosed() {
        let children = (101...360).map { process($0, "sleep", parent: 100) }
        XCTAssertEqual(inspect(children, paths: [:])?.state, .unknown)
    }
    func event(stop: String? = nil, time: Date? = nil, session: String? = nil) throws -> String {
        var message: [String: Any] = [:]
        if let stop { message["stop_reason"] = stop }
        let object: [String: Any] = ["sessionId": session ?? sid, "agentId": "worker", "isSidechain": true,
            "type": "assistant", "timestamp": ISO8601DateFormatter().string(from: time ?? now), "message": message]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    func state(_ tail: String) -> AgentState? {
        ClaudeDelegatedActivity.workerTailState(tail, sessionID: sid, agentID: "worker", started: now.addingTimeInterval(-600), now: now, modified: now)
    }
    func handback(flag: Any = true, time: Date? = nil, content: [[String: Any]] = [["type": "tool_result"]]) throws -> String {
        let object: [String: Any] = ["sessionId": sid, "agentId": "worker", "isSidechain": true,
            "type": "user", "timestamp": ISO8601DateFormatter().string(from: time ?? now),
            "toolEndsTurn": flag, "message": ["role": "user", "content": content]]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    func testHandbackCompletesWorkerWithoutAssistantStopReason() throws {
        let finished = try handback(time: now.addingTimeInterval(-300))
        XCTAssertNil(state(finished), "A completed handback must not age into Unknown")
        XCTAssertNil(state(try event(time: now.addingTimeInterval(-400)) + "\n" + finished))
        XCTAssertEqual(state(try finished + "\n" + event()), .working, "A resumed worker can run again")
        XCTAssertEqual(state(try finished + "\n" + event(time: now.addingTimeInterval(-121))), .unknown)
    }
    func testHandbackRequiresBooleanTerminalFlagAndToolResultEnvelope() throws {
        for flag: Any in [false, 1, "true", NSNull()] {
            XCTAssertEqual(state(try handback(flag: flag, time: now.addingTimeInterval(-300))), .unknown)
        }
        XCTAssertEqual(state(try handback(time: now.addingTimeInterval(-300), content: [["type": "text", "text": "toolEndsTurn: true"]])), .unknown)
        XCTAssertNil(state(try handback().replacingOccurrences(of: sid, with: UUID().uuidString)))
        XCTAssertNil(state(try handback().replacingOccurrences(of: "worker", with: "different-worker")))
        XCTAssertNil(state(try handback(time: now.addingTimeInterval(-900))))
    }
    func testWorkersRequireFreshMatchingUnfinishedLifecycle() throws {
        XCTAssertEqual(state(try event()), .working)
        XCTAssertNil(state(try event(stop: "end_turn")))
        XCTAssertNil(state(try event() + "\n" + event(stop: "stop_sequence")))
        XCTAssertEqual(state(try event(time: now.addingTimeInterval(-121))), .unknown)
        XCTAssertNil(state(try event(time: now.addingTimeInterval(-900))))
        XCTAssertNil(state(try event(session: UUID().uuidString)))
        XCTAssertEqual(state("invalid JSON"), .unknown)
    }
    func testWorkerLifecycleCanOverrideScheduledAndCompletedLogsDoNot() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".claude/projects/fixture/\(sid)/subagents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("agent-worker.jsonl")
        let parent = process(100, "claude"), child = process(101, "sleep", parent: 100)
        func read() -> AgentState? {
            ClaudeDelegatedActivity.inspect(home: home.path, sessionID: sid, parent: parent, incarnation: now.addingTimeInterval(-600),
                processes: [parent, child], now: now, deadline: deadline, identity: { _ in true }, descriptor: { _, _ in self.path })?.state
        }
        for (stop, expected) in [(nil, AgentState.working), ("end_turn", .scheduled)] as [(String?, AgentState)] {
            try event(stop: stop).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
            XCTAssertEqual(read(), expected)
        }
        try handback(time: now.addingTimeInterval(-300)).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-300)], ofItemAtPath: file.path)
        XCTAssertEqual(read(), .scheduled, "A finished worker must not hide a verified scheduled command")
        try event(time: now.addingTimeInterval(-200)).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        XCTAssertEqual(read(), .unknown)
    }
    func testScheduledRemainsVisibleSeparateFromRunningAttentionAndDone() {
        var session = AgentSession(id: "scheduled", provider: .claude, title: "Delayed check", cwd: "/fixture", state: .scheduled,
            updatedAt: now, evidence: "fixture", turnCompleted: true, hasUnreadResult: true)
        XCTAssertFalse(session.isDone); XCTAssertTrue(session.state.keepsWorktree)
        let activity = AgentActivitySnapshot(sessions: [session, session], warnings: [], sampledAt: now)
        XCTAssertEqual(activity.scheduledCount, 1); XCTAssertEqual(activity.workingCount, 0)
        XCTAssertEqual(activity.attentionCount, 0); XCTAssertEqual(activity.idleCount, 0)
        XCTAssertEqual(activity.visibleSessions(includeIdle: false).count, 1)
        XCTAssertEqual(NotchFeed(sessions: [session], includeIdle: false).groups.count, 1)
        session.state = .waiting
        XCTAssertEqual(NotchGroup.priority(session), 0)
    }
    func testNativeWritableDescriptorIsReadWithoutTaskContents() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
        child.standardOutput = handle; child.standardError = Pipe()
        try child.run(); defer { child.terminate(); child.waitUntilExit() }
        XCTAssertEqual(try ClaudeDelegatedActivity.outputPath(pid: Int(child.processIdentifier), fd: 1).map(Paths.canonical), Paths.canonical(file.path))
        XCTAssertNil(try ClaudeDelegatedActivity.outputPath(pid: Int(child.processIdentifier), fd: 2))
    }
    func testLocalAdapterDetectsRealDelayedTaskWithoutOverridingPermissionWait() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let taskRoot = URL(fileURLWithPath: "/private/tmp/claude-\(getuid())/burro-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: taskRoot) }
        let registry = home.appendingPathComponent(".claude/sessions")
        let output = taskRoot.appendingPathComponent("\(sid)/tasks/test.output")
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: output.path, contents: Data())
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
        child.standardOutput = handle; child.standardError = handle
        try child.run(); defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        func kernel(_ pid: Int32, name: String) -> LocalProcess {
            var info = BurroProcess(); XCTAssertEqual(burro_process_info(pid, &info), 1)
            return LocalProcess(pid: Int(pid), name: name, cwd: home.path,
                started: Date(timeIntervalSince1970: Double(info.started)), parentPID: Int(info.ppid))
        }
        let parent = kernel(getpid(), name: "claude"), worker = kernel(child.processIdentifier, name: "sleep")
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        for (status, expected) in [("idle", AgentState.scheduled), ("waiting_for_permission", .waiting)] {
            let record: [String: Any] = ["sessionId": sid, "pid": parent.pid, "cwd": home.path,
                "procStart": formatter.string(from: parent.started), "status": status]
            try JSONSerialization.data(withJSONObject: record).write(to: registry.appendingPathComponent("fixture.json"))
            let session = AgentReader().read(home: home.path, processes: ProcessSnapshot(processes: [parent, worker], warnings: []), now: Date()).sessions.first
            XCTAssertEqual(session?.state, expected); XCTAssertEqual(session?.turnCompleted, false)
        }
    }

    func testLocalAdapterKeepsProviderPermissionWaitAndIdleWithoutDelegates() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var info = BurroProcess(); XCTAssertEqual(burro_process_info(getpid(), &info), 1)
        let parent = LocalProcess(pid: Int(getpid()), name: "claude", cwd: home.path, started: Date(timeIntervalSince1970: Double(info.started)))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        for (status, expected) in [("waiting_for_permission", AgentState.waiting), ("idle", .idle)] {
            let record: [String: Any] = ["sessionId": sid, "pid": parent.pid, "cwd": home.path, "procStart": formatter.string(from: parent.started), "status": status]
            try JSONSerialization.data(withJSONObject: record).write(to: directory.appendingPathComponent("fixture.json"))
            let sessions = AgentReader().read(home: home.path, processes: ProcessSnapshot(processes: [parent], warnings: []), now: Date()).sessions
            XCTAssertEqual(sessions.first?.state, expected)
        }
    }
}
