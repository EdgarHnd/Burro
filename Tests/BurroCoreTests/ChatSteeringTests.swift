// Stop, steer, queue, attachments, managing and Seen in Burro: every provider request is checked
// as plain data, the composer's choices per chat state, the queue's dispatch rules and file, the
// local title/pin/hide and seen sets, and the remote script's stop and check with a fake Claude
// under a temporary HOME. Nothing here talks to a real chat.
import XCTest
@testable import BurroCore

final class ChatSteeringTests: XCTestCase {
    private let id = "11111111-2222-4333-8444-555555555555"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ provider: AgentProvider, state: AgentState = .idle, remote: RemoteHost? = nil, updated: Date? = nil) -> AgentSession {
        var value = AgentSession(id: "\(provider == .codex ? "codex" : "claude"):\(id)", provider: provider, title: "x", cwd: "/tmp",
                                 state: state, updatedAt: updated ?? now, evidence: "fixture")
        if let remote {
            value.remote = RemoteOrigin(hostID: remote.id, hostName: remote.name, sampledAt: now, stale: false)
            value.id = "remote:\(remote.id.uuidString):\(value.id)"
        }
        return value
    }
    private let host = RemoteHost(name: "devbox", destination: "me@devbox")
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-steer-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    // MARK: Codex requests

    func testCodexStopAndSteerTargetTheRunningTurn() {
        XCTAssertEqual(ChatReply.codexTurnsListParams(threadID: id)["limit"] as? Int, 1)
        XCTAssertEqual(ChatReply.codexTurnsListParams(threadID: id)["itemsView"] as? String, "notLoaded")
        let running: [String: Any] = ["data": [["id": "t-2", "status": "inProgress"], ["id": "t-1", "status": "completed"]]]
        XCTAssertEqual(ChatReply.codexActiveTurn(running), "t-2")
        XCTAssertNil(ChatReply.codexActiveTurn(["data": [["id": "t-1", "status": "completed"]]]), "Nothing to stop once the turn ended")
        XCTAssertNil(ChatReply.codexActiveTurn(["data": [["id": "", "status": "inProgress"]]]))
        XCTAssertNil(ChatReply.codexActiveTurn([:]))
        let stop = ChatReply.codexInterruptParams(threadID: id, turnID: "t-2")
        XCTAssertEqual(stop as NSDictionary, ["threadId": id, "turnId": "t-2"] as NSDictionary)
        let steer = ChatReply.codexSteerParams(threadID: id, turnID: "t-2", ReplyRequest(text: "  also the docs  ", attachments: ["/x/a.png"]))
        XCTAssertEqual(steer["expectedTurnId"] as? String, "t-2")
        XCTAssertEqual(steer["threadId"] as? String, id)
        let input = steer["input"] as? [[String: Any]]
        XCTAssertEqual(input?.first?["text"] as? String, "also the docs")
        XCTAssertEqual(input?.last?["type"] as? String, "localImage")
        XCTAssertEqual(input?.last?["path"] as? String, "/x/a.png")
    }

    func testCodexRenameAndArchiveRequests() {
        XCTAssertEqual(ChatProviderManage.codexRenameParams(threadID: id, name: "  Fix the\nbuild ")! as NSDictionary,
                       ["threadId": id, "name": "Fix the build"] as NSDictionary)
        XCTAssertNil(ChatProviderManage.codexRenameParams(threadID: id, name: "   "))
        XCTAssertNil(ChatProviderManage.codexRenameParams(threadID: id, name: String(repeating: "a", count: 201)))
        XCTAssertEqual(ChatProviderManage.codexArchiveParams(threadID: id) as NSDictionary, ["threadId": id] as NSDictionary)
        XCTAssertEqual(ChatProviderManage.codexThread(session(.codex)), id)
        XCTAssertNil(ChatProviderManage.codexThread(session(.claude)), "Claude chats are managed in Burro only")
        XCTAssertThrowsError(try ChatProviderManage.rename(session(.claude), to: "x", host: nil))
        XCTAssertThrowsError(try ChatProviderManage.archive(session(.codex, remote: host), host: nil), "A remote chat needs its machine")
    }

    // MARK: Claude stop

    func testClaudeStopsOnlyBackgroundSessionsByHexHandle() {
        XCTAssertEqual(ChatReply.claudeStopArguments(handle: "c0d2240d"), ["stop", "c0d2240d"])
        XCTAssertNil(ChatReply.claudeStopArguments(handle: "$(rm -rf ~)"))
        XCTAssertNil(ChatReply.claudeStopArguments(handle: "--all"))
        XCTAssertEqual(ChatReply.claudeStop(.init(handle: "c0d2240d", background: true, busy: true), remote: false), .claudeBackground(handle: "c0d2240d"))
        XCTAssertEqual(ChatReply.claudeStop(.init(handle: "c0d2240d", background: true, busy: true), remote: true), .claudeRemote)
        XCTAssertEqual(ChatReply.claudeStop(.init(handle: nil, background: false, busy: true), remote: false), .elsewhere)
        XCTAssertNil(ChatReply.claudeStop(.init(handle: nil, background: true, busy: true), remote: false))
        XCTAssertNil(ChatReply.claudeStop(nil, remote: false))
    }

    func testRemoteCheckReadsTheLiveSession() {
        let busy = ChatReply.remoteCheck(Data(#"{"ok":false,"error":"busy","live":{"kind":"background","busy":true,"handle":"abc123"}}"#.utf8), host: "devbox")
        XCTAssertTrue(busy.busy); XCTAssertTrue(busy.background); XCTAssertEqual(busy.attach, "abc123")
        let odd = ChatReply.remoteCheck(Data(#"{"ok":false,"error":"x","live":{"kind":"background","busy":false,"handle":"$(x)"}}"#.utf8), host: "devbox")
        XCTAssertNil(odd.attach, "Odd handles are never passed on")
        XCTAssertNotNil(odd.problem)
        let desktop = ChatReply.remoteCheck(Data(#"{"ok":false,"error":"x","live":{"kind":"interactive","busy":false,"handle":null}}"#.utf8), host: "devbox")
        XCTAssertTrue(desktop.open); XCTAssertFalse(desktop.background)
        XCTAssertEqual(ChatReply.remoteCheck(Data(#"{"ok":true,"output":""}"#.utf8), host: "devbox"), ChatReply.ClaudeCheck())
        XCTAssertEqual(ChatReply.remoteCheck(Data(#"{"ok":false,"error":"Claude Code isn't installed on this machine."}"#.utf8), host: "devbox").problem,
                       "Claude Code isn't installed on this machine.")
        XCTAssertNotNil(ChatReply.remoteCheck(Data("garbage".utf8), host: "devbox").problem)
    }

    // MARK: Composer

    func testComposerOffersTheRightChoices() {
        func plan(_ s: AgentSession, host: RemoteHost? = nil, check: ChatReply.ClaudeCheck? = nil, setup: String? = nil, queued: Bool = false, url: Bool = true) -> ComposerPlan {
            ChatReply.composerPlan(s, host: host, check: check, setupProblem: setup, queued: queued, hasURL: url)
        }
        let idle = plan(session(.codex))
        XCTAssertTrue(idle.canSend && idle.showPickers && idle.attachments); XCTAssertNil(idle.reason); XCTAssertNil(idle.stop)

        let codexWorking = plan(session(.codex, state: .working))
        XCTAssertTrue(codexWorking.canType && codexWorking.canQueue && codexWorking.canSteer)
        XCTAssertFalse(codexWorking.canSend || codexWorking.showPickers)
        XCTAssertEqual(codexWorking.stop, .codex)
        XCTAssertFalse(plan(session(.codex, state: .working), queued: true).canQueue, "Never more than one queued message per chat")

        let background = ChatReply.claudePlan(.init(handle: "c0d2240d", background: true, busy: true))
        let claudeWorking = plan(session(.claude, state: .working), check: background)
        XCTAssertTrue(claudeWorking.canQueue); XCTAssertFalse(claudeWorking.canSteer); XCTAssertFalse(claudeWorking.canSend)
        XCTAssertEqual(claudeWorking.stop, .claudeBackground(handle: "c0d2240d"))
        XCTAssertEqual(plan(session(.claude, state: .working, remote: host), host: host, check: background).stop, .claudeRemote)
        XCTAssertFalse(plan(session(.claude, state: .working, remote: host), host: host, check: background).attachments, "Attachments are local only")

        let desktop = ChatReply.claudePlan(.init(handle: nil, background: false, busy: true))
        let desktopWorking = plan(session(.claude, state: .working), check: desktop)
        XCTAssertEqual(desktopWorking.stop, .elsewhere); XCTAssertFalse(desktopWorking.canType); XCTAssertNotNil(desktopWorking.reason)

        let unchecked = plan(session(.claude, state: .working))
        XCTAssertTrue(unchecked.canQueue); XCTAssertNil(unchecked.stop)

        // Busy in `claude agents` before monitoring notices: queue is the one action.
        let busyIdle = plan(session(.claude), check: background)
        XCTAssertEqual(busyIdle.action, .queue); XCTAssertNotNil(busyIdle.reason)

        let attach = plan(session(.claude), check: ChatReply.claudePlan(.init(handle: "c0d2240d", background: true, busy: false)))
        XCTAssertEqual(attach.action, .attachInTerminal(handle: "c0d2240d")); XCTAssertFalse(attach.canType); XCTAssertFalse(attach.showPickers)
        let remoteAttach = plan(session(.claude, remote: host), host: host, check: ChatReply.claudePlan(.init(handle: "c0d2240d", background: true, busy: false)))
        XCTAssertEqual(remoteAttach.action, .attachOnMachine(handle: "c0d2240d"))
        let open = plan(session(.claude), check: ChatReply.claudePlan(.init(handle: nil, background: false, busy: false)))
        XCTAssertEqual(open.action, .openInProvider)
        XCTAssertNil(plan(session(.claude), check: ChatReply.claudePlan(.init(handle: nil, background: false, busy: false)), url: false).action)

        XCTAssertNotNil(plan(session(.codex, remote: host)).reason, "A remote chat needs its machine")
        let setup = plan(session(.codex, remote: host), host: host, setup: "Codex isn't installed on devbox.")
        XCTAssertEqual(setup.reason, "Codex isn't installed on devbox."); XCTAssertFalse(setup.canType)
        var odd = session(.codex); odd.id = "codex:not-a-uuid"
        XCTAssertEqual(plan(odd).action, .openInProvider)
        var stale = session(.codex, state: .working, remote: host); stale.remote?.stale = true
        XCTAssertNil(plan(stale, host: host).stop, "A machine that isn't answering can't be stopped")
    }

    // MARK: Remote attach

    func testRemoteAttachRunsOnlyTheFixedCommand() throws {
        let args = try XCTUnwrap(RemoteAttach.arguments(host: host, handle: "c0d2240d"))
        XCTAssertEqual(args.first, "-t")
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes") && args.contains("BatchMode=yes"))
        XCTAssertEqual(args[args.count - 2], "me@devbox")
        XCTAssertEqual(args[args.count - 3], "--")
        XCTAssertTrue(args.last!.hasSuffix("exec claude attach c0d2240d'"))
        XCTAssertNil(RemoteAttach.arguments(host: host, handle: "c0d'; rm -rf ~; '"))
        XCTAssertNil(RemoteAttach.arguments(host: RemoteHost(name: "x", destination: "-oProxyCommand=evil"), handle: "c0d2240d"))
        let script = try XCTUnwrap(RemoteAttach.script(host: host, handle: "c0d2240d"))
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh\nexec /usr/bin/ssh '-t' "))
        XCTAssertTrue(script.contains(#"'\''"#), "The remote command's own quotes are escaped for zsh")
    }

    // MARK: Attachments

    func testAttachmentsAreCheckedAndShapedPerProvider() throws {
        let folder = try temporaryFolder()
        let home = folder.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        let key = home.appendingPathComponent(".ssh/id_ed25519")
        try Data("secret".utf8).write(to: key)
        let image = folder.appendingPathComponent("shot.PNG"), notes = folder.appendingPathComponent("notes.txt")
        try Data([1, 2, 3]).write(to: image); try Data("n".utf8).write(to: notes)
        let disguised = folder.appendingPathComponent("fine.txt")
        try FileManager.default.createSymbolicLink(at: disguised, withDestinationURL: key)
        let big = folder.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big); try handle.truncate(atOffset: UInt64(ChatAttachments.maxBytes + 1)); try handle.close()

        XCTAssertEqual(try ChatAttachments.validate(image.path, home: home.path), image.path)
        XCTAssertThrowsError(try ChatAttachments.validate(key.path, home: home.path))
        XCTAssertThrowsError(try ChatAttachments.validate(disguised.path, home: home.path), "Links are judged by what they point at")
        XCTAssertThrowsError(try ChatAttachments.validate(big.path, home: home.path))
        XCTAssertThrowsError(try ChatAttachments.validate(folder.path, home: home.path), "Folders aren't attached")
        XCTAssertThrowsError(try ChatAttachments.validate("relative.png", home: home.path))

        let added = ChatAttachments.adding([image.path, image.path, notes.path, key.path], to: [], home: home.path)
        XCTAssertEqual(added.paths, [image.path, notes.path]); XCTAssertNotNil(added.problem)
        let many = (0..<10).map { _ in notes.path }
        XCTAssertEqual(ChatAttachments.adding(many, to: [], home: home.path).paths.count, 1, "Duplicates are skipped")

        let codex = ChatAttachments.codexInput(text: "look", paths: [image.path, notes.path])
        XCTAssertEqual(codex.count, 2)
        XCTAssertEqual(codex[0]["text"] as? String, "look\n\nAttached file:\n\(notes.path)")
        XCTAssertEqual(codex[1] as NSDictionary, ["type": "localImage", "path": image.path] as NSDictionary)
        XCTAssertEqual(ChatAttachments.claudeText(text: "look", paths: [image.path, notes.path]), "look\n\nAttached files:\n\(image.path)\n\(notes.path)")
        XCTAssertEqual(ChatAttachments.claudeText(text: "look", paths: []), "look")

        XCTAssertEqual(ChatReply.claudeArguments(sessionID: id, ReplyRequest(text: "x", attachments: [notes.path])).last, "x\n\nAttached file:\n\(notes.path)")
        XCTAssertEqual((ChatReply.codexTurnParams(threadID: id, ReplyRequest(text: "x", attachments: [image.path]))["input"] as? [[String: Any]])?.count, 2)
        XCTAssertThrowsError(try ChatReply.send(ReplyRequest(text: "x", attachments: [image.path]), to: session(.codex, remote: host), host: host)) { error in
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, ChatAttachments.localOnly)
        }

        let pasted = try ChatAttachments.savePasted(Data([9, 9]), extension: "png", folder: folder.appendingPathComponent("paste"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: pasted)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("paste").path)[.posixPermissions] as? Int, 0o700)
        XCTAssertThrowsError(try ChatAttachments.savePasted(Data([9]), extension: "sh", folder: folder.appendingPathComponent("paste")))
    }

    // MARK: Queue

    func testQueueHoldsOneMessagePerChatAndDispatchesWhenIdle() throws {
        var queue = ReplyQueue()
        let item = QueuedReply(chatID: "codex:\(id)", request: ReplyRequest(text: "then run the tests", model: "gpt-6", access: .readOnly), queuedAt: now)
        try queue.enqueue(item)
        XCTAssertThrowsError(try queue.enqueue(QueuedReply(chatID: "codex:\(id)", request: ReplyRequest(text: "second"), queuedAt: now)))
        XCTAssertThrowsError(try queue.enqueue(QueuedReply(chatID: "claude:\(id)", request: ReplyRequest(text: "  "), queuedAt: now)))
        XCTAssertEqual(queue.item(for: "codex:\(id)")?.request, ReplyRequest(text: "then run the tests", model: "gpt-6", access: .readOnly))

        func decide(_ s: AgentSession?, missing: Date? = nil, idle: Date? = nil, at: Date? = nil) -> ReplyQueue.Decision {
            ReplyQueue.decision(item, session: s, missingSince: missing, idleSince: idle, now: at ?? now.addingTimeInterval(30))
        }
        XCTAssertEqual(decide(session(.codex, state: .working)), .wait)
        XCTAssertEqual(decide(session(.codex, state: .waiting)), .wait, "A chat asking you something isn't done")
        XCTAssertEqual(decide(session(.codex, state: .idle), idle: nil), .wait)
        XCTAssertEqual(decide(session(.codex, state: .idle), idle: now.addingTimeInterval(29)), .wait, "Idle must settle first")
        XCTAssertEqual(decide(session(.codex, state: .idle), idle: now.addingTimeInterval(20)), .dispatch)
        XCTAssertEqual(decide(session(.codex, state: .inactive), idle: now), .dispatch)
        var stale = session(.codex, state: .idle, remote: host); stale.remote?.stale = true
        XCTAssertEqual(decide(stale, idle: now), .wait)
        XCTAssertEqual(decide(nil, missing: now.addingTimeInterval(10)), .wait, "A brief gap in the feed isn't gone")
        if case .drop = decide(nil, missing: now.addingTimeInterval(-31)) {} else { XCTFail("Gone for a minute drops it") }
        if case .drop = decide(session(.codex, state: .working), at: now.addingTimeInterval(ReplyQueue.expiresAfter)) {} else { XCTFail("Expires after a day") }

        XCTAssertEqual(queue.cancel(chatID: "codex:\(id)")?.text, "then run the tests")
        XCTAssertNil(queue.cancel(chatID: "codex:\(id)"))
        queue.record(ReplyQueueNotice(chatID: "codex:\(id)", text: "a", sent: false, message: "gone", at: now), now: now)
        queue.record(ReplyQueueNotice(chatID: "codex:\(id)", text: "b", sent: true, message: "sent", at: now), now: now)
        XCTAssertEqual(queue.notices.count, 1, "One notice per chat")
        XCTAssertEqual(queue.notice(for: "codex:\(id)")?.text, "b")
        queue.record(ReplyQueueNotice(chatID: "x", text: "c", sent: true, message: "sent", at: now.addingTimeInterval(2 * 86_400)), now: now.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(queue.notices.map(\.chatID), ["x"], "Old notices leave")
    }

    func testQueueFileIsOwnerOnlyAndTolerant() throws {
        let folder = try temporaryFolder()
        let store = ReplyQueueStore(url: folder.appendingPathComponent("Burro/reply-queue.json"))
        XCTAssertEqual(store.load(), ReplyQueue())
        var queue = ReplyQueue()
        try queue.enqueue(QueuedReply(chatID: "claude:\(id)", request: ReplyRequest(text: "hi", attachments: ["/x/a.png"]), queuedAt: now))
        try store.save(queue)
        XCTAssertEqual(store.load(), queue)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.url.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
        try Data("{not json".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), ReplyQueue(), "A damaged file reads as empty")
        let elsewhere = folder.appendingPathComponent("other.json")
        try FileManager.default.removeItem(at: store.url)
        try JSONEncoder().encode(queue).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: elsewhere)
        XCTAssertEqual(store.load(), ReplyQueue(), "Links aren't followed")
    }

    // MARK: Managing and seen

    func testLocalTitlesPinsAndHiddenChats() {
        var manage = ChatManage()
        let a = session(.claude), b = session(.codex, updated: now.addingTimeInterval(-60))
        manage.rename(a.id, to: "  Release notes\n draft ")
        XCTAssertEqual(manage.title(for: a.id), "Release notes  draft")
        XCTAssertEqual(manage.applyingTitles([a, b]).map(\.title), ["Release notes  draft", "x"])
        manage.rename(a.id, to: "   ")
        XCTAssertNil(manage.title(for: a.id), "An empty name goes back to the chat's own")

        manage.setPinned(b.id, true, now: now)
        manage.setPinned(b.id, true, now: now.addingTimeInterval(5))
        XCTAssertEqual(manage.pinned[b.id], now, "Pinning again keeps its place")
        XCTAssertEqual(manage.arrange([a, b]).map(\.id), [b.id, a.id])

        manage.hide(b)
        XCTAssertFalse(manage.isPinned(b.id))
        XCTAssertEqual(manage.arrange([a, b]).map(\.id), [a.id])
        var moved = b; moved.updatedAt = now
        XCTAssertEqual(manage.arrange([a, moved]).map(\.id), [a.id, b.id], "New activity shows a hidden chat again")
        manage.unhide(b.id)
        XCTAssertFalse(manage.isHidden(b))

        XCTAssertEqual(ChatManage.decode(manage.encoded()), manage)
        XCTAssertEqual(ChatManage.decode(Data("[]".utf8)), ChatManage())
        for index in 0..<(ChatManage.limit + 10) { manage.rename("chat-\(index)", to: "t") }
        XCTAssertEqual(manage.titles.count, ChatManage.limit)
    }

    func testSeenInBurroClearsOnlyBurrosCopy() {
        var seen = ChatSeen()
        var done = session(.claude); done.hasUnreadResult = true; done.turnCompleted = true
        var other = session(.codex); other.id = "codex:22222222-3333-4444-8555-666666666666"; other.hasUnreadResult = true
        XCTAssertTrue(done.isDone)
        XCTAssertTrue(seen.mark(done))
        XCTAssertFalse(seen.mark(done), "Marking again changes nothing")
        let applied = seen.applying([done, other])
        XCTAssertFalse(applied[0].isDone)
        XCTAssertEqual(applied[0].hasUnreadResult, false)
        XCTAssertEqual(applied[1].hasUnreadResult, true, "Other chats keep their providers' marker")
        var newer = done; newer.updatedAt = now.addingTimeInterval(10)
        XCTAssertTrue(seen.applying([newer])[0].isDone, "New activity is unread again")
        XCTAssertEqual(ChatSeen.decode(seen.encoded()), seen)
        XCTAssertEqual(ChatSeen.decode(Data("nope".utf8)), ChatSeen())
        for index in 0..<(ChatSeen.limit + 5) {
            var s = session(.codex, updated: now.addingTimeInterval(Double(index))); s.id = "codex:\(index)"
            seen.mark(s)
        }
        XCTAssertEqual(seen.seen.count, ChatSeen.limit)
        XCTAssertNotNil(seen.seen["codex:\(ChatSeen.limit + 4)"], "The newest are kept")
    }

    // MARK: Remote script

    /// Runs remote_reply.py the way Burro sends it, with a fake `claude` under a temporary HOME
    /// that reports one background and one desktop session and records what it was asked to do.
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
        return try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
    }

    func testRemoteScriptStopsOnlyItsBackgroundSession() throws {
        let home = try temporaryFolder()
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = home.appendingPathComponent("calls.log")
        let fake = """
        #!/usr/bin/python3 -I
        import json, sys
        open(\(String(reflecting: log.path)), "a").write(" ".join(sys.argv[1:]) + "\\n")
        if sys.argv[1:3] == ["agents", "--json"]:
            print(json.dumps([{"id": "c0d2240d", "sessionId": "\(id)", "kind": "background", "status": "busy"},
                              {"id": "x", "sessionId": "22222222-3333-4444-8555-666666666666", "kind": "interactive", "status": "busy"}]))
        """
        let claude = bin.appendingPathComponent("claude")
        try fake.write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claude.path)

        let check = try remoteReply(["check": id], home: home)
        XCTAssertEqual(check["ok"] as? Bool, false)
        let live = try XCTUnwrap(check["live"] as? [String: Any])
        XCTAssertEqual(live["kind"] as? String, "background"); XCTAssertEqual(live["busy"] as? Bool, true); XCTAssertEqual(live["handle"] as? String, "c0d2240d")

        XCTAssertEqual(try remoteReply(["stop": id], home: home)["ok"] as? Bool, true)
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("stop c0d2240d\n"))
        let desktop = try remoteReply(["stop": "22222222-3333-4444-8555-666666666666"], home: home)
        XCTAssertEqual(desktop["ok"] as? Bool, false, "Sessions the app or a terminal owns aren't stopped")
        XCTAssertEqual(try remoteReply(["stop": "33333333-4444-4555-8666-777777777777"], home: home)["ok"] as? Bool, false)
        for odd: Any in ["not-a-uuid", "\(id); rm -rf ~", 42] {
            let refused = try remoteReply(["stop": odd], home: home)
            XCTAssertTrue((refused["error"] as? String)?.contains("won't run") == true, "\(odd)")
        }
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(calls.filter { $0.hasPrefix("stop") }, ["stop c0d2240d"], "Only the one background session was stopped")
    }
}
