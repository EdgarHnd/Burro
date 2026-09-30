// Disposable repositories prove cleanup preserves ignored data and rejects changed evidence.
import XCTest
@testable import BurroCore

final class WorktreeCleanupTests: XCTestCase, @unchecked Sendable {
    struct Fixture {
        var root: URL
        var main: String { root.appendingPathComponent("repo").path }
        var path: String { root.appendingPathComponent("tree with spaces").path }
        var config: ScanConfiguration { .init(home: root.appendingPathComponent("home").path, repositories: [main], discover: false) }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("burro-cleanup-\(UUID())")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("home/.claude/sessions"), withIntermediateDirectories: true)
            try git(root.path, ["init", "-b", "main", main])
            try git(main, ["config", "user.name", "Test"])
            try git(main, ["config", "user.email", "test@example.invalid"])
            try git(main, ["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "initial"])
            try git(main, ["update-ref", "refs/remotes/origin/main", "HEAD"])
            try git(main, ["worktree", "add", "-b", "feature", path])
        }
        @discardableResult func git(_ path: String, _ args: [String]) throws -> String {
            let value = CommandRunner().git(path, args)
            guard value.succeeded else { throw CleanupError.blocked(value.error) }
            return value.output
        }
        func tree() async throws -> Worktree {
            let scan = await Scanner().scan(config)
            return try XCTUnwrap(scan.worktrees.first { $0.path == Paths.canonical(path) })
        }
        func move(_ source: URL) throws -> URL {
            let target = root.appendingPathComponent("test-trash")
            try FileManager.default.moveItem(at: source, to: target)
            return target
        }
    }
    func testMissingPathRetainsCanonicalIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("burro-path-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = Paths.canonical(root.path)
        try FileManager.default.removeItem(at: root)
        XCTAssertEqual(Paths.canonical(root.path), identity)
    }
    func testIgnoredDataPreservedAndBranchKeptWithoutForceOrPruningOtherTrees() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try "*.private\nshared\n".write(toFile: f.main + "/.git/info/exclude", atomically: true, encoding: .utf8)
        try "fixture data".write(toFile: f.path + "/config.private", atomically: true, encoding: .utf8)
        let external = f.root.appendingPathComponent("external-data")
        try Data("shared fixture".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(atPath: f.path + "/shared", withDestinationPath: external.path)
        let other = f.root.appendingPathComponent("other").path
        try f.git(f.main, ["worktree", "add", "-b", "other", other])
        let tree = try await f.tree()
        XCTAssertEqual(tree.assessment.level, .review)
        XCTAssertTrue(WorktreeCleanup.eligibility(tree, home: f.config.home, warnings: []).allowed)
        let trash = try await WorktreeCleanup().remove(tree, configuration: f.config, trash: f.move)
        XCTAssertEqual(try String(contentsOf: trash.appendingPathComponent("config.private"), encoding: .utf8), "fixture data")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: trash.path + "/shared"), external.path)
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "shared fixture")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
        XCTAssertFalse(try f.git(f.main, ["worktree", "list", "--porcelain"]).contains(f.path))
        XCTAssertTrue(try f.git(f.main, ["worktree", "list", "--porcelain"]).contains(other))
        XCTAssertEqual(try f.git(f.main, ["rev-parse", "feature"]).trimmingCharacters(in: .whitespacesAndNewlines), tree.head)
    }
    func testNewLocalFileBetweenReviewAndConfirmationCancelsRemoval() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try await f.tree()
        try "keep".write(toFile: f.path + "/new.txt", atomically: true, encoding: .utf8)
        do { _ = try await WorktreeCleanup().remove(tree, configuration: f.config, trash: f.move); XCTFail("Must reject new data") }
        catch { XCTAssertTrue(error.localizedDescription.contains("untracked"), error.localizedDescription) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path + "/new.txt"))
    }
    func testChangedHeadAndNewProtectionCancelRemoval() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try await f.tree()
        var changedBase = f.config; changedBase.baseOverrides[f.main] = "main"
        do { _ = try await WorktreeCleanup().remove(tree, configuration: changedBase, trash: f.move); XCTFail("Must review a changed comparison branch") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        var config = f.config; config.protectedPaths = [tree.path]
        do { _ = try await WorktreeCleanup().remove(tree, configuration: config, trash: f.move); XCTFail("Must respect new protection") }
        catch { XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("protected")) }
        try f.git(f.path, ["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "new work"])
        do { _ = try await WorktreeCleanup().remove(tree, configuration: f.config, trash: f.move); XCTFail("Must reject new HEAD") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }
    func testMoverFailureLeavesRegistrationIntact() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try await f.tree()
        do {
            _ = try await WorktreeCleanup().remove(tree, configuration: f.config, trash: { _ in throw CleanupError.blocked("Trash unavailable") })
            XCTFail("Must report failure")
        } catch { XCTAssertEqual(error.localizedDescription, "Trash unavailable") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
        XCTAssertTrue(try f.git(f.main, ["worktree", "list", "--porcelain"]).contains(f.path))
    }
    func testReplacementDirectoryAfterTrashIsNeverRemoved() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try await f.tree()
        do {
            _ = try await WorktreeCleanup().remove(tree, configuration: f.config, trash: { source in
                let destination = try f.move(source)
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                try Data("new work".utf8).write(to: source.appendingPathComponent("new.txt"))
                return destination
            })
            XCTFail("A recreated directory must not be removed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("preserved at")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path + "/new.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("test-trash/.git").path))
        XCTAssertTrue(try f.git(f.main, ["worktree", "list", "--porcelain"]).contains(f.path))
    }
    func testOpenIdleUnknownPinnedAndMissingCoverageStayBlocked() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var tree = try await f.tree()
        for state in [AgentState.working, .waiting, .scheduled, .idle, .unknown, .recent] {
            tree.agents = [AgentSession(id: "test", provider: .claude, title: "Test", cwd: tree.path, state: state, updatedAt: Date(), evidence: "Fixture")]
            XCTAssertFalse(WorktreeCleanup.eligibility(tree, home: f.config.home, warnings: []).allowed)
        }
        tree.agents[0].state = .inactive; tree.agents[0].pinned = true
        XCTAssertFalse(WorktreeCleanup.eligibility(tree, home: f.config.home, warnings: []).allowed)
        tree.agents = []
        XCTAssertFalse(WorktreeCleanup.eligibility(tree, home: f.config.home, warnings: [], registeredPaths: [tree.path + "/nested"]).allowed)
        XCTAssertFalse(WorktreeCleanup.eligibility(tree, home: f.config.home, warnings: ["Unknown metadata"]).allowed)
        tree.isPrimary = true
        XCTAssertFalse(WorktreeCleanup.eligibility(tree, home: f.config.home, warnings: []).allowed)
        tree.isPrimary = false
        tree.agents = [AgentSession(id: "attached", provider: .codex, title: "Closed", cwd: "/elsewhere", attachedPaths: [tree.path], state: .inactive, updatedAt: Date(), evidence: "Fixture")]
        XCTAssertTrue(WorktreeCleanup.eligibility(tree, home: f.config.home, warnings: []).managedByCodex)
        tree.agents = []; tree.path = Paths.canonical(f.config.home + "/.codex/worktrees/abc/project")
        XCTAssertTrue(WorktreeCleanup.eligibility(tree, home: f.config.home, warnings: []).managedByCodex)
    }
    func testUnmergedUnpushedBranchSurvivesCheckoutRemoval() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.git(f.path, ["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "unfinished feature"])
        let tree = try await f.tree()
        XCTAssertEqual(tree.facts.merged, false)
        XCTAssertEqual(tree.facts.unpushed, 1)
        XCTAssertEqual(tree.facts.retainedBranchName, "feature")
        XCTAssertEqual(WorktreeCleanup.eligibility(tree, home: f.config.home, warnings: []).status, .ready)
        _ = try await WorktreeCleanup().remove(tree, configuration: f.config, trash: f.move)
        XCTAssertEqual(try f.git(f.main, ["rev-parse", "feature"]).trimmingCharacters(in: .whitespacesAndNewlines), tree.head)
        XCTAssertFalse(try f.git(f.main, ["worktree", "list", "--porcelain"]).contains(f.path))
    }
    func testDetachedCommitRequiresLocalBranchEvenWhenPublished() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.git(f.path, ["checkout", "--detach"])
        try f.git(f.path, ["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "detached work"])
        try f.git(f.path, ["update-ref", "refs/remotes/origin/feature", "HEAD"])
        var tree = try await f.tree()
        XCTAssertEqual(tree.facts.unpushed, 0)
        XCTAssertNil(tree.facts.retainedBranch)
        XCTAssertEqual(WorktreeCleanup.eligibility(tree, home: f.config.home, warnings: []).status, .needsBranch)
        do { _ = try await WorktreeCleanup().remove(tree, configuration: f.config, trash: f.move); XCTFail("Must retain detached commits locally") }
        catch { XCTAssertTrue(error.localizedDescription.contains("local branch")) }
        try f.git(f.path, ["branch", "saved-work"])
        tree = try await f.tree()
        XCTAssertEqual(tree.facts.retainedBranchName, "saved-work")
        XCTAssertTrue(WorktreeCleanup.eligibility(tree, home: f.config.home, warnings: []).allowed)
    }
    func testDeletedRetentionBranchCancelsRemoval() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.git(f.path, ["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "saved work"])
        try f.git(f.path, ["checkout", "--detach"])
        let tree = try await f.tree()
        XCTAssertEqual(tree.facts.retainedBranchName, "feature")
        try f.git(f.main, ["branch", "-D", "feature"])
        do { _ = try await WorktreeCleanup().remove(tree, configuration: f.config, trash: f.move); XCTFail("Must recheck commit retention") }
        catch { XCTAssertTrue(error.localizedDescription.contains("local branch")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }
    func testRetentionLossDuringMoveLeavesRegistrationRecoverable() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.git(f.path, ["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "saved work"])
        try f.git(f.path, ["checkout", "--detach"])
        let tree = try await f.tree()
        do {
            _ = try await WorktreeCleanup().remove(tree, configuration: f.config, trash: { source in
                let destination = try f.move(source)
                try f.git(f.main, ["branch", "-D", "feature"])
                return destination
            })
            XCTFail("Do not unregister if the retaining branch disappeared")
        } catch { XCTAssertTrue(error.localizedDescription.contains("preserved at")) }
        XCTAssertTrue(try f.git(f.main, ["worktree", "list", "--porcelain"]).contains(f.path))
    }
    func testConcreteCleanupStatusesAndChangedFileNames() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try "save this".write(toFile: f.path + "/new file.txt", atomically: true, encoding: .utf8)
        var tree = try await f.tree()
        XCTAssertEqual(tree.facts.untrackedPaths, ["new file.txt"])
        XCTAssertEqual(WorktreeCleanup.eligibility(tree, home: f.config.home, warnings: []).status, .localChanges)
        tree.facts.untracked = 0; tree.facts.operationInProgress = true
        XCTAssertEqual(WorktreeCleanup.eligibility(tree, home: f.config.home, warnings: []).status, .gitBusy)
        tree.facts.operationInProgress = false; tree.facts.retentionChecked = nil
        XCTAssertEqual(WorktreeCleanup.eligibility(tree, home: f.config.home, warnings: []).status, .unknown)
        tree.protectedByUser = true
        XCTAssertEqual(WorktreeCleanup.eligibility(tree, home: f.config.home, warnings: []).status, .protected)
    }

}
