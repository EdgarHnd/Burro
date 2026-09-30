// Real temporary Git repositories verify data-loss-sensitive assessments end to end.
import XCTest
@testable import BurroCore

final class GitIntegrationTests: XCTestCase {
    func testCleanDirtyIgnoredUnmergedAndMissingWorktrees() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("burro-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("repo").path, tree = root.appendingPathComponent("tree with spaces").path
        let runner = CommandRunner()
        func git(_ path: String, _ args: [String]) throws -> String {
            let result = runner.git(path, args)
            guard result.succeeded else { throw NSError(domain: "git-test", code: Int(result.code), userInfo: [NSLocalizedDescriptionKey: result.error]) }
            return result.output
        }
        _ = try git(root.path, ["init", "-b", "main", main])
        _ = try git(main, ["config", "user.name", "Burro Tests"])
        _ = try git(main, ["config", "user.email", "burro@example.invalid"])
        _ = try git(main, ["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "initial"])
        _ = try git(main, ["update-ref", "refs/remotes/origin/main", "HEAD"])
        _ = try git(main, ["worktree", "add", "-b", "feature", tree])
        _ = try git(main, ["config", "remote.origin.url", main])
        _ = try git(main, ["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"])
        _ = try git(main, ["update-ref", "refs/remotes/origin/feature", "HEAD"])
        _ = try git(tree, ["branch", "--set-upstream-to=origin/feature"])
        let records = GitParser.worktrees(try git(main, ["worktree", "list", "--porcelain", "-z"]))
        let record = try XCTUnwrap(records.first { $0.branch == "feature" })
        let reader = GitReader()
        var facts = reader.facts(record, base: "origin/main")
        XCTAssertTrue(facts.errors.isEmpty); XCTAssertEqual(facts.merged, true); XCTAssertEqual(facts.unpushed, 0)
        XCTAssertEqual(facts.changed + facts.untracked + facts.ignoredCount, 0)
        XCTAssertEqual(DeliveryStatus.evaluate(facts), .merged)
        try "local data".write(toFile: tree + "/draft.txt", atomically: true, encoding: .utf8)
        facts = reader.facts(record, base: "origin/main"); XCTAssertEqual(facts.untracked, 1)
        XCTAssertEqual(facts.workspaceDiff?.added, 1)
        XCTAssertEqual(facts.workspaceDiff?.removed, 0)
        XCTAssertEqual(DeliveryStatus.evaluate(facts), .uncommitted)
        _ = try git(tree, ["add", "draft.txt"])
        facts = reader.facts(record, base: "origin/main"); XCTAssertEqual(facts.changed, 1)
        _ = try git(tree, ["-c", "commit.gpgsign=false", "commit", "-m", "local"])
        facts = reader.facts(record, base: "origin/main")
        XCTAssertEqual(facts.merged, false); XCTAssertEqual(facts.unpushed, 1)
        XCTAssertEqual(DeliveryStatus.evaluate(facts), .needsPush)
        _ = try git(tree, ["update-ref", "refs/remotes/origin/feature", "HEAD"])
        XCTAssertEqual(DeliveryStatus.evaluate(reader.facts(record, base: "origin/main")), .needsMerge)
        try "*.private\n".write(toFile: main + "/.git/info/exclude", atomically: true, encoding: .utf8)
        try "secret fixture".write(toFile: tree + "/config.private", atomically: true, encoding: .utf8)
        facts = reader.facts(record, base: "origin/main")
        XCTAssertEqual(facts.ignoredCount, 1); XCTAssertEqual(facts.ignored, ["config.private"])
        _ = try git(main, ["worktree", "lock", tree])
        XCTAssertTrue(GitParser.worktrees(try git(main, ["worktree", "list", "--porcelain", "-z"])).contains { $0.path == record.path && $0.locked })
        facts = reader.facts(WorktreeRecord(path: root.path + "/missing"), base: "origin/main")
        XCTAssertFalse(facts.errors.isEmpty); XCTAssertNil(facts.merged)
        XCTAssertNil(DeliveryStatus.evaluate(facts))
    }
    func testRefRefreshRecognizesMergeIntoStagingWithoutChangingCheckout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote").path, local = root.appendingPathComponent("local").path
        let runner = CommandRunner()
        func git(_ path: String, _ args: [String]) throws -> String {
            let result = runner.git(path, args)
            guard result.succeeded else { throw NSError(domain: "git", code: 1, userInfo: [NSLocalizedDescriptionKey: result.error]) }
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(root.path, ["init", "-b", "staging", remote])
        _ = try git(remote, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "initial"])
        _ = try git(root.path, ["clone", remote, local])
        _ = try git(local, ["checkout", "-b", "feature"])
        _ = try git(local, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "feature"])
        _ = try git(local, ["push", "-u", "origin", "feature"])
        let head = try git(local, ["rev-parse", "HEAD"])
        let record = WorktreeRecord(path: local, head: head, branch: "feature")
        XCTAssertEqual(DeliveryStatus.evaluate(GitReader().facts(record, base: "origin/staging")), .needsMerge)
        _ = try git(remote, ["merge", "--ff-only", "feature"])
        let refresh = GitReferenceRefresh()
        let error = await refresh.refresh(local, identity: local)
        XCTAssertNil(error)
        XCTAssertEqual(DeliveryStatus.evaluate(GitReader().facts(record, base: "origin/staging")), .merged)
        XCTAssertEqual(try git(local, ["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try git(local, ["branch", "--show-current"]), "feature")
        _ = try git(local, ["remote", "set-url", "origin", root.appendingPathComponent("missing").path])
        let cached = await refresh.refresh(local, identity: local)
        XCTAssertNil(cached)
        let failed = await refresh.refresh(local, identity: local, now: Date().addingTimeInterval(301))
        XCTAssertNotNil(failed)
    }
    func testSharedStagingUsesUpstreamAndPreservesBehindEvidence() {
        var facts = GitFacts()
        facts.branch = "staging"; facts.upstream = "origin/staging"; facts.base = "origin/main"
        facts.merged = false; facts.unpushed = 0; facts.upstreamAhead = 0; facts.upstreamBehind = 9
        facts.changed = 1
        XCTAssertEqual(DeliveryStatus.evaluate(facts), .uncommitted)
        XCTAssertEqual(facts.upstreamBehind, 9)
        facts.changed = 0
        XCTAssertEqual(DeliveryStatus.evaluate(facts), .behind)
        facts.upstreamBehind = 0
        XCTAssertEqual(DeliveryStatus.evaluate(facts), .synced)
        facts.upstreamAhead = 1
        XCTAssertEqual(DeliveryStatus.evaluate(facts), .needsPush)
        facts.upstreamAhead = nil
        XCTAssertNil(DeliveryStatus.evaluate(facts))
    }
    func testCommandTimeoutReturnsFailure() {
        let result = CommandRunner().run("/bin/sleep", ["3"], timeout: 0.05)
        XCTAssertTrue(result.timedOut); XCTAssertFalse(result.succeeded)
    }
}
