import XCTest
@testable import BurroCore

final class ChatTranscriptFollowTests: XCTestCase {
    private let sent = Date(timeIntervalSince1970: 1_800_000_000)
    private func user(_ id: Int, _ text: String, at: Date?) -> ChatMessage { ChatMessage(id: id, kind: .user, text: text, at: at) }
    private func reply(_ id: Int, _ text: String, at: Date? = nil) -> ChatMessage { ChatMessage(id: id, kind: .assistant, text: text, at: at) }

    // MARK: Echoes

    func testAnEchoWaitsUntilTheLogHasTheReplyAndIsNeverShownTwice() {
        let before = [user(0, "Fix it", at: sent.addingTimeInterval(-600)), reply(1, "Done.")]
        let echo = ChatEchoes.make("  Run the tests\n", sent: sent, logged: before)
        XCTAssertEqual(ChatEchoes.pending([echo], logged: before, now: sent.addingTimeInterval(2)), [echo])
        let shown = ChatEchoes.merged(ChatTranscript(messages: before), echoes: [echo])
        XCTAssertEqual(shown.messages.map(\.sending), [false, false, true])
        XCTAssertEqual(Set(shown.messages.map(\.id)).count, 3)
        // The logged copy arrives (whitespace differs; the provider's clock is a little behind).
        let after = before + [user(2, "Run the tests", at: sent.addingTimeInterval(-3))]
        XCTAssertEqual(ChatEchoes.pending([echo], logged: after, now: sent.addingTimeInterval(4)), [])
        XCTAssertEqual(ChatEchoes.merged(ChatTranscript(messages: after), echoes: []).messages.filter { $0.text == "Run the tests" }.count, 1)
    }

    func testAnOlderMessageWithTheSameTextDoesNotSettleANewEcho() {
        let old = [user(0, "continue", at: sent.addingTimeInterval(-300))]
        let echo = ChatEchoes.make("continue", sent: sent, logged: old)
        XCTAssertEqual(ChatEchoes.pending([echo], logged: old, now: sent.addingTimeInterval(5)), [echo])
        // Untimed logs (no timestamps): counted at send time instead.
        let untimed = [user(0, "continue", at: nil)]
        let second = ChatEchoes.make("continue", sent: sent, logged: untimed)
        XCTAssertEqual(second.earlier, 1)
        XCTAssertEqual(ChatEchoes.pending([second], logged: untimed, now: sent), [second])
        XCTAssertEqual(ChatEchoes.pending([second], logged: untimed + [user(1, "continue", at: nil)], now: sent), [])
    }

    func testEachLoggedMessageSettlesOneEcho() {
        let first = ChatEcho(text: "yes", sent: sent), second = ChatEcho(text: "yes", sent: sent.addingTimeInterval(1))
        let logged = [user(0, "yes", at: sent.addingTimeInterval(0.5))]
        XCTAssertEqual(ChatEchoes.pending([second, first], logged: logged, now: sent.addingTimeInterval(2)), [second])
        XCTAssertEqual(ChatEchoes.pending([first, second], logged: logged + [user(1, "yes", at: sent.addingTimeInterval(1.2))],
                                          now: sent.addingTimeInterval(2)), [])
    }

    func testAttachmentsAndCutMessagesStillMatchButOtherTextAndRepliesDoNot() {
        let echo = ChatEcho(text: "Look at this", sent: sent)
        XCTAssertEqual(ChatEchoes.pending([echo], logged: [user(0, "Look at this\n/tmp/shot.png", at: sent)], now: sent), [])
        XCTAssertEqual(ChatEchoes.pending([echo], logged: [reply(0, "Look at this", at: sent)], now: sent), [echo])
        XCTAssertEqual(ChatEchoes.pending([echo], logged: [user(0, "Look", at: sent)], now: sent), [echo])
        let long = String(repeating: "word ", count: 3000)
        let cut = String(long.prefix(12_000)) + "…"
        XCTAssertEqual(ChatEchoes.pending([ChatEcho(text: long, sent: sent)], logged: [user(0, cut, at: sent)], now: sent), [])
    }

