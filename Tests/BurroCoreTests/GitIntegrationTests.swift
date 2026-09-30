// Integration hints require exact ancestry or patch evidence; cleanup retains commits independently.
import XCTest
@testable import BurroCore

final class GitIntegrationTests: XCTestCase, @unchecked Sendable {
    typealias Fixture = WorktreeCleanupTests.Fixture
    private func commit(_ f: Fixture, path: String, file: String, content: String, title: String) throws {
        try content.write(toFile: path + "/" + file, atomically: true, encoding: .utf8)
        try f.git(path, ["add", "--", file])
        try f.git(path, ["-c", "commit.gpgsign=false", "commit", "-m", title])
    }
    func testCombinedSquashPatchIsRecognized() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try commit(f, path: f.path, file: "feature.txt", content: "first\n", title: "Add feature")
        try commit(f, path: f.path, file: "feature.txt", content: "first\nsecond\n", title: "Refine feature")
        try f.git(f.main, ["merge", "--squash", "feature"])
        try f.git(f.main, ["-c", "commit.gpgsign=false", "commit", "-m", "Add feature (#42)"])
        try f.git(f.main, ["update-ref", "refs/remotes/origin/main", "HEAD"])
        let tree = try await f.tree()
        XCTAssertEqual(tree.facts.merged, false)
        XCTAssertEqual(tree.facts.equivalentPatchIn, "origin/main")
        XCTAssertEqual(tree.facts.integrationSummary, "Equivalent changes in origin/main")
    }
    func testMatchingSubjectWithDifferentPatchIsNotIncluded() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try commit(f, path: f.path, file: "feature.txt", content: "one\n", title: "Feature")
        try commit(f, path: f.main, file: "feature.txt", content: "different\n", title: "Feature (#42)")
        try f.git(f.main, ["update-ref", "refs/remotes/origin/main", "HEAD"])
        let tree = try await f.tree()
        XCTAssertNil(tree.facts.equivalentPatchIn)
    }
    func testIncludedInStagingEvenWhenComparingToMain() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try commit(f, path: f.path, file: "feature.txt", content: "staging\n", title: "Feature")
        try f.git(f.path, ["update-ref", "refs/remotes/origin/staging", "HEAD"])
        let tree = try await f.tree()
        XCTAssertEqual(tree.facts.merged, false)
        XCTAssertEqual(tree.facts.includedIn, ["origin/staging"])
        XCTAssertEqual(tree.facts.integrationSummary, "Included in origin/staging")
    }
    func testUniqueMergeCommitIsNotAssumedEquivalent() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try commit(f, path: f.main, file: "main.txt", content: "main\n", title: "Main")
        try commit(f, path: f.path, file: "feature.txt", content: "feature\n", title: "Feature")
        try f.git(f.path, ["-c", "commit.gpgsign=false", "merge", "--no-ff", "main", "-m", "Combined"])
        try f.git(f.main, ["merge", "--squash", "feature"])
        try f.git(f.main, ["-c", "commit.gpgsign=false", "commit", "-m", "Combined"])
        try f.git(f.main, ["update-ref", "refs/remotes/origin/main", "HEAD"])
        XCTAssertNil(GitIntegrationEvidence(runner: CommandRunner()).equivalentRef(f.path, base: "origin/main"))
    }
    func testStatusPathsPreserveSpacesNewlinesAndRenameDestination() {
        let paths = GitParser.changePaths("R  new name\0old name\0 M modified\nfile\0?? new file\0")
        XCTAssertEqual(paths.tracked, ["new name", "modified\nfile"])
        XCTAssertEqual(paths.untracked, ["new file"])
    }
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
        let records = GitParser.worktrees(try git(main, ["worktree", "list", "--porcelain", "-z"]))
        let record = try XCTUnwrap(records.first { $0.branch == "feature" })
        let reader = GitReader()
        var facts = reader.facts(record, base: "origin/main")
        XCTAssertTrue(facts.errors.isEmpty); XCTAssertEqual(facts.merged, true); XCTAssertEqual(facts.unpushed, 0)
        XCTAssertEqual(facts.changed + facts.untracked + facts.ignoredCount, 0)
        try "local data".write(toFile: tree + "/draft.txt", atomically: true, encoding: .utf8)
        facts = reader.facts(record, base: "origin/main"); XCTAssertEqual(facts.untracked, 1)
        _ = try git(tree, ["add", "draft.txt"])
        facts = reader.facts(record, base: "origin/main"); XCTAssertEqual(facts.changed, 1)
        _ = try git(tree, ["-c", "commit.gpgsign=false", "commit", "-m", "local"])
        facts = reader.facts(record, base: "origin/main")
        XCTAssertEqual(facts.merged, false); XCTAssertEqual(facts.unpushed, 1)
        try "*.private\n".write(toFile: main + "/.git/info/exclude", atomically: true, encoding: .utf8)
        try "secret fixture".write(toFile: tree + "/config.private", atomically: true, encoding: .utf8)
        facts = reader.facts(record, base: "origin/main")
        XCTAssertEqual(facts.ignoredCount, 1); XCTAssertEqual(facts.ignored, ["config.private"])
        _ = try git(main, ["worktree", "lock", tree])
        XCTAssertTrue(GitParser.worktrees(try git(main, ["worktree", "list", "--porcelain", "-z"])).contains { $0.path == record.path && $0.locked })
        facts = reader.facts(WorktreeRecord(path: root.path + "/missing"), base: "origin/main")
        XCTAssertFalse(facts.errors.isEmpty); XCTAssertNil(facts.merged)
    }
    func testCommandTimeoutReturnsFailure() {
        let result = CommandRunner().run("/bin/sleep", ["3"], timeout: 0.05)
        XCTAssertTrue(result.timedOut); XCTAssertFalse(result.succeeded)
    }
}
