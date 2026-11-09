import XCTest
import Darwin
@testable import BurroCore

final class AgentLogWorkerTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("burro-worker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func executable() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(".build/rust/release/burro-log-worker")
        if !FileManager.default.isExecutableFile(atPath: url.path) {
            if ProcessInfo.processInfo.environment["BURRO_REQUIRE_RUST_WORKER"] == "1" {
                XCTFail("Required Rust worker missing; run script/build_rust_worker.sh")
                throw CocoaError(.fileNoSuchFile)
            }
            throw XCTSkip("Run script/build_rust_worker.sh for Rust integration tests")
        }
        return url
    }
    private func event(_ kind: String) -> String {
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"\(kind)\"}}"
    }
    private func fakeWorker(in folder: URL, body: String) throws -> URL {
        let url = folder.appendingPathComponent("worker")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func testRustMatchesSwiftForLifecycleFixturesAndLockAges() throws {
        let folder = try fixture(), now = Date()
        let worker = AgentLogWorker(executable: try executable()); defer { worker.stop() }
        var fixtures = ["", "{bad", event("task_complete"), event("turn_complete"), event("task_started"), event("turn_started"),
                        event("task_aborted"), event("turn_aborted"), event("request_user_input"), event("approval_required"),
                        "{\"type\":\"response_item\",\"payload\":{\"type\":\"task_complete\"}}",
                        "{\"type\":\"event_msg\",\"payload\":{\"type\":false}}"]
        for kind in ["turn_started", "task_aborted", "approval_required", "unknown"] {
            fixtures.append(event("task_complete") + "\n" + event(kind) + "\n{partial")
        }
        let paths = try fixtures.enumerated().map { index, text in
            let path = folder.appendingPathComponent("\(index).jsonl")
            try text.write(to: path, atomically: true, encoding: .utf8)
            return path.path
        }
        let batch = try XCTUnwrap(worker.exchange(paths))
        XCTAssertEqual(batch.reads, paths.count)
        for (index, log) in batch.results.enumerated() {
            XCTAssertEqual(log, CodexLogEvidence.swiftRead(paths[index]))
            for held: Int32 in [-1, 0, 1] {
                for age: Double in [0, 119, 120, 299, 300, 900] {
                    var aged = log; aged.modified = now.timeIntervalSince1970 - age
                    XCTAssertEqual(aged.state(held: held, now: now),
                                   AgentParsing.codexState(tail: fixtures[index], held: held,
                                                           modified: now.addingTimeInterval(-age), now: now))
                }
            }
        }
        let cached = try XCTUnwrap(worker.exchange(paths))
        XCTAssertEqual(cached.reads, 0); XCTAssertEqual(cached.cacheHits, paths.count)
    }

    func testAppendTruncateAndAtomicReplacementInvalidateCache() throws {
        let folder = try fixture(), file = folder.appendingPathComponent("session.jsonl")
        let worker = AgentLogWorker(executable: try executable()); defer { worker.stop() }
        try event("task_complete").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(try XCTUnwrap(worker.exchange([file.path])).results[0].completed)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + event("turn_started")).utf8)); try handle.close()
        XCTAssertEqual(try XCTUnwrap(worker.exchange([file.path])).results[0].last, .working)
        try Data().write(to: file)
        XCTAssertNil(try XCTUnwrap(worker.exchange([file.path])).results[0].last)
        try event("approval_required").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try XCTUnwrap(worker.exchange([file.path])).results[0].last, .waiting)
        try FileManager.default.removeItem(at: file)
        let missing = try XCTUnwrap(worker.exchange([file.path])).results[0]
        XCTAssertFalse(missing.readable); XCTAssertFalse(missing.completed)
        XCTAssertEqual(missing.state(held: 1, now: Date()), .unknown)
        XCTAssertEqual(missing.state(held: 0, now: Date()), .unknown)
    }

    func testClaudeCompletionRequestPreservesCodexCache() throws {
        let folder = try fixture(), file = folder.appendingPathComponent("session.jsonl")
        try event("task_started").write(to: file, atomically: true, encoding: .utf8)
        let worker = AgentLogWorker(executable: try executable()); defer { worker.stop() }
        XCTAssertEqual(try XCTUnwrap(worker.exchange([file.path])).reads, 1)
        XCTAssertNotNil(worker.exchange([], completed: folder.path)?.completed)
        let warm = try XCTUnwrap(worker.exchange([file.path]))
        XCTAssertEqual(warm.reads, 0); XCTAssertEqual(warm.cacheHits, 1)
    }

    func testRustCatalogMatchesSwiftAndInvalidatesWALWritesAndRestart() throws {
        let folder = try fixture(), database = folder.appendingPathComponent("state.sqlite")
        let runner = CommandRunner()
        func sql(_ query: String) throws {
            let result = runner.run("/usr/bin/sqlite3", [database.path, query])
            XCTAssertTrue(result.succeeded, result.error)
        }
        try sql("PRAGMA journal_mode=WAL; CREATE TABLE threads(id TEXT,cwd TEXT,title TEXT,updated_at INTEGER,rollout_path TEXT,archived INTEGER,name TEXT,source TEXT,is_pinned INTEGER); INSERT INTO threads VALUES ('id','/tmp','Chat',100,'/tmp/log',0,'Renamed','subagent',1); CREATE TABLE project_roots(path TEXT); INSERT INTO project_roots VALUES('/project'); CREATE TABLE thread_attachments(thread_id TEXT, identity_key TEXT, payload TEXT, attachment_type TEXT); INSERT INTO thread_attachments VALUES('id','/tree','{\"root\":\"/tree\"}','worktree');")
        let worker = AgentLogWorker(executable: try executable()); defer { worker.stop() }
        XCTAssertEqual(try XCTUnwrap(worker.readCatalog(database.path)), try CodexCatalog.swiftRead(database.path))
        XCTAssertEqual(try XCTUnwrap(worker.readCatalog(database.path)), try CodexCatalog.swiftRead(database.path))
        let first = try XCTUnwrap(worker.exchange([], catalog: .init(path: database.path, revision: nil))?.catalog)
        let unchanged = try XCTUnwrap(worker.exchange([], catalog: .init(path: database.path, revision: first.revision))?.catalog)
        XCTAssertFalse(unchanged.queried); XCTAssertNil(unchanged.snapshot)
        try sql("UPDATE threads SET title='Changed', name=NULL, is_pinned=0; DELETE FROM thread_attachments; INSERT INTO threads VALUES ('new','/tmp','New',101,'/tmp/new',0,NULL,NULL,0);")
        XCTAssertEqual(try XCTUnwrap(worker.readCatalog(database.path)), try CodexCatalog.swiftRead(database.path))
        try sql("UPDATE threads SET archived=1 WHERE id='id'; UPDATE threads SET updated_at=102,title='Latest' WHERE id='new'")
        XCTAssertEqual(try XCTUnwrap(worker.readCatalog(database.path)), try CodexCatalog.swiftRead(database.path))
        worker.stop()
        XCTAssertEqual(try XCTUnwrap(worker.readCatalog(database.path)), try CodexCatalog.swiftRead(database.path))
        try sql("UPDATE threads SET archived=1")
        XCTAssertEqual(try XCTUnwrap(worker.readCatalog(database.path)).threads.count, 0)
        try FileManager.default.removeItem(at: database)
        XCTAssertNil(worker.readCatalog(database.path))
    }

    func testCatalogDeltaPreservesOrderAndRejectsIncompleteOrDuplicateRows() {
        let previous = CodexCatalog(threads: [["id": "one", "title": "Old"], ["id": "two", "title": "Kept"]], roots: [], attachments: [])
        func delta(_ threads: [[String: String]], _ order: [String]) -> CodexCatalogDelta {
            .init(baseRevision: 1, threads: threads, order: order, roots: ["/new"], attachments: [])
        }
        let changed = ["id": "three", "title": "New"]
        let result = delta([changed], ["three", "two"]).applying(to: previous)
        XCTAssertEqual(result?.threads, [changed, previous.threads[1]])
        XCTAssertEqual(result?.roots, ["/new"])
        XCTAssertEqual(delta([], []).applying(to: previous)?.threads, [])
        XCTAssertNil(delta([], ["missing"]).applying(to: previous))
        XCTAssertNil(delta([], ["one", "one"]).applying(to: previous))
        XCTAssertNil(delta([changed, changed], ["three", "two"]).applying(to: previous))
        XCTAssertNil(delta([changed], ["one", "two"]).applying(to: previous))
    }

    func testCatalogBeyondTransportLimitFallsBackWithoutDroppingChats() throws {
        let folder = try fixture(), database = folder.appendingPathComponent("state.sqlite")
        let result = CommandRunner().run("/usr/bin/sqlite3", [database.path,
            "CREATE TABLE threads(id TEXT,cwd TEXT,title TEXT,updated_at INTEGER,rollout_path TEXT,archived INTEGER); INSERT INTO threads VALUES('id','/tmp',printf('%.*c',6500000,'x'),1,'/tmp/log',0);"])
        XCTAssertTrue(result.succeeded)
        let worker = AgentLogWorker(executable: try executable()); defer { worker.stop() }
        XCTAssertNil(worker.readCatalog(database.path))
        XCTAssertEqual(try CodexCatalog.swiftRead(database.path).threads.count, 1)
    }

    func testLiveCatalogScopeAndFullCleanupCatalogStaySeparate() throws {
        let folder = try fixture(), codex = folder.appendingPathComponent(".codex"), database = codex.appendingPathComponent("state_1.sqlite")
        try FileManager.default.createDirectory(at: codex.appendingPathComponent("thread-writer-locks"), withIntermediateDirectories: true)
        let parent = "11111111-1111-4111-8111-111111111111", child = "22222222-2222-4222-8222-222222222222"
        let now = Date(), today = Int(now.timeIntervalSince1970)
        let source = "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"\(parent)\"}}}"
        let result = CommandRunner().run("/usr/bin/sqlite3", [database.path,
            "CREATE TABLE threads(id TEXT,cwd TEXT,title TEXT,updated_at INTEGER,rollout_path TEXT,archived INTEGER,is_pinned INTEGER,source TEXT); INSERT INTO threads VALUES ('old','/tmp','History',0,'/tmp/log',0,0,'cli'), ('\(parent)','/tmp','Parent',0,'/tmp/log',0,0,'cli'), ('\(child)','/tmp','Today',\(today),'/tmp/log',0,0,'\(source)'), ('pin','/tmp','Pinned',0,'/tmp/log',0,1,'invalid-json'), ('unread','/tmp','Unread',0,'/tmp/log',0,0,'cli');"])
        XCTAssertTrue(result.succeeded, result.error)
        let scope = CodexCatalogScope(since: Int64(today - 600), ids: ["unread"])
        let worker = AgentLogWorker(executable: try executable()); defer { worker.stop() }
        let live = try XCTUnwrap(worker.readCatalog(database.path, scope: scope))
        XCTAssertEqual(live, try CodexCatalog.swiftRead(database.path).filtered(scope))
        XCTAssertEqual(Set(live.threads.compactMap { $0["id"] }), Set([parent,child,"pin","unread"]))
        XCTAssertEqual(try XCTUnwrap(worker.readCatalog(database.path)).threads.count, 5)
        XCTAssertEqual(try XCTUnwrap(worker.readCatalog(database.path, scope: scope)), live)
        // The native fallback and the public reader preserve the same scope;
        // cleanup's default reader still inspects the complete inventory.
        let reader = AgentReader(logWorker: AgentLogWorker(executable: nil))
        let processes = ProcessSnapshot(processes: [], warnings: [])
        var readState = ProviderReadState.empty; readState.codexUnread = ["unread"]
        let full = reader.read(home: folder.path, processes: processes, now: now, readState: readState)
        let visible = reader.read(home: folder.path, processes: processes, now: now, readState: readState, live: true)
        XCTAssertEqual(full.sessions.count, 5)
        XCTAssertEqual(Set(visible.sessions.map(\.id)), Set([parent,child,"pin","unread"].map { "codex:" + $0 }))
    }

    func testWorkerRestartAndMissingExecutableFallback() throws {
        let folder = try fixture(), file = folder.appendingPathComponent("session.jsonl")
        try event("task_complete").write(to: file, atomically: true, encoding: .utf8)
        let worker = AgentLogWorker(executable: try executable()); defer { worker.stop() }
        XCTAssertEqual(try XCTUnwrap(worker.exchange([file.path])).reads, 1)
        worker.stop()
        XCTAssertEqual(try XCTUnwrap(worker.exchange([file.path])).reads, 1)
        let missing = AgentLogWorker(executable: folder.appendingPathComponent("missing"))
        XCTAssertEqual(missing.read([file.path]), [CodexLogEvidence.swiftRead(file.path)])
        let disabled = AgentLogWorker(executable: nil)
        XCTAssertEqual(disabled.read([file.path]), missing.read([file.path]))
    }

    func testBrokenOrHungChildFallsBackAndRecovers() throws {
        let folder = try fixture(), file = folder.appendingPathComponent("session.jsonl")
        try event("approval_required").write(to: file, atomically: true, encoding: .utf8)
        // exec ensures this fixture has no orphaned grandchild to clean up.
        let fake = try fakeWorker(in: folder, body: "exec /bin/sleep 30\n")
        let worker = AgentLogWorker(executable: fake, timeout: 0.75, retryDelay: 0)
        defer { worker.stop() }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(worker.read([file.path]), [CodexLogEvidence.swiftRead(file.path)])
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        try FileManager.default.removeItem(at: fake)
        try FileManager.default.copyItem(at: try executable(), to: fake)
        XCTAssertEqual(try XCTUnwrap(worker.exchange([file.path])).results[0].last, .waiting)
    }

    func testBadProtocolAndCrashNeverPublishAnEmptySuccessfulScan() throws {
        let folder = try fixture(), file = folder.appendingPathComponent("session.jsonl")
        try event("task_started").write(to: file, atomically: true, encoding: .utf8)
        for body in ["exit 1\n", "echo invalid\n", "echo '{\"version\":2,\"id\":\"wrong\",\"results\":[],\"reads\":0,\"cacheHits\":0}'\n"] {
            let fake = try fakeWorker(in: folder, body: body)
            let worker = AgentLogWorker(executable: fake, timeout: 0.2)
            XCTAssertEqual(worker.read([file.path]).first?.last, .working)
            worker.stop()
        }
    }

    func testExcessiveChildOutputIsBoundedAndFallsBack() throws {
        let folder = try fixture(), file = folder.appendingPathComponent("session.jsonl")
        try event("task_started").write(to: file, atomically: true, encoding: .utf8)
        let fake = try fakeWorker(in: folder, body: "exec /usr/bin/head -c 600000 /dev/zero\n")
        let worker = AgentLogWorker(executable: fake, timeout: 0.75)
        defer { worker.stop() }
        XCTAssertEqual(worker.read([file.path]).first?.last, .working)
    }

    func testSymlinksDirectoriesAndFIFOsCannotBlockEitherReader() throws {
        let folder = try fixture(), fifo = folder.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fifo)
        let worker = AgentLogWorker(executable: try executable()); defer { worker.stop() }
        let paths = [folder.path, fifo.path, link.path, "relative"]
        XCTAssertTrue(try XCTUnwrap(worker.exchange(paths)).results.allSatisfy { !$0.readable })
        XCTAssertTrue(paths.map(CodexLogEvidence.swiftRead).allSatisfy { !$0.readable })
    }

    func testConcurrentCallersShareOneSerializedWorker() async throws {
        let folder = try fixture(), file = folder.appendingPathComponent("session.jsonl")
        try event("turn_complete").write(to: file, atomically: true, encoding: .utf8)
        let worker = AgentLogWorker(executable: try executable()); defer { worker.stop() }
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<12 { group.addTask { worker.exchange([file.path])?.results.first?.completed == true } }
            var results: [Bool] = []; for await result in group { results.append(result) }; return results
        }
        XCTAssertEqual(results.count, 12); XCTAssertTrue(results.allSatisfy { $0 })
    }

    func testSyntheticWarmScanBenchmark() throws {
        guard ProcessInfo.processInfo.environment["BURRO_WORKER_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in synthetic benchmark") }
        let folder = try fixture(), worker = AgentLogWorker(executable: try executable())
        defer { worker.stop() }
        // Lifecycle event followed by ordinary log envelopes, so both parsers must
        // inspect the tail. This measures a repeated unchanged-log workload only.
        let noise = String(repeating: "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"text\":\"synthetic fixture\"}}\n", count: 500)
        let paths = try (0..<40).map { index in
            let path = folder.appendingPathComponent("\(index).jsonl")
            try (event("task_started") + "\n" + noise).write(to: path, atomically: true, encoding: .utf8)
            return path.path
        }
        let cold = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(try XCTUnwrap(worker.exchange(paths)).reads, paths.count)
        let coldTime = ProcessInfo.processInfo.systemUptime - cold
        let warm = ProcessInfo.processInfo.systemUptime
        for _ in 0..<10 { XCTAssertEqual(try XCTUnwrap(worker.exchange(paths)).cacheHits, paths.count) }
        let warmTime = (ProcessInfo.processInfo.systemUptime - warm) / 10
        let swift = ProcessInfo.processInfo.systemUptime
        for _ in 0..<10 { XCTAssertTrue(paths.map(CodexLogEvidence.swiftRead).allSatisfy { $0.last == .working }) }
        let swiftTime = (ProcessInfo.processInfo.systemUptime - swift) / 10
        print("SYNTHETIC_LOG_BENCHMARK cold=\(coldTime)s warm=\(warmTime)s swift=\(swiftTime)s files=40")
    }
}
