import XCTest
import Darwin
@testable import BurroCore

final class UsageLogWorkerTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("burro-usage-worker-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func worker() throws -> AgentLogWorker {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent(".build/rust/release/burro-log-worker")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            if ProcessInfo.processInfo.environment["BURRO_REQUIRE_RUST_WORKER"] == "1" { XCTFail("Required Rust helper missing") }
            throw XCTSkip("Build the Rust worker")
        }
        let worker = AgentLogWorker(executable: executable)
        addTeardownBlock { worker.stop() }
        return worker
    }
    private func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
    }
    private func claude(_ date: Date, id: String = "one", output: Int = 50) throws -> String {
        try line(["type": "assistant", "timestamp": ISO8601DateFormatter().string(from: date), "requestId": "request",
                  "message": ["id": id, "model": "claude-sonnet-4-6", "usage": ["input_tokens": 100,
                    "output_tokens": output, "cache_read_input_tokens": 200, "cache_creation_input_tokens": 80,
                    "cache_creation": ["ephemeral_1h_input_tokens": 30]]]])
    }
    private func codex(_ date: Date, total: Int = 120, input: Int = 100) throws -> String {
        try line(["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: date),
                  "payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": total],
                    "last_token_usage": ["input_tokens": input, "cached_input_tokens": 25, "output_tokens": 20]]]])
    }
    private func compare(_ actual: LocalUsageCost, _ expected: LocalUsageCost, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.tokens, expected.tokens, file: file, line: line)
        XCTAssertEqual(actual.recordCount, expected.recordCount, file: file, line: line)
        XCTAssertEqual(actual.pricedCount, expected.pricedCount, file: file, line: line)
        XCTAssertEqual(actual.apiValue, expected.apiValue, accuracy: 0.000000001, file: file, line: line)
        XCTAssertEqual(actual.partial, expected.partial, file: file, line: line)
        XCTAssertEqual(actual.models, expected.models, file: file, line: line)
        XCTAssertEqual(actual.days.map(\.date), expected.days.map(\.date), file: file, line: line)
        XCTAssertEqual(actual.days.map(\.tokens), expected.days.map(\.tokens), file: file, line: line)
    }
    func testProviderParityDeduplicationAndWarmCache() throws {
        let now = Date(), worker = try worker()
        for provider in UsageProvider.allCases {
            let root = try fixture(), file = root.appendingPathComponent(provider == .grok ? "signals.json" : "chat.jsonl")
            let contents: String
            switch provider {
            case .codex:
                let context = try line(["type": "turn_context", "payload": ["model": "gpt-6-sol"]])
                let record = try codex(now.addingTimeInterval(-300))
                contents = context + "\n" + record + "\n" + record + "\n" + (try codex(now.addingTimeInterval(-200), total: 220))
                try contents.write(to: root.appendingPathComponent("fork.jsonl"), atomically: true, encoding: .utf8)
            case .claude:
                contents = try claude(now.addingTimeInterval(-100), output: 10) + "\n" +
                    claude(now.addingTimeInterval(-100)) + "\n" + claude(now.addingTimeInterval(-80), id: "stream", output: 0)
            case .grok:
                contents = try line(["totalTokensBeforeCompaction": 300, "contextTokensUsed": 100, "primaryModelId": "grok-4"])
            }
            try contents.write(to: file, atomically: true, encoding: .utf8)
            let request = UsageLogRequest(provider: provider, roots: [root], now: now)
            let expected = LocalUsageScanner.swiftScan(provider: provider, roots: [root], now: now)
            let cold = try XCTUnwrap(worker.exchange([], usage: request)?.usage)
            let warm = try XCTUnwrap(worker.exchange([], usage: request)?.usage)
            XCTAssertGreaterThan(cold.reads, 0); XCTAssertEqual(warm.reads, 0)
            XCTAssertEqual(warm.cacheHits, cold.reads)
            compare(cold.result(now: now), expected); compare(warm.result(now: now), expected)
        }
    }
    func testAppendReplaceTruncateDeleteAgeAndProfileIsolation() throws {
        let root = try fixture(), second = try fixture(), worker = try worker(), now = Date()
        let file = root.appendingPathComponent("one.jsonl")
        let request = UsageLogRequest(provider: .claude, roots: [root], now: now)
        try claude(now.addingTimeInterval(-100)).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try XCTUnwrap(worker.exchange([], usage: request)?.usage).result(now: now).recordCount, 1)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + claude(now.addingTimeInterval(-50), id: "two")).utf8)); try handle.close()
        XCTAssertEqual(try XCTUnwrap(worker.exchange([], usage: request)?.usage).result(now: now).recordCount, 2)
        try claude(now.addingTimeInterval(-20), output: 500).write(to: file, atomically: true, encoding: .utf8)
        let replaced = try XCTUnwrap(worker.exchange([], usage: request)?.usage)
        XCTAssertEqual(replaced.reads, 1); XCTAssertEqual(replaced.result(now: now).tokens, 880)
        XCTAssertEqual(try XCTUnwrap(worker.exchange([], usage: UsageLogRequest(provider: .claude, roots: [second], now: now))?.usage).buckets.count, 0)
        let aged = try XCTUnwrap(worker.exchange([], usage: UsageLogRequest(provider: .claude, roots: [root], now: now.addingTimeInterval(31 * 86400)))?.usage)
        XCTAssertTrue(aged.buckets.isEmpty)
        try Data().write(to: file)
        XCTAssertTrue(try XCTUnwrap(worker.exchange([], usage: request)?.usage).buckets.isEmpty)
        try FileManager.default.removeItem(at: file)
        let removed = try XCTUnwrap(worker.exchange([], usage: request)?.usage)
        XCTAssertTrue(removed.buckets.isEmpty); XCTAssertFalse(removed.partial)
    }
    func testMalformedOversizedAndSpecialFilesStayBounded() throws {
        let root = try fixture(), now = Date(), worker = try worker()
        try (claude(now.addingTimeInterval(-5)) + "\n{\"usage\":").write(to: root.appendingPathComponent("torn.jsonl"), atomically: true, encoding: .utf8)
        let huge = root.appendingPathComponent("huge.jsonl")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge); try handle.truncate(atOffset: 33 * 1024 * 1024); try handle.close()
        XCTAssertEqual(mkfifo(root.appendingPathComponent("fifo.jsonl").path, 0o600), 0)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.jsonl"), withDestinationURL: root.appendingPathComponent("torn.jsonl"))
        let request = UsageLogRequest(provider: .claude, roots: [root], now: now)
        let batch = try XCTUnwrap(worker.exchange([], usage: request)?.usage)
        XCTAssertTrue(batch.partial); XCTAssertEqual(batch.result(now: now).recordCount, 1)
        XCTAssertLessThan(batch.bytesRead, 4096)
        compare(batch.result(now: now), LocalUsageScanner.swiftScan(provider: .claude, roots: [root], now: now))
    }
    func testFailedWorkerUsesCompleteSwiftRecoveryAndCanRestart() throws {
        let root = try fixture(), now = Date(), fake = root.appendingPathComponent("worker")
        try claude(now.addingTimeInterval(-5)).write(to: root.appendingPathComponent("chat.jsonl"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let worker = AgentLogWorker(executable: fake, timeout: 0.1, retryDelay: 0)
        defer { worker.stop() }
        let expected = LocalUsageScanner.swiftScan(provider: .claude, roots: [root], now: now)
        compare(LocalUsageScanner.scan(provider: .claude, roots: [root], now: now, worker: worker), expected)
        let working = try self.worker(), request = UsageLogRequest(provider: .claude, roots: [root], now: now)
        XCTAssertEqual(try XCTUnwrap(working.exchange([], usage: request)?.usage).reads, 1)
        working.stop()
        XCTAssertEqual(try XCTUnwrap(working.exchange([], usage: request)?.usage).reads, 1)
    }
    func testCalendarBoundariesPreserveDSTAndRejectInvalidAggregates() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-15T12:00:00Z"))
        let request = UsageLogRequest(provider: .codex, roots: [try fixture()], now: now, calendar: calendar)
        XCTAssertTrue(zip(request.dayBoundaries, request.dayBoundaries.dropFirst()).contains { $1 - $0 == 23 * 3600 })
        let date = request.dayBoundaries[10]
        let good = UsageLogBucket(date: date, model: "gpt-6-sol", input: 100, cached: 0, cacheWrite: 0, cacheWriteHour: 0, output: 10, recordCount: 1)
        XCTAssertFalse(UsageLogBatch(buckets: [good, good], partial: false, reads: 1, cacheHits: 0, bytesRead: 100, visited: 1).valid(for: request))
        XCTAssertFalse(UsageLogBatch(buckets: [good], partial: false, reads: 1, cacheHits: 1, bytesRead: 100, visited: 1).valid(for: request))
    }
    func testCompletionMetadataParityCacheReplacementAndDeletion() throws {
        let root = try fixture(), org = root.appendingPathComponent("account/org"), worker = try worker()
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        let file = org.appendingPathComponent("local_session.json")
        let object: [String: Any] = ["sessionId": "session-one", "completedTurns": 2, "isArchived": false,
                                    "unrelated": Array(repeating: ["body": "synthetic ignored text"], count: 1000)]
        try line(object).write(to: file, atomically: true, encoding: .utf8)
        let cold = try XCTUnwrap(worker.exchange([], completed: root.path)?.completed)
        XCTAssertEqual(Set(cold.ids), ProviderReadState.swiftClaudeCompletedSessions(root: root)); XCTAssertEqual(cold.reads, 1)
        let warm = try XCTUnwrap(worker.exchange([], completed: root.path)?.completed)
        XCTAssertEqual(warm.reads, 0); XCTAssertEqual(warm.cacheHits, 1)
        try line(["sessionId": "session-one", "completedTurns": 2, "isArchived": true]).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(try XCTUnwrap(worker.exchange([], completed: root.path)?.completed).ids.isEmpty)
        try "{bad".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(try XCTUnwrap(worker.exchange([], completed: root.path)?.completed).ids.isEmpty)
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(try XCTUnwrap(worker.exchange([], completed: root.path)?.completed).ids.isEmpty)
    }
    func testSyntheticHistoryBenchmark() throws {
        guard ProcessInfo.processInfo.environment["BURRO_WORKER_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in synthetic history benchmark") }
        let root = try fixture(), now = Date(), worker = try worker()
        for file in 0..<20 {
            let records = try (0..<200).map { try claude(now.addingTimeInterval(-100), id: "\(file)-\($0)") }
            try records.joined(separator: "\n").write(to: root.appendingPathComponent("\(file).jsonl"), atomically: true, encoding: .utf8)
        }
        let request = UsageLogRequest(provider: .claude, roots: [root], now: now)
        let swiftStart = ProcessInfo.processInfo.systemUptime
        let expected = autoreleasepool { LocalUsageScanner.swiftScan(provider: .claude, roots: [root], now: now) }
        let swiftTime = ProcessInfo.processInfo.systemUptime - swiftStart
        let coldStart = ProcessInfo.processInfo.systemUptime
        let cold = try XCTUnwrap(worker.exchange([], usage: request)?.usage)
        let coldTime = ProcessInfo.processInfo.systemUptime - coldStart
        let warmStart = ProcessInfo.processInfo.systemUptime
        let warm = try XCTUnwrap(worker.exchange([], usage: request)?.usage)
        let warmTime = ProcessInfo.processInfo.systemUptime - warmStart
        compare(cold.result(now: now), expected); compare(warm.result(now: now), expected)
        XCTAssertFalse(expected.partial); XCTAssertEqual(expected.recordCount, 4000)
        XCTAssertEqual(warm.reads, 0); XCTAssertEqual(warm.cacheHits, 20)
        print("SYNTHETIC_USAGE_BENCHMARK swift=\(swiftTime)s cold=\(coldTime)s warm=\(warmTime)s files=20 records=4000")
    }

}
