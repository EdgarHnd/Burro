import XCTest
@testable import BurroCore

final class TodoLedgerTests: XCTestCase {
    private func item(_ id: String, done: Bool = false, day: String = "2026-11-09", order: Double = 1, doneAt: Double? = nil) -> TodoItem {
        TodoItem(id: id, text: id, day: day, done: done, doneAt: doneAt, order: order, createdAt: order, updatedAt: order)
    }

    func testQueueFoldsChangesToTheSameTodo() {
        var queue: [TodoOp] = []
        queue = TodoLedger.enqueue(.add(clientId: "abc12345", text: "Draft", day: "2026-11-09", project: nil), into: queue)
        queue = TodoLedger.enqueue(.edit(id: "local:abc12345", text: "Final"), into: queue)
        XCTAssertEqual(queue, [.add(clientId: "abc12345", text: "Final", day: "2026-11-09", project: nil)], "edits fold into an unsynced add")
        queue = TodoLedger.enqueue(.setDone(id: "local:abc12345", done: true), into: queue)
        queue = TodoLedger.enqueue(.setDone(id: "local:abc12345", done: false), into: queue)
        XCTAssertEqual(queue.count, 2, "only the last tick is kept")
        queue = TodoLedger.enqueue(.remove(id: "local:abc12345"), into: queue)
        XCTAssertTrue(queue.isEmpty, "removing an unsynced to-do erases it entirely")

        queue = TodoLedger.enqueue(.edit(id: "srv1", text: "a"), into: [])
        queue = TodoLedger.enqueue(.edit(id: "srv1", text: "b"), into: queue)
        queue = TodoLedger.enqueue(.remove(id: "srv1"), into: queue)
        XCTAssertEqual(queue, [.remove(id: "srv1")], "a synced to-do keeps only its removal")
    }

    func testRemapPointsLaterChangesAtTheServerRow() {
        let queue: [TodoOp] = [.setDone(id: "local:x", done: true), .edit(id: "other", text: "t"), .remove(id: "local:x")]
        XCTAssertEqual(TodoLedger.remap(queue, from: "local:x", to: "srv9"),
                       [.setDone(id: "srv9", done: true), .edit(id: "other", text: "t"), .remove(id: "srv9")])
    }

    func testViewShowsOpenThroughTodayThenFinishedToday() {
        let base = [item("future", day: "2026-11-10"), item("overdue", day: "2026-11-01", order: 5), item("today", order: 2),
                    item("doneToday", done: true, doneAt: 2_000), item("doneBefore", done: true, doneAt: 10)]
        let pending: [TodoOp] = [.add(clientId: "newone12", text: "New", day: "2026-11-09", project: nil), .setDone(id: "today", done: true)]
        let view = TodoLedger.view(base: base, pending: pending, day: "2026-11-09", doneSince: 1_000, now: 3_000)
        XCTAssertEqual(view.map(\.id), ["overdue", "local:newone12", "doneToday", "today"])
        XCTAssertEqual(TodoLedger.clean("  ship   it \n"), "ship it")
        XCTAssertNil(TodoLedger.clean(" \n "))
    }

    func testDayKeysFollowTheLocalCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let midnight: TimeInterval = 1_794_150_000 // 2026-11-08T15:00Z = 2026-11-09 00:00 in Seoul
        let date = Date(timeIntervalSince1970: midnight + 5 * 3600 + 20 * 60)
        XCTAssertEqual(TodoDay.key(date, calendar: calendar), "2026-11-09")
        XCTAssertEqual(TodoDay.startMillis(date, calendar: calendar), midnight * 1000)
        XCTAssertEqual(TodoDay.key(Date(timeIntervalSince1970: midnight - 1), calendar: calendar), "2026-11-08")
    }

    func testMauriceSecretsParseAndRejectNonConvexHosts() {
        let text = """
        // Local secrets — gitignored.
        CONVEX_URL = https:/$()/example-123.convex.cloud
        EDGAR_API_TOKEN = abcdefghijklmnopqrstuvwxyz012345
        """
        let config = ConvexConfig.parseXcconfig(text)
        XCTAssertEqual(config?.url.absoluteString, "https://example-123.convex.cloud")
        XCTAssertEqual(config?.token, "abcdefghijklmnopqrstuvwxyz012345")
        XCTAssertNil(ConvexConfig.validURL("http://example.convex.cloud"))
        XCTAssertNil(ConvexConfig.validURL("https://evil.example.com"))
        XCTAssertNil(ConvexConfig.parseXcconfig("CONVEX_URL = https://x.convex.cloud\nEDGAR_API_TOKEN = short"))
    }

    func testConvexEnvelopeDecodesNullAndRefusals() throws {
        let ok = try JSONDecoder().decode(ConvexClient.Envelope<ConvexVoid>.self, from: Data(#"{"status":"success","value":null}"#.utf8))
        XCTAssertNotNil(ok.value)
        let refused = try JSONDecoder().decode(ConvexClient.Envelope<String>.self,
            from: Data(#"{"status":"error","errorMessage":"[Request ID: x] Server Error","errorData":"Write the to-do first."}"#.utf8))
        XCTAssertNil(refused.value)
        XCTAssertEqual(refused.errorData?.message, "Write the to-do first.")
        let items = try JSONDecoder().decode(ConvexClient.Envelope<[TodoItem]>.self, from: Data(#"""
        {"status":"success","value":[{"id":"k1","text":"Run","day":"2026-11-09","done":false,"doneAt":null,"order":1.0,"source":"burro","project":null,"createdAt":1.0,"updatedAt":1.0}]}
        """#.utf8))
        XCTAssertEqual(items.value?.first?.text, "Run")
    }
}

final class AgentLaunchTests: XCTestCase {
    func testWebSocketFramesRoundTripAtEachLengthEncoding() throws {
        for size in [5, 300, 70_000] {
            let payload = Data((0..<size).map { UInt8($0 % 251) })
            var buffer = WebSocketFrames.encode(payload, mask: [9, 8, 7, 6])
            var partial = Data(buffer.prefix(3))
            XCTAssertNil(try WebSocketFrames.decode(&partial), "incomplete frames wait for more bytes")
            let frame = try XCTUnwrap(WebSocketFrames.decode(&buffer))
            XCTAssertEqual(frame.payload, payload)
            XCTAssertEqual(frame.opcode, 1)
            XCTAssertTrue(buffer.isEmpty)
        }
        var server = Data([0x81, 0x02]) + Data("hi".utf8) + Data([0x89, 0x00])
        XCTAssertEqual(try WebSocketFrames.decode(&server)?.payload, Data("hi".utf8), "server frames are unmasked")
        XCTAssertEqual(try WebSocketFrames.decode(&server)?.opcode, 0x9)
    }

    func testClaudeArgumentsKeepThePromptOutOfFlagParsing() {
        let request = LaunchRequest(provider: .claude, prompt: "  --delete everything? no: fix the build  ", folder: "/tmp",
                                    model: "claude-opus-5-5", effort: "high", access: .readOnly)
        XCTAssertEqual(ClaudeLaunch.arguments(for: request),
                       ["--bg", "--permission-mode", "plan", "--model", "claude-opus-5-5", "--effort", "high", "--", "--delete everything? no: fix the build"])
        XCTAssertEqual(LaunchAccess.ask.claudeMode, "manual")
        XCTAssertEqual(LaunchAccess.edit.claudeMode, "acceptEdits")
    }

    func testClaudeOutputAndAgentListParsing() {
        let output = "  claude agents             list sessions\n  claude attach c6085a95    open in this terminal\n"
        XCTAssertEqual(ClaudeLaunch.handle(fromOutput: output), "c6085a95")
        XCTAssertNil(ClaudeLaunch.handle(fromOutput: "Workspace not trusted."))
        let agents = Data(#"[{"id":"aaaa1111","sessionId":"aaaa1111-0000"},{"id":"c6085a95","sessionId":"c6085a95-ddb5-4b2a"}]"#.utf8)
        XCTAssertEqual(ClaudeLaunch.sessionID(handle: "c6085a95", agentsJSON: agents), "c6085a95-ddb5-4b2a")
    }

    func testCodexParamsAndModelList() {
        let request = LaunchRequest(provider: .codex, prompt: "Ship it", folder: "/dev/app", model: "gpt-6-luna", effort: "low", access: .ask)
        let thread = CodexLaunch.threadParams(for: request)
        XCTAssertEqual(thread["sandbox"] as? String, "workspace-write")
        XCTAssertEqual(thread["approvalPolicy"] as? String, "on-request")
        XCTAssertEqual(thread["cwd"] as? String, "/dev/app")
        let turn = CodexLaunch.turnParams(threadID: "t1", for: request)
        XCTAssertEqual(turn["effort"] as? String, "low")
        XCTAssertEqual((turn["input"] as? [[String: String]])?.first?["text"], "Ship it")
        XCTAssertEqual(LaunchAccess.readOnly.codexSandbox, "read-only")
        XCTAssertEqual(LaunchAccess.edit.codexApproval, "never")
        let models = CodexLaunch.models(from: ["data": [
            ["id": "gpt-6.1-sol", "displayName": "GPT-6.1-Sol", "isDefault": true, "defaultReasoningEffort": "low",
             "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "high"]]],
            ["id": "secret", "hidden": true],
        ]])
        XCTAssertEqual(models, [LaunchModel(id: "gpt-6.1-sol", title: "GPT-6.1-Sol", efforts: ["low", "high"], defaultEffort: "low", isDefault: true)])
    }

    /// Opt-in: talks to the real Codex daemon (read-only `model/list`; starts the daemon if needed).
    func testLiveCodexModelList() throws {
        guard ProcessInfo.processInfo.environment["BURRO_LIVE_CODEX"] == "1" else { throw XCTSkip("set BURRO_LIVE_CODEX=1") }
        let models = try CodexLaunch.listModels()
        XCTAssertFalse(models.isEmpty)
        XCTAssertTrue(models.contains { $0.isDefault })
    }
}
