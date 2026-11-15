// Replying to an idle Claude background session: which `claude agents` rows count as running,
// the composer's plan per state, the route a reply takes, the stop and resume argv, the bounded
// wait for the stop with a fake agents reader, the whole local sequence with fake commands, the
// queue's no-double-send rule, and remote_reply.py's `continue` with a fake `claude` and `ps`
// under a temporary HOME. Nothing here stops or resumes a real session.
import XCTest
@testable import BurroCore

final class ClaudeContinueTests: XCTestCase {
    private let id = "11111111-2222-4333-8444-555555555555"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let host = RemoteHost(name: "devbox", destination: "me@devbox")

    private func session(_ state: AgentState = .idle, remote: RemoteHost? = nil) -> AgentSession {
        var value = AgentSession(id: "claude:\(id)", provider: .claude, title: "x", cwd: "/tmp", state: state, updatedAt: now, evidence: "fixture")
        if let remote {
            value.remote = RemoteOrigin(hostID: remote.id, hostName: remote.name, sampledAt: now, stale: false)
            value.id = "remote:\(remote.id.uuidString):\(value.id)"
        }
        return value
    }
    private func rows(_ rows: [[String: Any]]) -> Data { try! JSONSerialization.data(withJSONObject: rows) }
    private func row(_ fields: [String: Any]) -> [String: Any] { (["sessionId": id] as [String: Any]).merging(fields) { $1 } }

    private let idleRow: [String: Any] = ["id": "c0d2240d", "kind": "background", "pid": 42, "status": "idle", "state": "done"]
    private let idle = ChatReply.ClaudeLive(handle: "c0d2240d", background: true, busy: false, idle: true)

    // MARK: Rows

    func testOnlyRunningRowsCount() {
        func live(_ fields: [String: Any]...) -> ChatReply.ClaudeLookup { ChatReply.claudeLookup(id, rows: rows(fields.map(row))) }
        for finished in ["done", "failed", "stopped"] {
            XCTAssertEqual(live(["id": "c0d2240d", "kind": "background", "state": finished]), .found(nil), "A finished \(finished) session isn't open")
        }
        XCTAssertEqual(live(idleRow), .found(idle))
        XCTAssertEqual(live(["id": "c0d2240d", "kind": "background", "pid": 42, "status": "idle", "state": "working"]), .found(idle),
                       "The process's status decides, not the job's state")
        XCTAssertEqual(live(["id": "c0d2240d", "kind": "background", "pid": 42, "status": "waiting", "state": "blocked"]),
                       .found(.init(handle: "c0d2240d", background: true, busy: false, waiting: true)))
        XCTAssertEqual(live(["id": "c0d2240d", "kind": "background", "state": "working"]),
                       .found(.init(handle: "c0d2240d", background: true, busy: true)), "Running without a status counts as working")
        XCTAssertEqual(live(["id": "c0d2240d", "kind": "background", "pid": 42, "status": "idle", "state": "blocked"]),
                       .found(.init(handle: "c0d2240d", background: true, busy: false, waiting: true)))
        XCTAssertEqual(live(["kind": "interactive", "pid": 7, "status": "idle"]), .found(.init(handle: nil, background: false, busy: false, idle: true)))
        XCTAssertEqual(live(["id": "c0d2240d", "kind": "background", "state": "done"], ["kind": "interactive", "pid": 7, "status": "idle"]),
                       .found(.init(handle: nil, background: false, busy: false, idle: true)), "A terminal that reopened a finished session wins")
        XCTAssertEqual(live(idleRow, ["kind": "interactive", "pid": 7, "status": "idle"]), .found(.init(handle: nil, background: false, busy: false, idle: true)),
                       "The most restrictive row wins")
        XCTAssertEqual(ChatReply.claudeLookup(id, rows: Data("{\"not\":\"rows\"}".utf8)), .unreadable)
        XCTAssertEqual(ChatReply.claudeLookup(id, rows: Data("Warning: x".utf8)), .unreadable)
        XCTAssertEqual(ChatReply.claudeLookup(id, rows: rows([])), .found(nil))
    }

    // MARK: Composer plan