    func testAnEchoTheLogNeverShowsIsDropped() {
        let echo = ChatEcho(text: "hello", sent: sent)
        XCTAssertEqual(ChatEchoes.pending([echo], logged: [], now: sent.addingTimeInterval(ChatEchoes.window - 1)), [echo])
        XCTAssertEqual(ChatEchoes.pending([echo], logged: [], now: sent.addingTimeInterval(ChatEchoes.window + 1)), [])
        // A sending echo never settles another echo.
        let shown = ChatEchoes.merged(ChatTranscript(messages: []), echoes: [echo])
        XCTAssertEqual(ChatEchoes.pending([ChatEcho(text: "hello", sent: sent)], logged: shown.messages, now: sent).count, 1)
    }

    // MARK: Following

    func testNewMessagesAreCountedAfterTheLastOneSeen() {
        let messages = [user(0, "Go", at: sent), reply(1, "Working", at: sent.addingTimeInterval(1))]
        let mark = ChatFollow.mark(messages)
        XCTAssertEqual(ChatFollow.newCount(messages, after: mark), 0)
        let more = messages + [reply(2, "Step", at: sent.addingTimeInterval(2)), reply(3, "Done", at: sent.addingTimeInterval(3))]
        XCTAssertEqual(ChatFollow.newCount(more, after: mark), 2)
        // Your own reply still sending isn't news, and isn't what was last seen.
        let sending = more + [ChatMessage(id: 4, kind: .user, text: "Thanks", at: sent.addingTimeInterval(4), sending: true)]
        XCTAssertEqual(ChatFollow.newCount(sending, after: mark), 2)
        XCTAssertEqual(ChatFollow.mark(sending), ChatFollow.mark(more))
        // The seen message scrolled out of the window: fall back to its time.
        let slid = Array(more.dropFirst(2)) + [reply(5, "Later", at: sent.addingTimeInterval(9))]
        XCTAssertEqual(ChatFollow.newCount(slid, after: mark), 3)
    }

    // MARK: Worker protocol

