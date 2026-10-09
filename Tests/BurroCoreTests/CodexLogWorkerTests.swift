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
