import XCTest
@testable import BurroCore

final class WorktreeRemovalTests: XCTestCase {
    func testRemovalRechecksLocalDataAndKeepsBranch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo").path
        let linked = root.appendingPathComponent("linked").path
        let runner = CommandRunner()
        func git(_ args: [String]) throws -> String {
            let result = runner.git(repo, args)
            XCTAssertTrue(result.succeeded, result.error)
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try git(["init", "-b", "main"])
        _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "initial"])
        _ = try git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        _ = try git(["worktree", "add", "-b", "feature", linked])
        let records = GitParser.worktrees(runner.git(repo, ["worktree", "list", "--porcelain", "-z"]).output)
        let record = try XCTUnwrap(records.first { $0.branch == "feature" })
        var config = ScanConfiguration(home: root.path, repositories: [repo], discover: false)
        config.onlyWorktree = record.path
        config.inspectionDeadline = Date().addingTimeInterval(10)
        let targeted = await Scanner().scan(config)
        XCTAssertEqual(targeted.worktrees.map(\.path), [record.path])
        XCTAssertNil(targeted.worktrees.first?.facts.workspaceDiff)
        let expired = CommandRunner(deadline: Date().addingTimeInterval(-1)).git(repo, ["status"])
        XCTAssertTrue(expired.timedOut)
        let facts = GitReader().facts(record, base: "origin/main")
        let tree = Worktree(path: record.path, repository: "repo", repositoryPath: repo, branch: "feature", head: record.head,
            isPrimary: false, isLocked: false, isMissing: false, isPrunable: false, facts: facts, agents: [], processes: [],
            protectedByUser: false, assessment: Assessment(level: .candidate, reasons: []))
        let draft = URL(fileURLWithPath: linked).appendingPathComponent("draft")
        try Data("keep me".utf8).write(to: draft)
        XCTAssertNotNil(WorktreeRemoval.remove(tree))
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.path))
        try FileManager.default.removeItem(at: draft)
        try Data("ignored-secret\n".utf8).write(to: URL(fileURLWithPath: repo + "/.git/info/exclude"))
        try Data("fixture only".utf8).write(to: URL(fileURLWithPath: linked + "/ignored-secret"))
        XCTAssertNil(WorktreeRemoval.remove(tree))
        XCTAssertFalse(FileManager.default.fileExists(atPath: linked))
        XCTAssertTrue(runner.git(repo, ["rev-parse", "--verify", "feature"]).succeeded)
    }
}