    func testUnchangedBatchesAreValidOnlyEmptyAndWithARevision() throws {
        let unchanged = try JSONDecoder().decode(TranscriptBatch.self, from: Data(#"{"found":true,"messages":[],"truncated":false,"revision":7,"unchanged":true}"#.utf8))
        XCTAssertTrue(unchanged.valid(for: 10))
        XCTAssertEqual(unchanged.revision, 7)
        let bad = try JSONDecoder().decode(TranscriptBatch.self, from: Data(#"{"found":true,"messages":[{"kind":"user","text":"x"}],"revision":7,"unchanged":true}"#.utf8))
        XCTAssertFalse(bad.valid(for: 10))
        let noRevision = try JSONDecoder().decode(TranscriptBatch.self, from: Data(#"{"found":true,"messages":[],"unchanged":true}"#.utf8))
        XCTAssertFalse(noRevision.valid(for: 10))
        // The SSH script never sends either field.
        let remote = try JSONDecoder().decode(TranscriptBatch.self, from: Data(#"{"found":true,"messages":[{"kind":"user","text":"x"}]}"#.utf8))
        XCTAssertTrue(remote.valid(for: 10))
        XCTAssertNil(remote.revision)
    }

    func testFilePathsMustStayInsideTheRoot() {
        let root = "/Users/me/Library/Caches/Burro/Remote"
        XCTAssertTrue(ChatTranscripts.inside(root + "/host/chats/codex-1.jsonl", root: root))
        XCTAssertTrue(ChatTranscripts.inside(root + "/a.jsonl", root: root + "/"))
        for path in [root + "/../x.jsonl", root + "/host/./a.jsonl", root + "//a.jsonl", root + "/a.txt", root + "x/a.jsonl",
                     "relative/a.jsonl", root + "/.jsonl", root + "/" + Array(repeating: "d", count: 9).joined(separator: "/") + "/a.jsonl"] {
            XCTAssertFalse(ChatTranscripts.inside(path, root: root), path)
        }
        XCTAssertFalse(ChatTranscripts.inside("/a.jsonl", root: "/"))
    }

    // MARK: Rust worker (file reads, incremental state)

    private func executable() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(".build/rust/release/burro-log-worker")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            if ProcessInfo.processInfo.environment["BURRO_REQUIRE_RUST_WORKER"] == "1" { XCTFail("Required Rust worker missing") }
            throw XCTSkip("Run script/build_rust_worker.sh for Rust integration tests")
        }
        return url
    }

    private func line(_ text: String, role: String = "user") -> String {
        role == "user" ? #"{"type":"user","message":{"content":"\#(text)"}}"#
            : #"{"type":"assistant","message":{"content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    func testReadingACachedFileAnswersUnchangedAndPicksUpAppends() throws {
        let worker = AgentLogWorker(executable: try executable(), retryDelay: 0); defer { worker.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("burro-transcript-file-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let chats = root.appendingPathComponent("host/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let file = chats.appendingPathComponent("claude-chat.jsonl")
        try (line("Fix the login") + "\n" + line("On it.", role: "assistant") + "\n").write(to: file, atomically: false, encoding: .utf8)
        let read = { (revision: UInt64?) in
            try ChatTranscripts.read(file: file.path, provider: .claude, root: root.path, limit: 50, after: revision, worker: worker)
        }
        guard case .loaded(let first, let revision?) = try read(nil) else { return XCTFail("expected a revision") }
        XCTAssertEqual(first.messages.map(\.text), ["Fix the login", "On it."])
        XCTAssertEqual(try read(revision), .unchanged)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data((line("Fixed.", role: "assistant") + "\n").utf8)); try handle.close()
        guard case .loaded(let grown, let next?) = try read(revision) else { return XCTFail("expected new messages") }
        XCTAssertGreaterThan(next, revision)
        XCTAssertEqual(grown.messages.map(\.text), ["Fix the login", "On it.", "Fixed."])
        // The convenience form returns the whole transcript.
        XCTAssertEqual(try ChatTranscripts.read(file: file.path, provider: .claude, root: root.path, limit: 50, after: nil, worker: worker).transcript, grown)

        // Missing and symlinked files read as not found; the worker stays usable afterwards.
        XCTAssertThrowsError(try ChatTranscripts.read(file: chats.appendingPathComponent("gone.jsonl").path, provider: .claude, root: root.path,
                                                      limit: 50, after: nil, worker: worker)) { XCTAssertEqual($0 as? ChatTranscripts.LoadError, .notFound) }
        let link = chats.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try ChatTranscripts.read(file: link.path, provider: .claude, root: root.path, limit: 50, after: nil, worker: worker)) {
            XCTAssertEqual($0 as? ChatTranscripts.LoadError, .notFound)
        }
        XCTAssertThrowsError(try ChatTranscripts.read(file: root.deletingLastPathComponent().appendingPathComponent("x.jsonl").path, provider: .claude,
                                                      root: root.path, limit: 50, after: nil, worker: worker)) {
            XCTAssertEqual($0 as? ChatTranscripts.LoadError, .unsupported)
        }
        XCTAssertEqual(try read(next), .unchanged)
    }

    func testAWorkerWithoutRevisionsIsTreatedAsUnavailable() throws {
        // Stands in for a stale worker binary: it answers transcript requests without a revision.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-stale-worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("worker")
        try """
        #!/usr/bin/python3 -I
        import json, sys
        for raw in sys.stdin:
            request = json.loads(raw)
            print(json.dumps({"version": 4, "id": request["id"], "results": [], "reads": 0, "cacheHits": 0,
                              "transcript": {"found": True, "messages": [{"kind": "user", "text": "hi"}], "truncated": False}}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let worker = AgentLogWorker(executable: script, retryDelay: 0); defer { worker.stop() }
        let chats = folder.appendingPathComponent("chats")
        XCTAssertThrowsError(try ChatTranscripts.read(file: chats.appendingPathComponent("a.jsonl").path, provider: .codex, root: folder.path,
                                                      limit: 50, after: nil, worker: worker)) {
            guard case .unavailable = $0 as? ChatTranscripts.LoadError else { return XCTFail("\($0)") }
        }
    }
}