    func testComposerPlanForIdleAndBusyBackgroundAndInteractive() {
        func plan(_ s: AgentSession, host: RemoteHost? = nil, _ check: ChatReply.ClaudeCheck?) -> ComposerPlan {
            ChatReply.composerPlan(s, host: host, check: check, setupProblem: nil, queued: false, hasURL: true)
        }
        let busyLive = ChatReply.ClaudeLive(handle: "c0d2240d", background: true, busy: true)
        let desktopIdle = ChatReply.ClaudeLive(handle: nil, background: false, busy: false)
        let desktopBusy = ChatReply.ClaudeLive(handle: nil, background: false, busy: true)
        for remote in [nil, host] {
            let s = { (state: AgentState) in self.session(state, remote: remote) }
            let idlePlan = plan(s(.idle), host: remote, ChatReply.claudePlan(idle))
            XCTAssertTrue(idlePlan.canSend && idlePlan.showPickers && idlePlan.sendStopsFirst, "idle background, remote: \(remote != nil)")
            XCTAssertNil(idlePlan.reason); XCTAssertNil(idlePlan.action)
            XCTAssertEqual(ChatReply.sendHelp(idlePlan), "Stops the idle background session and continues it with your message (Return)")

            let busyPlan = plan(s(.working), host: remote, ChatReply.claudePlan(busyLive))
            XCTAssertFalse(busyPlan.canSend || busyPlan.sendStopsFirst); XCTAssertTrue(busyPlan.canQueue)
            XCTAssertEqual(busyPlan.stop, remote == nil ? .claudeBackground(handle: "c0d2240d") : .claudeRemote, "Busy: Stop or Queue, unchanged")

            let desktop = plan(s(.idle), host: remote, ChatReply.claudePlan(desktopIdle))
            XCTAssertFalse(desktop.canSend || desktop.sendStopsFirst); XCTAssertNotNil(desktop.reason)
            XCTAssertEqual(desktop.action, .openInProvider, "Interactive sessions stay hand-off only")
            let desktopWorking = plan(s(.working), host: remote, ChatReply.claudePlan(desktopBusy))
            XCTAssertEqual(desktopWorking.stop, .elsewhere); XCTAssertFalse(desktopWorking.canType)

            let closed = plan(s(.idle), host: remote, ChatReply.claudePlan(nil))
            XCTAssertTrue(closed.canSend); XCTAssertFalse(closed.sendStopsFirst)
            XCTAssertEqual(ChatReply.sendHelp(closed), "Send (Return)")
        }
        let attached = plan(session(), ChatReply.claudePlan(idle, attached: true))
        XCTAssertFalse(attached.canSend); XCTAssertTrue(attached.reason?.contains("attached in a terminal") == true)
        let waiting = plan(session(), ChatReply.claudePlan(.init(handle: "c0d2240d", background: true, busy: false, waiting: true)))
        XCTAssertFalse(waiting.canSend); XCTAssertEqual(waiting.action, .attachInTerminal(handle: "c0d2240d"), "Asking for approval: attach to answer")
        let noHandle = plan(session(), ChatReply.claudePlan(.init(handle: nil, background: true, busy: false, idle: true)))
        XCTAssertFalse(noHandle.canSend, "Without a valid short id nothing can be stopped")
    }

