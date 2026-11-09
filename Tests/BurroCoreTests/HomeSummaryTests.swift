import XCTest
@testable import BurroCore

final class HomeSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func tree(_ path: String, repository: String) -> Worktree {
        Worktree(path: path, repository: URL(fileURLWithPath: repository).lastPathComponent, repositoryPath: repository,
                 branch: "main", head: String(repeating: "a", count: 40), isPrimary: path == repository,
                 isLocked: false, isMissing: false, isPrunable: false, facts: GitFacts(), agents: [], processes: [],
                 protectedByUser: false, assessment: Assessment(level: .keep, reasons: []))
    }
    private func session(_ id: String, _ state: AgentState, cwd: String, attached: [String] = [], unread: Bool = false,
                         remote: RemoteOrigin? = nil, title: String? = nil, age: TimeInterval = 60) -> AgentSession {
        var session = AgentSession(id: id, provider: .codex, title: title ?? id, cwd: cwd, attachedPaths: attached, state: state,
                                   updatedAt: now.addingTimeInterval(-age), evidence: "Fixture")
        session.hasUnreadResult = unread
        session.remote = remote
        return session
    }

    func testRollsUpChatsByRepositoryFolderAndMachine() {
        let host = UUID()
        let trees = [tree("/dev/app", repository: "/dev/app"), tree("/dev/app-feature", repository: "/dev/app"),
                     tree("/dev/site", repository: "/dev/site")]
        let sessions = [
            session("run", .working, cwd: "/dev/app-feature/src"),
            session("ask", .waiting, cwd: "/tmp", attached: ["/dev/app"], title: "Which build should ship?"),
            session("done", .idle, cwd: "/dev/site", unread: true),
            session("notes", .working, cwd: "/elsewhere/notes"),
            session("quiet", .idle, cwd: "/elsewhere/quiet"),
            session("remote", .working, cwd: "/srv/app", remote: RemoteOrigin(hostID: host, hostName: "Studio", sampledAt: now, stale: false)),
            session("stale", .waiting, cwd: "/srv/app", remote: RemoteOrigin(hostID: host, hostName: "Studio", sampledAt: now, stale: true)),
            session("run", .working, cwd: "/dev/app-feature/src"), // duplicate IDs count once
        ]
        let summary = HomeSummary.build(sessions: sessions, worktrees: trees, readyPaths: ["/dev/app-feature"],
            hosts: [HomeHost(id: host, name: "Studio", connection: .online, lastSeen: now)], now: now)

        XCTAssertEqual(summary.counts.running, 3)
        XCTAssertEqual(summary.counts.waiting, 1, "a stale remote request is not waiting")
        XCTAssertEqual(summary.counts.done, 1)
        XCTAssertEqual(summary.projects.map(\.name), ["app", "notes", "site"], "needs you, then running, then done; quiet folders omitted")
        let app = summary.projects[0]
        XCTAssertEqual([app.counts.running, app.counts.waiting, app.worktrees, app.readyToRemove], [1, 1, 2, 1])
        XCTAssertFalse(summary.projects[1].isRepository)
        XCTAssertEqual(summary.machines.map(\.name), ["This Mac", "Studio"])
        XCTAssertEqual(summary.machines[0].counts.running, 2)
        XCTAssertEqual(summary.machines[1].counts.running, 1)
        XCTAssertEqual(summary.needsYou.map(\.id), ["ask"])
        XCTAssertEqual(summary.unread.map(\.id), ["done"])
        XCTAssertTrue(summary.sentence.hasPrefix("3 agents are working in app, notes and 1 more."), summary.sentence)
        XCTAssertTrue(summary.sentence.contains("1 chat needs you: “Which build should ship?” 1 result"), summary.sentence)
        XCTAssertTrue(summary.sentence.contains("1 result is ready to read."), summary.sentence)
    }

    func testTodayTokensFoldIntoTheOwningProject() {
        let trees = [tree("/dev/app", repository: "/dev/app"), tree("/dev/app-feature", repository: "/dev/app")]
        let activity = ProjectActivity(folders: [
            .init(path: "/dev/app-feature/pkg", tokens: 1_000, apiValue: 2, records: 3, last: now),
            .init(path: "/dev/app", tokens: 500, apiValue: 1, records: 1, last: now),
            .init(path: "/elsewhere/notes", tokens: 70, apiValue: 0, records: 1, last: now),
            .init(path: "/unknown", tokens: 9_999, apiValue: 9, records: 1, last: now),
        ], partial: false, since: now.addingTimeInterval(-3600), scannedAt: now)
        let summary = HomeSummary.build(sessions: [session("notes", .working, cwd: "/elsewhere/notes")],
                                        worktrees: trees, activity: activity, now: now)
        let tokens = Dictionary(uniqueKeysWithValues: summary.projects.map { ($0.name, $0.tokensToday) })
        XCTAssertEqual(tokens, ["app": 1_500, "notes": 70], "folders outside known projects are not shown")
        XCTAssertEqual(summary.projects.first { $0.name == "app" }?.apiValueToday, 3)
    }

    func testQuietSummaryAndLowLimitLine() {
        XCTAssertEqual(HomeSummary.build(sessions: [], worktrees: [], now: now).sentence,
                       "All quiet. No agents are running and nothing needs you.")
        let usage = ProviderUsage(id: .claude, updatedAt: now,
            windows: [UsageWindow(id: "week", title: "Weekly", remainingPercent: 12, resetsAt: now.addingTimeInterval(3 * 86400))])
        let sentence = HomeSummary.build(sessions: [], worktrees: [], usage: usage.windows.isEmpty ? [] : [usage], leftovers: 2, now: now).sentence
        XCTAssertTrue(sentence.hasPrefix("No agents are running. Claude weekly has 12% left, resetting "), sentence)
        XCTAssertTrue(sentence.hasSuffix("This Mac has 2 leftover processes."), sentence)
    }

    func testProjectBucketsMustMatchTheRequest() {
        let since = now.addingTimeInterval(-3600)
        let plain = UsageLogRequest(provider: .claude, roots: [URL(fileURLWithPath: "/tmp")], now: now)
        let scoped = UsageLogRequest(provider: .claude, roots: [URL(fileURLWithPath: "/tmp")], now: now, projectsSince: since)
        func bucket(_ cwd: String, last: Date? = nil) -> UsageLogProjectBucket {
            UsageLogProjectBucket(cwd: cwd, model: "claude-test", input: 1, cached: 0, cacheWrite: 0, cacheWriteHour: 0,
                                  output: 1, recordCount: 1, last: (last ?? now).timeIntervalSince1970)
        }
        func batch(_ projects: [UsageLogProjectBucket]?) -> UsageLogBatch {
            UsageLogBatch(buckets: [], partial: false, reads: 0, cacheHits: 0, bytesRead: 0, visited: 0, projects: projects)
        }
        XCTAssertTrue(batch(nil).valid(for: plain))
        XCTAssertFalse(batch([]).valid(for: plain), "unrequested project data is rejected")
        XCTAssertFalse(batch(nil).valid(for: scoped))
        XCTAssertTrue(batch([bucket("/dev/app")]).valid(for: scoped))
        XCTAssertFalse(batch([bucket("relative")]).valid(for: scoped))
        XCTAssertFalse(batch([bucket("/dev/\u{7}bell")]).valid(for: scoped))
        XCTAssertFalse(batch([bucket("/dev/app"), bucket("/dev/app")]).valid(for: scoped))
        XCTAssertFalse(batch([bucket("/dev/app", last: since.addingTimeInterval(-1))]).valid(for: scoped))
    }

    func testRustWorkerAttributesTodayByFolder() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent(".build/rust/release/burro-log-worker")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            if ProcessInfo.processInfo.environment["BURRO_REQUIRE_RUST_WORKER"] == "1" { XCTFail("Required Rust helper missing") }
            throw XCTSkip("Build the Rust worker")
        }
        let worker = AgentLogWorker(executable: executable)
        defer { worker.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-home-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        func line(_ id: String, _ cwd: String, output: Int) throws -> String {
            let object: [String: Any] = ["type": "assistant", "cwd": cwd, "requestId": id,
                "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(-600)),
                "message": ["id": id, "model": "claude-sonnet-4-6", "stop_reason": "end_turn", "usage": ["input_tokens": 100,
                    "output_tokens": output, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]]]
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        try [line("a", "/dev/app", output: 10), line("b", "/dev/app/sub", output: 20), line("c", "/dev/site", output: 5)]
            .joined(separator: "\n").write(to: folder.appendingPathComponent("chat.jsonl"), atomically: true, encoding: .utf8)
        let activity = try XCTUnwrap(ProjectActivityScanner.scan(roots: [(.claude, [folder])], since: now.addingTimeInterval(-3600),
                                                                 now: now, worker: worker))
        let totals = activity.totals(roots: ["/dev/app", "/dev/site"])
        XCTAssertEqual(totals["/dev/app"]?.tokens, 230)
        XCTAssertEqual(totals["/dev/app"]?.records, 2)
        XCTAssertEqual(totals["/dev/site"]?.tokens, 105)
        XCTAssertGreaterThan(activity.apiValue, 0, "known models are priced")
    }
}
