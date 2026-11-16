// The Worktrees page's decisions: row states, filter counts, which rows can be ticked, a bulk set
// that never holds anything cleanup eligibility does not allow, repository-health thresholds, and
// a conservative git gc proven on a disposable repository (never a real one).
import XCTest
@testable import BurroCore

final class WorktreeBoardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    private func tree(_ name: String, repo: String = "repo", primary: Bool = false, branch: String? = nil,
                      changed: Int = 0, untracked: Int = 0, unpushed: Int? = 0, retained: Bool = true,
                      agents: [AgentSession] = [], processes: [LocalProcess] = [], protected: Bool = false,
                      locked: Bool = false, errors: [String] = [], lastCommit: Date? = nil) -> Worktree {
        var facts = GitFacts()
        facts.base = "origin/main"; facts.changed = changed; facts.untracked = untracked; facts.unpushed = unpushed
        facts.retentionChecked = true; facts.retainedBranch = retained ? "refs/heads/" + (branch ?? name) : nil
        facts.errors = errors; facts.lastCommit = lastCommit ?? now.addingTimeInterval(-3_600)
        return Worktree(path: "/fixture/\(repo)/\(name)", repository: repo, repositoryPath: "/fixture/\(repo)/main",
            branch: branch ?? name, head: String(repeating: "a", count: 40), isPrimary: primary, isLocked: locked,
            isMissing: false, isPrunable: false, facts: facts, agents: agents, processes: processes,
            protectedByUser: protected, assessment: Assessment(level: .keep, reasons: []))
    }
    private func chat(_ state: AgentState, path: String, title: String = "Chat", at: Date? = nil) -> AgentSession {
        AgentSession(id: UUID().uuidString, provider: .claude, title: title, cwd: path, state: state,
                     updatedAt: at ?? now.addingTimeInterval(-60), evidence: "test")
    }
    /// Rows with the real cleanup decision, as the page builds them.
    private func rows(_ trees: [Worktree], sizes: [String: Int64] = [:]) -> [WorktreeBoardRow] {
        trees.map { WorktreeBoardRow(tree: $0, eligibility: WorktreeCleanup.eligibility($0, home: "/fixture-home", warnings: []),
                                     size: sizes[$0.path]) }
    }

    /// Every state the policy can produce, so the safety properties are checked across all of them.
    private var everyKind: [Worktree] {
        let busy = "/fixture/repo/busy"
        return [
            tree("safe-merged"),
            tree("safe-unpushed", unpushed: 3),
            tree("main", primary: true, branch: "main"),
            tree("dirty", changed: 2, untracked: 1),
            tree("busy", agents: [chat(.working, path: busy)]),
            tree("idle-open", agents: [chat(.idle, path: "/fixture/repo/idle-open")]),
            tree("process", processes: [LocalProcess(pid: 42, name: "node", cwd: "/fixture/repo/process", started: now)]),
            tree("protected", protected: true),
            tree("locked", locked: true),
            tree("detached", retained: false),
            tree("unverified", errors: ["Merge status could not be read"]),
            tree("busy-dirty", changed: 4, agents: [chat(.waiting, path: "/fixture/repo/busy-dirty")]),
            tree("old-chat", agents: [chat(.inactive, path: "/fixture/repo/old-chat", title: "Done long ago")]),
        ]
    }

    func testRowStatesFollowTheCleanupDecision() {
        let byName = Dictionary(uniqueKeysWithValues: rows(everyKind).map { (URL(fileURLWithPath: $0.id).lastPathComponent, $0) })
        XCTAssertEqual(byName["safe-merged"]?.kind, .safe)
        XCTAssertEqual(byName["safe-unpushed"]?.kind, .safe, "commits stay on the branch, as cleanup already allows")
        XCTAssertEqual(byName["safe-unpushed"]?.changes.text, "3 unpushed")
        XCTAssertEqual(byName["dirty"]?.kind, .uncommitted)
        XCTAssertEqual(byName["dirty"]?.changes.text, "3 uncommitted")
        XCTAssertEqual(byName["dirty"]?.changes.attention, true)
        XCTAssertEqual(byName["busy"]?.kind, .inUse)
        XCTAssertEqual(byName["idle-open"]?.kind, .inUse)
        XCTAssertEqual(byName["process"]?.kind, .inUse)
        XCTAssertEqual(byName["busy-dirty"]?.kind, .inUse)
        XCTAssertEqual(byName["protected"]?.stateTitle, "Protected")
        XCTAssertEqual(byName["detached"]?.stateTitle, "Save commits first")
        XCTAssertEqual(byName["unverified"]?.stateTitle, "Cannot verify")
        XCTAssertEqual(byName["old-chat"]?.kind, .safe)
        XCTAssertEqual(byName["old-chat"]?.linkedChat?.title, "Done long ago")
        XCTAssertNil(byName["safe-merged"]?.linkedChat)
    }

    func testWhichRowsCanBeTicked() {
        let all = rows(everyKind)
        let tickable = Set(all.filter(\.selectable).map { URL(fileURLWithPath: $0.id).lastPathComponent })
        XCTAssertEqual(tickable, ["safe-merged", "safe-unpushed", "dirty", "protected", "locked", "detached", "unverified", "old-chat"])
        for row in all where row.isInUse { XCTAssertFalse(row.selectable, row.id); XCTAssertNotNil(row.selectionBlocker) }
        XCTAssertFalse(all.first { $0.tree.isPrimary }!.selectable)
    }

    func testBulkSetHoldsOnlyWhatCleanupAllows() {
        let all = rows(everyKind)
        let everything = Set(all.map(\.id))
        let bulk = WorktreeBoard.bulkSet(everything, rows: all)
        XCTAssertEqual(Set(bulk.map { URL(fileURLWithPath: $0.path).lastPathComponent }), ["safe-merged", "safe-unpushed", "old-chat"])
        // Exhaustively: every subset of the rows gives a bulk set inside the allowed rows.
        let allowed = Set(all.filter(\.eligibility.allowed).map(\.id))
        for mask in 0..<(1 << all.count) {
            let selection = Set(all.indices.filter { mask & (1 << $0) != 0 }.map { all[$0].id })
            let ids = WorktreeBoard.bulkSet(selection, rows: all).map(\.path)
            XCTAssertTrue(Set(ids).isSubset(of: allowed.intersection(selection)))
            XCTAssertEqual(ids.count, Set(ids).count)
        }
        // A row that turns busy after being ticked leaves the bulk set and the selection.
        var changed = everyKind
        changed[0].agents = [chat(.working, path: changed[0].path)]
        let after = rows(changed)
        XCTAssertFalse(WorktreeBoard.bulkSet([changed[0].path], rows: after).contains { $0.path == changed[0].path })
        XCTAssertEqual(WorktreeBoard.prune([changed[0].path, "/gone"], rows: after), [])
        // Unknown ids never reach the bulk set.
        XCTAssertTrue(WorktreeBoard.bulkSet(["/fixture/elsewhere"], rows: all).isEmpty)
    }

    func testSelectSafeOnesTicksOnlySafeRows() {
        let all = rows(everyKind)
        let ids = WorktreeBoard.safeIDs(all)
        XCTAssertEqual(ids, Set(all.filter { $0.eligibility.allowed }.map(\.id)))
        XCTAssertEqual(Set(WorktreeBoard.bulkSet(ids, rows: all).map(\.path)), ids)
    }

    func testFilterCountsAndSummary() {
        let old = now.addingTimeInterval(-20 * 86_400)
        var trees = everyKind
        trees.append(tree("stale", lastCommit: old))
        let sizes = Dictionary(uniqueKeysWithValues: trees.map { ($0.path, Int64(100_000_000)) })
        let all = rows(trees, sizes: sizes)
        let counts = WorktreeBoard.counts(all, now: now)
        XCTAssertEqual(counts[.all], 14)
        XCTAssertEqual(counts[.inUse], 4)
        XCTAssertEqual(counts[.safe], 4)
        XCTAssertEqual(counts[.uncommitted], 2, "uncommitted counts busy rows too: it is work either way")
        XCTAssertEqual(counts[.untouched], 1)
        let summary = WorktreeBoard.summary(all)
        XCTAssertEqual(summary, WorktreeBoardSummary(total: 14, inUse: 4, safe: 4, uncommitted: 2, reclaimable: 400_000_000))
        // Reclaimable stays unknown until every safe row is measured.
        var partial = all; partial[0].size = nil
        XCTAssertNil(WorktreeBoard.summary(partial).reclaimable)
        // Unknown activity is not "untouched".
        var unknown = trees.last!; unknown.facts.lastCommit = nil
        XCTAssertFalse(WorktreeBoardFilter.untouched.matches(rows([unknown])[0], now: now))
    }

    func testProtectedFilterShowsWhatYouOrARuleProtects() {
        let all = rows(everyKind)
        let protected = all.filter { WorktreeBoardFilter.protected.matches($0, now: now) }.map { URL(fileURLWithPath: $0.id).lastPathComponent }
        // As the old sidebar's Protected: what you protected and what cleanup reports as Protected
        // (a repository's main checkout, a locked worktree).
        XCTAssertEqual(protected, ["main", "protected", "locked"])
        XCTAssertEqual(WorktreeBoard.counts(all, now: now)[.protected], 3)
        // Protected by you but in use right now: still listed under Protected.
        let busy = rows([tree("guarded", agents: [chat(.working, path: "/fixture/repo/guarded")], protected: true)])
        XCTAssertEqual(busy[0].kind, .inUse)
        XCTAssertTrue(WorktreeBoardFilter.protected.matches(busy[0], now: now))
        XCTAssertEqual(WorktreeBoard.groups(all, filter: .protected, sort: .branch, now: now).flatMap(\.rows).count, 3)
        XCTAssertEqual(WorktreeBoardFilter.protected.title, "Protected")
    }

    func testGroupsFilterAndSort() {
        let trees = [
            tree("a-old", repo: "small", lastCommit: now.addingTimeInterval(-9_000)),
            tree("b-new", repo: "big", lastCommit: now.addingTimeInterval(-100)),
            tree("c-mid", repo: "big", changed: 1, lastCommit: now.addingTimeInterval(-5_000)),
            tree("d", repo: "big", lastCommit: now.addingTimeInterval(-7_000)),
        ]
        let all = rows(trees, sizes: [trees[1].path: 5, trees[3].path: 9])
        let groups = WorktreeBoard.groups(all, filter: .all, sort: .lastActivity, now: now)
        XCTAssertEqual(groups.map(\.name), ["big", "small"])
        XCTAssertEqual(groups[0].rows.map(\.tree.branch), ["b-new", "c-mid", "d"])
        XCTAssertEqual(groups[0].safe, 2)
        XCTAssertEqual(groups[0].reclaimable, 14)
        XCTAssertNil(groups[1].reclaimable)
        XCTAssertEqual(WorktreeBoard.groups(all, filter: .all, sort: .size, now: now)[0].rows.map(\.tree.branch), ["d", "b-new", "c-mid"])
        XCTAssertEqual(WorktreeBoard.groups(all, filter: .all, sort: .branch, now: now)[0].rows.map(\.tree.branch), ["b-new", "c-mid", "d"])
        let dirty = WorktreeBoard.groups(all, filter: .uncommitted, sort: .lastActivity, now: now)
        XCTAssertEqual(dirty.map(\.name), ["big"])
        XCTAssertEqual(dirty[0].total, 3, "the header still counts the whole repository")
    }

    func testFormatting() {
        XCTAssertEqual(WorktreeBoardFormat.ago(now.addingTimeInterval(-20), now: now, calendar: utc), "now")
        XCTAssertEqual(WorktreeBoardFormat.ago(now.addingTimeInterval(-120), now: now, calendar: utc), "2 min ago")
        let noon = utc.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        XCTAssertEqual(WorktreeBoardFormat.ago(noon.addingTimeInterval(-7_200), now: noon, calendar: utc), "2 h ago")
        XCTAssertEqual(WorktreeBoardFormat.ago(noon.addingTimeInterval(-86_400), now: noon, calendar: utc), "yesterday")
        XCTAssertEqual(WorktreeBoardFormat.ago(noon.addingTimeInterval(-9 * 86_400), now: noon, calendar: utc), "9 days ago")
        XCTAssertEqual(WorktreeBoardFormat.ago(nil, now: now, calendar: utc), "—")
        XCTAssertEqual(WorktreeBoardFormat.bytes(412_000_000), "412 MB")
        XCTAssertEqual(WorktreeBoardFormat.bytes(1_130_000_000), "1.1 GB")
        XCTAssertEqual(WorktreeBoardFormat.bytes(820_000), "820 KB")
        XCTAssertEqual(WorktreeBoardFormat.bytes(nil), "—")
        XCTAssertEqual(WorktreeBoardFormat.compact(104_212), "104k")
        XCTAssertEqual(WorktreeBoardFormat.compact(6_712), "6.7k")
        XCTAssertEqual(WorktreeBoardFormat.compact(940), "940")
    }

    func testRepositoryHealthThresholds() throws {
        let busy = """
        count: 104212
        size: 412000
        in-pack: 2900000
        packs: 267
        size-pack: 3100000
        prune-packable: 12
        garbage: 0
        size-garbage: 0
        """
        let stats = try XCTUnwrap(RepositoryObjectStats.parse(busy))
        XCTAssertEqual(stats, RepositoryObjectStats(loose: 104_212, packs: 267, looseKiB: 412_000, packKiB: 3_100_000, prunePackable: 12))
        XCTAssertTrue(stats.needsAttention)
        XCTAssertEqual(stats.summary, "267 packs, 104k loose objects")
        // Git's own gc --auto limits: more than 6700 loose objects or more than 50 packs.
        XCTAssertFalse(RepositoryObjectStats(loose: 6_700, packs: 50).needsAttention)
        XCTAssertTrue(RepositoryObjectStats(loose: 6_701, packs: 1).needsAttention)
        XCTAssertTrue(RepositoryObjectStats(loose: 0, packs: 51).needsAttention)
        XCTAssertEqual(RepositoryObjectStats(loose: 1, packs: 1).summary, "1 pack, 1 loose object")
        XCTAssertNil(RepositoryObjectStats.parse("fatal: not a git repository"))
        XCTAssertNil(RepositoryObjectStats.parse("count: 3\n"))
        XCTAssertEqual(RepositoryMaintenance.parseDiskUsage("123\t/some/path\n"), 125_952)
        XCTAssertNil(RepositoryMaintenance.parseDiskUsage("du: cannot read"))
    }

    /// The gc keeps unreachable objects, reflogs and stale worktree registrations. Disposable repository only.
    func testConservativeGarbageCollectionLosesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("burro-gc-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo").path, side = root.appendingPathComponent("side").path
        func git(_ args: [String], input: String? = nil) throws -> String {
            let result = CommandRunner().run("/usr/bin/git", ["-C", repo, "-c", "commit.gpgsign=false"] + args, input: input.map { Data($0.utf8) })
            guard result.succeeded else { throw CleanupError.blocked(result.error) }
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try git(["init", "-q", "-b", "main"])
        for (key, value) in [("user.name", "Test"), ("user.email", "test@example.invalid"), ("gc.auto", "0"), ("maintenance.auto", "false")] {
            _ = try git(["config", key, value])
        }
        for index in 0..<12 {
            try "\(index)".write(toFile: repo + "/f\(index)", atomically: true, encoding: .utf8)
            _ = try git(["add", "."]); _ = try git(["commit", "-q", "-m", "c\(index)"])
        }
        _ = try git(["worktree", "add", "-q", "-b", "side", side])
        try FileManager.default.removeItem(atPath: side) // A stale registration gc must not prune.
        let orphan = try git(["hash-object", "-w", "--stdin"], input: "unreachable data")
        let reflog = try git(["reflog"]).split(separator: "\n").count
        let before = try XCTUnwrap(RepositoryMaintenance.objectStats(repo))
        XCTAssertGreaterThan(before.loose, 30)

        let result = await RepositoryMaintenance.collectGarbage(repo, timeout: 60)
        XCTAssertTrue(result.succeeded, result.error)

        let after = try XCTUnwrap(RepositoryMaintenance.objectStats(repo))
        XCTAssertLessThan(after.loose, before.loose)
        XCTAssertNoThrow(try git(["cat-file", "-e", orphan]), "unreachable objects are kept")
        XCTAssertEqual(try git(["reflog"]).split(separator: "\n").count, reflog, "reflogs are kept")
        XCTAssertTrue(try git(["worktree", "list", "--porcelain"]).contains(Paths.canonical(side)), "registrations are kept")
        let size = await RepositoryMaintenance.diskUsage(repo)
        XCTAssertGreaterThan(try XCTUnwrap(size), 0)
    }
}