    func testRemoteCheckCarriesIdleWaitingAndAttached() {
        func check(_ live: String) -> ChatReply.ClaudeCheck {
            let body = #"{"ok":false,"error":"x","live":"# + live + "}"
            return ChatReply.remoteCheck(Data(body.utf8), host: "devbox")
        }
        XCTAssertTrue(check(#"{"kind":"background","busy":false,"idle":true,"waiting":false,"attached":false,"handle":"c0d2240d"}"#).continues)
        XCTAssertFalse(check(#"{"kind":"background","busy":false,"idle":true,"waiting":false,"attached":true,"handle":"c0d2240d"}"#).continues)
        XCTAssertFalse(check(#"{"kind":"background","busy":false,"idle":false,"waiting":true,"handle":"c0d2240d"}"#).continues)
        XCTAssertFalse(check(#"{"kind":"background","busy":false,"idle":true,"handle":"$(x)"}"#).continues)
        XCTAssertFalse(check(#"{"kind":"interactive","busy":false,"idle":true,"handle":null}"#).continues)
    }

    // MARK: Route and argv

    func testRouteStopsOnlyAnIdleBackgroundSessionWhenAsked() {
        XCTAssertEqual(ChatReply.claudeRoute(nil, stopIdleBackground: true, attached: false), .resume)
        XCTAssertEqual(ChatReply.claudeRoute(idle, stopIdleBackground: true, attached: false), .stopThenResume(handle: "c0d2240d"))
        XCTAssertEqual(ChatReply.claudeRoute(idle, stopIdleBackground: false, attached: false), .refuse(ChatReply.stillOpen), "Only when the Send asks")
        if case .refuse = ChatReply.claudeRoute(idle, stopIdleBackground: true, attached: true) {} else { XCTFail("Attached in a terminal") }
        for live in [ChatReply.ClaudeLive(handle: "c0d2240d", background: true, busy: true),
                     ChatReply.ClaudeLive(handle: "c0d2240d", background: true, busy: false, waiting: true),
                     ChatReply.ClaudeLive(handle: nil, background: false, busy: false),
                     ChatReply.ClaudeLive(handle: nil, background: true, busy: false, idle: true)] {
            if case .refuse = ChatReply.claudeRoute(live, stopIdleBackground: true, attached: false) {} else { XCTFail("\(live)") }
        }
    }

    func testStopAndResumeArguments() {
        XCTAssertEqual(ChatReply.claudeStopArguments(handle: "c0d2240d"), ["stop", "c0d2240d"])
        XCTAssertNil(ChatReply.claudeStopArguments(handle: "c0d2240d --all"))
        XCTAssertEqual(ChatReply.claudeArguments(sessionID: id, ReplyRequest(text: "go on", access: .edit)),
                       ["--bg", "--resume", id, "--permission-mode", "acceptEdits", "--", "go on"])
    }

    func testAttachDetection() {
        let attach = { (line: String) in ChatReply.attachedInTerminal(line, handle: "c0d2240d", sessionID: self.id) }
        XCTAssertTrue(attach("/Users/me/.local/bin/claude attach c0d2240d"))
        XCTAssertTrue(attach("claude attach \(id.uppercased())"))
        XCTAssertTrue(attach("/Applications/Claude.app/Contents/MacOS/claude attach my-session"), "By name it could be this one")
        XCTAssertTrue(attach("claude attach"), "The picker could open this one")
        XCTAssertTrue(attach("2.1.325 attach c0d2240d"), "The short id alone is enough")
        XCTAssertFalse(attach("claude attach aaaa1111"), "Another session")
        XCTAssertFalse(attach("/usr/bin/ssh devbox\nvim attach.txt\ngit attach notes"))
        XCTAssertTrue(ChatReply.attachedInTerminal(nil, handle: "c0d2240d", sessionID: id), "Can't read the process list: treated as attached")
    }

    // MARK: Wait and the local sequence

    /// A fake `claude` and `ps`: answers `agents` from a script of listings, records every call.
    private final class Fake: @unchecked Sendable {
        let lock = NSLock()
        var calls: [[String]] = []
        var listings: [String]
        var stopCode: Int32 = 0
        var resumeCode: Int32 = 0
        var processes: String? = ""
        var clock: TimeInterval = 0
        init(_ listings: [String]) { self.listings = listings }
        var commands: ClaudeCommands {
            ClaudeCommands(run: { [self] arguments, _, _ in
                lock.withLock {
                    calls.append(arguments)
                    if arguments.first == "agents" { return (0, listings.count > 1 ? listings.removeFirst() : (listings.first ?? "[]")) }
                    if arguments.first == "stop" { return (stopCode, stopCode == 0 ? "" : "Error: no such session") }
                    return (resumeCode, resumeCode == 0 ? "Started c0d2240d · claude attach c0d2240d" : "Error: bad")
                }
            }, processes: { [self] in lock.withLock { processes } },
               sleep: { [self] seconds in lock.withLock { clock += seconds } },
               now: { [self] in lock.withLock { Date(timeIntervalSince1970: clock) } })
        }
        var verbs: [String] { lock.withLock { calls.map { $0.first ?? "" } } }
    }
    private var idleListing: String { String(decoding: rows([row(idleRow)]), as: UTF8.self) }
    private var stoppedListing: String { String(decoding: rows([row(["id": "c0d2240d", "kind": "background", "state": "stopped"])]), as: UTF8.self) }

    func testWaitIsBoundedAndNeedsAConfirmedStop() {
        let fake = Fake([idleListing, idleListing, stoppedListing])
        XCTAssertTrue(ChatReply.waitUntilStopped(id, commands: fake.commands, limit: 8, poll: 0.4))
        XCTAssertEqual(fake.verbs, ["agents", "agents", "agents"])

        let never = Fake([idleListing])
        XCTAssertFalse(ChatReply.waitUntilStopped(id, commands: never.commands, limit: 8, poll: 0.4))
        XCTAssertLessThanOrEqual(never.calls.count, 22, "A few seconds at most")

        let unreadable = Fake(["Warning: something"])
        XCTAssertFalse(ChatReply.waitUntilStopped(id, commands: unreadable.commands, limit: 2, poll: 0.4), "An unreadable listing never counts as stopped")
    }

    func testLocalReplyStopsThenResumesInOrder() throws {
        let fake = Fake([idleListing, idleListing, stoppedListing])
        let args = ChatReply.claudeArguments(sessionID: id, ReplyRequest(text: "go on"))
        let output = try ChatReply.continueClaude(id, arguments: args, folder: "/tmp", stopIdleBackground: true, commands: fake.commands)
        XCTAssertFalse(output.contains("copy"))
        XCTAssertEqual(fake.calls.first, ["agents", "--json", "--all"])
        XCTAssertEqual(fake.calls.filter { $0.first == "stop" }, [["stop", "c0d2240d"]])
        XCTAssertEqual(fake.calls.last, args, "The resume goes last")
        let stopIndex = try XCTUnwrap(fake.calls.firstIndex { $0.first == "stop" })
        XCTAssertEqual(fake.calls[stopIndex + 1].first, "agents", "Confirmed stopped before resuming")
    }

    func testLocalReplySendsNothingWhenTheStopCantBeConfirmed() {
        let args = ChatReply.claudeArguments(sessionID: id, ReplyRequest(text: "go on"))
        let stillRunning = Fake([idleListing])
        XCTAssertThrowsError(try ChatReply.continueClaude(id, arguments: args, folder: "/tmp", stopIdleBackground: true, commands: stillRunning.commands)) {
            XCTAssertTrue(($0 as? LocalizedError)?.errorDescription?.contains("nothing was sent") == true)
        }
        XCTAssertFalse(stillRunning.verbs.contains("--bg"), "Still running after stop: nothing sent")

        let stopFails = Fake([idleListing, stoppedListing]); stopFails.stopCode = 1
        XCTAssertThrowsError(try ChatReply.continueClaude(id, arguments: args, folder: "/tmp", stopIdleBackground: true, commands: stopFails.commands))
        XCTAssertFalse(stopFails.verbs.contains("--bg"))

        let attached = Fake([idleListing, stoppedListing]); attached.processes = "/Users/me/.local/bin/claude attach c0d2240d"
        XCTAssertThrowsError(try ChatReply.continueClaude(id, arguments: args, folder: "/tmp", stopIdleBackground: true, commands: attached.commands))
        XCTAssertEqual(attached.verbs, ["agents"], "Attached in a terminal: neither stopped nor sent")

        let noProcessList = Fake([idleListing, stoppedListing]); noProcessList.processes = nil
        XCTAssertThrowsError(try ChatReply.continueClaude(id, arguments: args, folder: "/tmp", stopIdleBackground: true, commands: noProcessList.commands))
        XCTAssertEqual(noProcessList.verbs, ["agents"])

        let notAsked = Fake([idleListing, stoppedListing])
        XCTAssertThrowsError(try ChatReply.continueClaude(id, arguments: args, folder: "/tmp", stopIdleBackground: false, commands: notAsked.commands))
        XCTAssertEqual(notAsked.verbs, ["agents"], "Without the owner's Send asking, nothing is stopped")

        let interactive = Fake([String(decoding: rows([row(["kind": "interactive", "pid": 7, "status": "idle"])]), as: UTF8.self)])
        XCTAssertThrowsError(try ChatReply.continueClaude(id, arguments: args, folder: "/tmp", stopIdleBackground: true, commands: interactive.commands))
        XCTAssertEqual(interactive.verbs, ["agents"])

        let busy = Fake([String(decoding: rows([row(["id": "c0d2240d", "kind": "background", "pid": 42, "status": "busy"])]), as: UTF8.self)])
        XCTAssertThrowsError(try ChatReply.continueClaude(id, arguments: args, folder: "/tmp", stopIdleBackground: true, commands: busy.commands))
        XCTAssertEqual(busy.verbs, ["agents"])
    }

    func testLocalReplyToAFinishedSessionResumesDirectly() throws {
        let fake = Fake([stoppedListing])
        let args = ChatReply.claudeArguments(sessionID: id, ReplyRequest(text: "go on"))
        _ = try ChatReply.continueClaude(id, arguments: args, folder: "/tmp", stopIdleBackground: false, commands: fake.commands)
        XCTAssertEqual(fake.verbs, ["agents", "--bg"], "A finished background session isn't open: no stop")

        let failing = Fake([idleListing, stoppedListing]); failing.resumeCode = 1
        XCTAssertThrowsError(try ChatReply.continueClaude(id, arguments: args, folder: "/tmp", stopIdleBackground: true, commands: failing.commands)) {
            XCTAssertTrue(($0 as? LocalizedError)?.errorDescription?.hasPrefix("Burro stopped the idle background session, but") == true)
        }
    }

    func testOneReplyPerChatAtATime() {
        let gate = ClaudeReplyGate()
        XCTAssertTrue(gate.enter(id))
        XCTAssertFalse(gate.enter(id.uppercased()))
        gate.leave(id)
        XCTAssertTrue(gate.enter(id))
    }

    // MARK: Queue

    func testQueueNeverSendsAMessageTwiceAcrossARelaunch() throws {
        var queue = ReplyQueue()
        let chat = "claude:\(id)"
        try queue.enqueue(QueuedReply(chatID: chat, request: ReplyRequest(text: "then commit"), queuedAt: now))
        let item = try XCTUnwrap(queue.item(for: chat))
        XCTAssertEqual(ReplyQueue.decision(item, session: session(), missingSince: nil, idleSince: now, now: now.addingTimeInterval(10)), .dispatch)
        queue.markDispatched(chatID: chat, at: now.addingTimeInterval(10))
        let marked = try XCTUnwrap(queue.item(for: chat))
        if case .drop = ReplyQueue.decision(marked, session: session(), missingSince: nil, idleSince: now, now: now.addingTimeInterval(60)) {} else {
            XCTFail("A message that may have gone is never sent again")
        }
        XCTAssertTrue(ReplyQueue.continuesIdleBackground(session()))
        var codex = session(); codex.provider = .codex
        XCTAssertFalse(ReplyQueue.continuesIdleBackground(codex))
        // Files saved before this field existed still load.
        let old = Data(#"{"items":[{"id":"\#(UUID().uuidString)","chatID":"\#(chat)","text":"hi","access":"keep","attachments":[],"queuedAt":1800000000}],"notices":[]}"#.utf8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        XCTAssertNil(try decoder.decode(ReplyQueue.self, from: old).items.first?.dispatchedAt)
    }

    // MARK: Remote script

    private func temporaryHome() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-continue-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// A fake `claude` that keeps its sessions in $HOME/agents.json (a stop marks the background
    /// one stopped unless $HOME/ignore-stop exists), and a fake `ps` reading $HOME/ps.txt.
    private func install(home: URL, agents: [[String: Any]]) throws {
        try rows(agents).write(to: home.appendingPathComponent("agents.json"))
        try Data().write(to: home.appendingPathComponent("ps.txt"))
        let claude = """
        #!/usr/bin/python3 -I
        import json, os, sys
        home = os.environ["HOME"]
        open(os.path.join(home, "calls.log"), "a").write(" ".join(sys.argv[1:]) + "\\n")
        path = os.path.join(home, "agents.json")
        rows = json.load(open(path))
        if sys.argv[1:3] == ["agents", "--json"]:
            print(json.dumps(rows))
        elif sys.argv[1] == "stop":
            if not os.path.exists(os.path.join(home, "ignore-stop")):
                for r in rows:
                    if r.get("id") == sys.argv[2]:
                        for k in ("pid", "status"): r.pop(k, None)
                        r["state"] = "stopped"
                json.dump(rows, open(path, "w"))
        elif sys.argv[1] == "--bg":
            print("Resumed " + sys.argv[3] + " in the background")
        """
        let ps = "#!/bin/sh\ncat \"$HOME/ps.txt\"\n"
        for (name, body) in [("claude", claude), ("ps", ps)] {
            let url = home.appendingPathComponent(".local/bin/\(name)")
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    private func remoteReply(_ request: [String: Any], home: URL) throws -> [String: Any] {
        let body = try Data(contentsOf: try XCTUnwrap(RemoteScript.url("remote_reply")))
        var input = Data("REQUEST_B64 = \"\(try JSONSerialization.data(withJSONObject: request).base64EncodedString())\"\n".utf8)
        input.append(body)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(input); try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any], String(decoding: out, as: UTF8.self))
    }
    private func calls(_ home: URL) -> [String] {
        ((try? String(contentsOf: home.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    private var argv: [String] { ChatReply.claudeArguments(sessionID: id, ReplyRequest(text: "go on")) }

    func testRemoteContinueStopsThenResumesInOrder() throws {
        let home = try temporaryHome()
        try install(home: home, agents: [row(idleRow)])
        let check = try remoteReply(["check": id], home: home)
        XCTAssertTrue(ChatReply.remoteCheck(try JSONSerialization.data(withJSONObject: check), host: "devbox").continues)

        let plain = try remoteReply(["args": argv, "cwd": "/tmp"], home: home)
        XCTAssertEqual(plain["ok"] as? Bool, false, "The plain send still refuses an open session")
        XCTAssertFalse(calls(home).contains { $0.hasPrefix("stop") || $0.hasPrefix("--bg") })

        // A handle in the request is never used: the script looks it up itself.
        let result = try remoteReply(["continue": argv, "cwd": "/tmp", "handle": "deadbeef", "stop": "x"], home: home)
        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        let verbs = calls(home)
        let stop = try XCTUnwrap(verbs.lastIndex(of: "stop c0d2240d"))
        let resume = try XCTUnwrap(verbs.lastIndex { $0.hasPrefix("--bg --resume \(id)") })
        XCTAssertLessThan(stop, resume)
        XCTAssertTrue(verbs[(stop + 1)..<resume].contains { $0.hasPrefix("agents --json") }, "Confirmed stopped before resuming")
        XCTAssertFalse(verbs.contains("stop deadbeef"))
        XCTAssertEqual(verbs.filter { $0.hasPrefix("stop") }, ["stop c0d2240d"])

        // Now finished: the next reply resumes directly.
        _ = try remoteReply(["continue": argv, "cwd": "/tmp"], home: home)
        XCTAssertEqual(calls(home).filter { $0.hasPrefix("stop") }.count, 1)
    }

    func testRemoteContinueSendsNothingWhenStillRunning() throws {
        let home = try temporaryHome()
        try install(home: home, agents: [row(idleRow)])
        try Data().write(to: home.appendingPathComponent("ignore-stop"))
        let result = try remoteReply(["continue": argv, "cwd": "/tmp"], home: home)
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertTrue((result["error"] as? String)?.contains("nothing was sent") == true)
        XCTAssertTrue(calls(home).contains("stop c0d2240d"))
        XCTAssertFalse(calls(home).contains { $0.hasPrefix("--bg") }, "Still running after the stop: nothing sent")
    }

    func testRemoteContinueRefusesInteractiveBusyWaitingAndAttached() throws {
        let cases: [(String, [String: Any])] = [
            ("interactive", ["kind": "interactive", "pid": 7, "status": "idle"]),
            ("busy", ["id": "c0d2240d", "kind": "background", "pid": 42, "status": "busy"]),
            ("waiting", ["id": "c0d2240d", "kind": "background", "pid": 42, "status": "waiting", "state": "blocked"]),
            ("odd handle", ["id": "$(rm -rf ~)", "kind": "background", "pid": 42, "status": "idle"]),
        ]
        for (name, fields) in cases {
            let home = try temporaryHome()
            try install(home: home, agents: [row(fields)])
            XCTAssertEqual(try remoteReply(["continue": argv, "cwd": "/tmp"], home: home)["ok"] as? Bool, false, name)
            XCTAssertFalse(calls(home).contains { $0.hasPrefix("stop") || $0.hasPrefix("--bg") }, name)
        }
        let home = try temporaryHome()
        try install(home: home, agents: [row(idleRow)])
        try "/home/me/.local/bin/claude attach c0d2240d\n".write(to: home.appendingPathComponent("ps.txt"), atomically: true, encoding: .utf8)
        let attached = try remoteReply(["continue": argv, "cwd": "/tmp"], home: home)
        XCTAssertEqual(attached["ok"] as? Bool, false)
        XCTAssertEqual((attached["live"] as? [String: Any])?["attached"] as? Bool, true)
        XCTAssertFalse(calls(home).contains { $0.hasPrefix("stop") || $0.hasPrefix("--bg") }, "Attached in a terminal there")
        for odd: Any in [["--bg", "--resume", id, "--dangerously-skip-permissions", "--", "x"], "stop c0d2240d", 42] {
            let refused = try remoteReply(["continue": odd, "cwd": "/tmp"], home: home)
            XCTAssertTrue((refused["error"] as? String)?.contains("won't run") == true, "\(odd)")
        }
    }
}
