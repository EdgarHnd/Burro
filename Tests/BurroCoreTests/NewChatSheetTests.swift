import Foundation
import XCTest
@testable import BurroCore

/// The New chat sheet's recent prompts and templates, the new-worktree rules (against throwaway
/// repositories in a temporary folder only), the quota line and the pending row's worktree states.
final class NewChatSheetTests: XCTestCase {
    // MARK: Recent prompts and templates

    func testRecentPromptsAreNewestFirstDedupedAndCappedPerProject() {
        var memory = LaunchPromptMemory()
        for index in 0..<25 { memory.recordStart("Prompt \(index)", folder: "/p/one") }
        memory.recordStart("  Prompt 3 \n", folder: "/p/one/")
        let list = memory.recentPrompts(folder: "/p/one")
        XCTAssertEqual(list.count, LaunchPromptMemory.recentLimit)
        XCTAssertEqual(list.first, "Prompt 3")
        XCTAssertEqual(list.filter { $0 == "Prompt 3" }.count, 1)
        XCTAssertEqual(list[1], "Prompt 24")
        XCTAssertFalse(list.contains("Prompt 0"))
        XCTAssertEqual(memory.recentPrompts(folder: "/p/two"), [])
    }

    func testRecentPromptsKeepThisMacAndAnotherMachineApart() {
        var memory = LaunchPromptMemory()
        let host = UUID()
        memory.recordStart("here", folder: "/p/app")
        memory.recordStart("there", folder: "/p/app", machine: host)
        XCTAssertEqual(memory.recentPrompts(folder: "/p/app"), ["here"])
        XCTAssertEqual(memory.recentPrompts(folder: "/p/app", machine: host), ["there"])
        memory.recordStart("   ", folder: "/p/app")
        memory.recordStart("no folder", folder: "")
        XCTAssertEqual(memory.recentPrompts(folder: "/p/app"), ["here"])
    }

    func testOldestProjectsAreForgotten() {
        var memory = LaunchPromptMemory()
        for index in 0...LaunchPromptMemory.projectLimit { memory.recordStart("x", folder: "/p/\(index)") }
        XCTAssertEqual(memory.recent.count, LaunchPromptMemory.projectLimit)
        XCTAssertEqual(memory.recentPrompts(folder: "/p/0"), [])
        XCTAssertEqual(memory.recentPrompts(folder: "/p/\(LaunchPromptMemory.projectLimit)"), ["x"])
    }

    func testLongPromptsAreKeptWholeOrNotAtAllAndShownByFirstLine() {
        var memory = LaunchPromptMemory()
        let long = String(repeating: "a", count: 9_000)
        memory.recordStart(long, folder: "/p")
        XCTAssertEqual(memory.recentPrompts(folder: "/p"), [long], "kept whole")
        let limit = String(repeating: "b", count: LaunchPromptMemory.storedPromptLimit)
        memory.recordStart(limit, folder: "/p")
        XCTAssertEqual(memory.recentPrompts(folder: "/p").first, limit)
        // Longer than the limit: not remembered, not offered as a template, never shortened.
        memory.recordStart(limit + "c", folder: "/p")
        XCTAssertEqual(memory.recentPrompts(folder: "/p"), [limit, long])
        XCTAssertFalse(memory.canSave(limit + "c"))
        XCTAssertNil(memory.saveTemplate(limit + "c"))
        XCTAssertTrue(memory.recent.values.joined().allSatisfy { $0 == long || $0 == limit })
        // Past 1 MB encoded the oldest prompts go, whole; the one just started stays.
        var full = LaunchPromptMemory()
        for index in 0..<80 { full.recordStart(String(repeating: "\(index % 10)", count: 19_000) + "\(index)", folder: "/p/\(index % 5)") }
        let all = full.recent.values.flatMap { $0 }
        XCTAssertLessThanOrEqual(full.encodedSize, LaunchPromptMemory.encodedLimit)
        XCTAssertGreaterThan(all.count, 40, "only as many as needed are dropped")
        XCTAssertTrue(all.allSatisfy { $0.count >= 19_001 }, "nothing cut")
        XCTAssertEqual(full.recentPrompts(folder: "/p/4").first?.hasSuffix("79"), true)
        XCTAssertNotNil(LaunchPromptMemory.decode(full.encoded()))
        XCTAssertEqual(LaunchPromptMemory.firstLine("\n\n  Fix the build  \nthen more"), "Fix the build")
        let chip = LaunchPromptMemory.firstLine(String(repeating: "word ", count: 40), limit: 20)
        XCTAssertTrue(chip.hasSuffix("…"))
        XCTAssertLessThanOrEqual(chip.count, 20)
    }

    func testTheLimitIsOnEncodedBytesNotCharacters() {
        // Emoji, CJK, quotes and newlines encode to many more bytes than characters.
        var memory = LaunchPromptMemory()
        let heavy = String(repeating: "🦙漢\"\n\\", count: 3_900)   // 19,500 characters, far more bytes
        XCTAssertLessThanOrEqual(heavy.count, LaunchPromptMemory.storedPromptLimit)
        for index in 0..<40 { memory.recordStart(heavy + "\(index)", folder: "/p/\(index % 20)") }
        XCTAssertLessThanOrEqual(memory.encodedSize, LaunchPromptMemory.encodedLimit)
        XCTAssertEqual(memory.recentPrompts(folder: "/p/19").first, heavy + "39", "the newest stays")
        XCTAssertTrue(memory.recent.values.joined().allSatisfy { $0.hasPrefix(heavy) }, "kept whole")
        XCTAssertNotNil(LaunchPromptMemory.decode(memory.encoded()))
        // Templates are never dropped: one that wouldn't fit even alone with the others isn't saved.
        var templates = LaunchPromptMemory()
        var saved = 0
        for index in 0..<40 where templates.saveTemplate(heavy + "t\(index)", id: "t\(index)") != nil { saved += 1 }
        XCTAssertGreaterThan(saved, 0)
        XCTAssertLessThan(saved, 40)
        XCTAssertEqual(templates.saved.count, saved, "none removed to make room")
        XCTAssertFalse(templates.canSave(heavy + "more"), "Save as template is off when it can't fit")
        XCTAssertLessThanOrEqual(templates.encodedSize, LaunchPromptMemory.encodedLimit)
        // Saving a template that fits makes room by forgetting recent prompts, oldest first.
        var mixed = memory
        let before = mixed.recent.values.joined().count
        XCTAssertNotNil(mixed.saveTemplate(heavy + "keep", id: "k"))
        XCTAssertLessThanOrEqual(mixed.encodedSize, LaunchPromptMemory.encodedLimit)
        XCTAssertLessThan(mixed.recent.values.joined().count, before)
        // Reads ignore anything over 2 MB.
        XCTAssertNil(LaunchPromptMemory.decode(Data(count: LaunchPromptMemory.decodeLimit + 1)))
    }

    func testTemplatesSaveDeleteAndKeepTheBuiltIns() throws {
        var memory = LaunchPromptMemory()
        XCTAssertEqual(memory.templates.map(\.title), ["Fix the failing CI run", "Review this pull request", "Write release notes"])
        XCTAssertFalse(memory.canSave("   "))
        XCTAssertFalse(memory.canSave(LaunchTemplate.builtIns[0].prompt))
        let saved = try XCTUnwrap(memory.saveTemplate("Bump the version\nand tag it", id: "mine"))
        XCTAssertEqual(saved.title, "Bump the version")
        XCTAssertFalse(saved.builtIn)
        XCTAssertNil(memory.saveTemplate("Bump the version\nand tag it"), "the same prompt isn't saved twice")
        XCTAssertEqual(memory.templates.count, 4)
        memory.deleteTemplate("builtin.ci")
        XCTAssertEqual(memory.templates.count, 4, "built-ins can't be deleted")
        memory.deleteTemplate("mine")
        XCTAssertEqual(memory.templates.count, 3)
    }

    func testPromptMemoryRoundTripsAndIgnoresDamage() throws {
        var memory = LaunchPromptMemory()
        memory.recordStart("hello", folder: "/p")
        memory.saveTemplate("mine", id: "1")
        XCTAssertEqual(LaunchPromptMemory.decode(memory.encoded()), memory)
        XCTAssertNil(LaunchPromptMemory.decode(Data("nope".utf8)))
        XCTAssertNil(LaunchPromptMemory.decode(nil))
    }

    // MARK: Worktree names

    func testSlugUsesThePromptsFirstMeaningfulWords() {
        XCTAssertEqual(NewWorktree.slug(from: "The streak freeze tile in the shop shows the old price"), "streak-freeze-tile-shop")
        XCTAssertEqual(NewWorktree.slug(from: "Fix Café crash: iOS 18!"), "fix-cafe-crash-ios")
        XCTAssertEqual(NewWorktree.slug(from: "   "), "chat")
        XCTAssertEqual(NewWorktree.slug(from: "日本語 だけ"), "chat")
        XCTAssertEqual(NewWorktree.slug(from: String(repeating: "x", count: 60)).count, 40)
        XCTAssertEqual(NewWorktree.slug(from: "internationalization localization accessibility documentation"), "internationalization-localization")
        XCTAssertEqual(NewWorktree.branchName(prompt: "Refresh shop prices", provider: .claude), "claude/refresh-shop-prices")
        XCTAssertEqual(NewWorktree.branchName(prompt: "Refresh shop prices", provider: .codex), "codex/refresh-shop-prices")
    }

    func testFolderSitsNextToTheMainCheckout() {
        XCTAssertEqual(NewWorktree.folder(repository: "/Users/me/Dev/app", slug: "fix-it"), "/Users/me/Dev/app-worktrees/fix-it")
        XCTAssertEqual(NewWorktree.folder(repository: "/Users/me/Dev/app/", slug: "fix-it"), "/Users/me/Dev/app-worktrees/fix-it")
    }

    func testPlanSkipsTakenBranchesAndFolders() throws {
        let plan = try XCTUnwrap(NewWorktree.plan(prompt: "Fix it", provider: .claude, repository: "/r/app",
                                                  branchTaken: { $0 == "claude/fix" }, pathTaken: { $0 == "/r/app-worktrees/fix-2" }))
        XCTAssertEqual(plan, NewWorktreePlan(slug: "fix-3", branch: "claude/fix-3", path: "/r/app-worktrees/fix-3"))
        XCTAssertNil(NewWorktree.plan(prompt: "Fix it", provider: .claude, repository: "/r/app", branchTaken: { _ in true }, pathTaken: { _ in false }))
    }

    // MARK: Creating a worktree (throwaway repositories only)

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-newworktree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return URL(fileURLWithPath: Paths.canonical(folder.path))
    }

    @discardableResult
    private func git(_ path: String, _ arguments: [String]) -> CommandResult {
        CommandRunner().run("/usr/bin/git", ["-c", "user.name=Test", "-c", "user.email=test@localhost", "-c", "commit.gpgsign=false",
                                             "-c", "init.defaultBranch=main", "-C", path] + arguments)
    }

    /// A repository with one commit, its hooks folder pinned (so a global hooks setting can't interfere).
    private func repository(in folder: URL, commit: Bool = true) throws -> String {
        let repo = folder.appendingPathComponent("app").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        XCTAssertTrue(git(repo, ["init", "-q"]).succeeded)
        XCTAssertTrue(git(repo, ["config", "core.hooksPath", repo + "/.git/hooks"]).succeeded)
        if commit {
            try "hello\n".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
            XCTAssertTrue(git(repo, ["add", "README.md"]).succeeded)
            XCTAssertTrue(git(repo, ["commit", "-q", "-m", "first"]).succeeded)
        }
        return repo
    }

    private func branches(_ repo: String) -> [String] {
        git(repo, ["for-each-ref", "--format=%(refname:short)", "refs/heads"]).output.split(separator: "\n").map(String.init)
    }
    private func worktreeCount(_ repo: String) -> Int {
        GitParser.worktrees(git(repo, ["worktree", "list", "--porcelain", "-z"]).output).count
    }

    func testCreatesTheWorktreeOnANewBranchNextToTheRepository() throws {
        let folder = try scratch()
        let repo = try repository(in: folder)
        XCTAssertTrue(NewWorktree.isGitProject(repo))
        let tree = try NewWorktree.create(in: repo, prompt: "Refresh the shop prices after purchase", provider: .claude)
        XCTAssertEqual(tree.branch, "claude/refresh-shop-prices-after")
        XCTAssertEqual(tree.path, folder.appendingPathComponent("app-worktrees/refresh-shop-prices-after").path)
        XCTAssertEqual(tree.repository, repo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.path + "/README.md"))
        XCTAssertTrue(NewWorktree.isGitProject(tree.path))
        XCTAssertEqual(git(tree.path, ["rev-parse", "--abbrev-ref", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines), tree.branch)
        // The same prompt again gets the next free name; started from inside the first worktree it
        // still goes next to the main checkout.
        let again = try NewWorktree.create(in: tree.path, prompt: "Refresh the shop prices after purchase", provider: .claude)
        XCTAssertEqual(again.branch, "claude/refresh-shop-prices-after-2")
        XCTAssertEqual(again.path, folder.appendingPathComponent("app-worktrees/refresh-shop-prices-after-2").path)
        XCTAssertEqual(worktreeCount(repo), 3)
    }

    func testStartFolderKeepsTheProjectsPlaceInsideItsCheckout() {
        let all: (String) -> Bool = { _ in true }
        XCTAssertEqual(NewWorktree.startFolder(project: "/r/app", checkout: "/r/app", worktree: "/r/app-worktrees/x", exists: all), "/r/app-worktrees/x")
        XCTAssertEqual(NewWorktree.startFolder(project: "/r/app/packages/web", checkout: "/r/app", worktree: "/r/app-worktrees/x", exists: all),
                       "/r/app-worktrees/x/packages/web")
        XCTAssertEqual(NewWorktree.startFolder(project: "/r/app/packages/web", checkout: "/r/app/", worktree: "/w", exists: all), "/w/packages/web")
        // Not there in the new worktree (untracked, ignored): the worktree's root.
        XCTAssertEqual(NewWorktree.startFolder(project: "/r/app/build", checkout: "/r/app", worktree: "/w", exists: { _ in false }), "/w")
        // A sibling that only shares a prefix, an unknown checkout, or "..": the root.
        XCTAssertEqual(NewWorktree.startFolder(project: "/r/app2/web", checkout: "/r/app", worktree: "/w", exists: all), "/w")
        XCTAssertEqual(NewWorktree.startFolder(project: "/r/app/web", checkout: "", worktree: "/w", exists: all), "/w")
        XCTAssertEqual(NewWorktree.startFolder(project: "/r/app/../etc", checkout: "/r/app", worktree: "/w", exists: all), "/w")
    }

    func testASubfolderProjectStartsInTheSameSubfolderOfTheWorktree() throws {
        let folder = try scratch()
        let repo = try repository(in: folder)
        try FileManager.default.createDirectory(atPath: repo + "/packages/web", withIntermediateDirectories: true)
        try "x\n".write(toFile: repo + "/packages/web/index.js", atomically: true, encoding: .utf8)
        XCTAssertTrue(git(repo, ["add", "."]).succeeded)
        XCTAssertTrue(git(repo, ["commit", "-q", "-m", "web"]).succeeded)
        let tree = try NewWorktree.create(in: repo + "/packages/web", prompt: "Tidy the web package", provider: .codex)
        XCTAssertEqual(tree.folder, tree.path + "/packages/web")
        XCTAssertEqual(tree.repository, repo)
        // Started from the repository root, the chat starts at the worktree's root.
        let root = try NewWorktree.create(in: repo, prompt: "Tidy the root", provider: .codex)
        XCTAssertEqual(root.folder, root.path)
    }

    func testDiscardUndoesAnUnusedWorktreeOnly() throws {
        let folder = try scratch()
        let repo = try repository(in: folder)
        let tree = try NewWorktree.create(in: repo, prompt: "Dismissed before it started", provider: .claude)
        XCTAssertEqual(worktreeCount(repo), 2)
        XCTAssertEqual(NewWorktree.discard(tree), [])
        XCTAssertEqual(branches(repo), ["main"])
        XCTAssertEqual(worktreeCount(repo), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("app-worktrees").path))
        // Something written into a worktree keeps it (no force): reported as left behind.
        let used = try NewWorktree.create(in: repo, prompt: "Someone wrote here", provider: .claude)
        try "work\n".write(toFile: used.path + "/notes.txt", atomically: true, encoding: .utf8)
        XCTAssertFalse(NewWorktree.discard(used).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: used.path + "/notes.txt"))
        XCTAssertTrue(branches(repo).contains(used.branch), "a branch still checked out isn't deleted")
    }

    func testRefusesFoldersThatCantBranchAndLeavesNothing() throws {
        let folder = try scratch()
        let plain = folder.appendingPathComponent("plain").path
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        XCTAssertFalse(NewWorktree.isGitProject(plain))
        XCTAssertThrowsError(try NewWorktree.create(in: plain, prompt: "x", provider: .codex)) {
            XCTAssertEqual($0 as? NewWorktreeError, .notRepository)
        }
        XCTAssertThrowsError(try NewWorktree.create(in: folder.appendingPathComponent("gone").path, prompt: "x", provider: .codex)) {
            XCTAssertEqual($0 as? NewWorktreeError, .missingFolder)
        }
        let empty = try repository(in: folder, commit: false)
        XCTAssertThrowsError(try NewWorktree.create(in: empty, prompt: "x", provider: .codex)) {
            XCTAssertEqual($0 as? NewWorktreeError, .noCommits)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("app-worktrees").path))
        XCTAssertEqual(branches(empty), [])
    }

    func testAFailedCheckoutIsUndoneCompletely() throws {
        let folder = try scratch()
        let repo = try repository(in: folder)
        // A post-checkout hook that fails: git registers and checks out the worktree, then reports failure.
        let hook = repo + "/.git/hooks/post-checkout"
        try "#!/bin/sh\necho 'hook says no' >&2\nexit 1\n".write(toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        XCTAssertThrowsError(try NewWorktree.create(in: repo, prompt: "Try this", provider: .codex)) { error in
            guard case .gitFailed(_, let leftovers)? = error as? NewWorktreeError else { return XCTFail("\(error)") }
            XCTAssertEqual(leftovers, [])
        }
        XCTAssertEqual(branches(repo), ["main"])
        XCTAssertEqual(worktreeCount(repo), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("app-worktrees").path))
    }

    func testABlockedFolderFailsWithGitsReasonAndLeavesNoBranch() throws {
        let folder = try scratch()
        let repo = try repository(in: folder)
        // The worktrees folder is a plain file, so git can't create the checkout there.
        try "not a folder".write(toFile: folder.appendingPathComponent("app-worktrees").path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try NewWorktree.create(in: repo, prompt: "Try this", provider: .codex)) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.hasPrefix("Git couldn't create the worktree"), message)
        }
        XCTAssertEqual(branches(repo), ["main"])
        XCTAssertEqual(worktreeCount(repo), 1)
        XCTAssertEqual(try String(contentsOfFile: folder.appendingPathComponent("app-worktrees").path, encoding: .utf8), "not a folder")
    }

    // MARK: Pending row and drafts

    func testPendingRowSaysItIsCreatingTheWorktreeAndRetryAsksAgainOnlyWhenNoneWasMade() throws {
        var launches = PendingLaunches()
        let request = LaunchRequest(provider: .claude, prompt: "Fix it", folder: "/r/app")
        let now = Date(timeIntervalSince1970: 1_000)
        let launch = launches.begin(request, follow: true, now: now, worktreeBranch: "claude/fix")
        XCTAssertEqual(launches.launch(launch.id)?.status(now: now), "Creating worktree claude/fix…")
        XCTAssertTrue(try XCTUnwrap(launches.launch(launch.id)).retryInNewWorktree)
        launches.worktreeCreated(launch.id, folder: "/r/app-worktrees/fix-2", branch: "claude/fix-2")
        let made = try XCTUnwrap(launches.launch(launch.id))
        XCTAssertEqual(made.request.folder, "/r/app-worktrees/fix-2")
        XCTAssertFalse(made.retryInNewWorktree)
        XCTAssertEqual(made.status(now: now), "Starting… checking it got going")
        let remote = launches.begin(request, follow: true, now: now, machine: UUID(), machineName: "Mini", worktreeBranch: "claude/fix")
        XCTAssertNil(launches.launch(remote.id)?.worktreeBranch, "never on another machine")
    }

    func testDraftsAndFormsCarryTheSwitchOnThisMacOnly() {
        let request = LaunchRequest(provider: .codex, prompt: "x", folder: "/r/app")
        XCTAssertTrue(LaunchDraft(retrying: request, newWorktree: true).newWorktree)
        XCTAssertFalse(LaunchDraft(retrying: request, machine: UUID(), newWorktree: true).newWorktree)
        var form = LaunchForm(draft: LaunchDraft(retrying: request, newWorktree: true), fallbackFolder: "", defaults: LaunchDefaults(),
                              models: { _ in [] })
        XCTAssertTrue(form.newWorktree)
        form.selectMachine(UUID(), defaults: LaunchDefaults(), localFolder: "", models: { _ in [] })
        XCTAssertFalse(form.newWorktree)
    }

    // MARK: Quota line

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    // Monday 16 November 2026, 18:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_794_852_000)

    private func usage(_ provider: UsageProvider, _ windows: [UsageWindow], updated: Date? = nil, issue: UsageIssue? = nil) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(availability: .available,
                              providers: [ProviderUsage(id: provider, updatedAt: updated ?? now, windows: windows, issue: issue)])
    }

    func testQuotaLineNamesTheSessionWithItsResetTime() {
        let snapshot = usage(.claude, [
            UsageWindow(id: "session", title: "Session", remainingPercent: 38.4, resetsAt: now.addingTimeInterval(5 * 3600), duration: 5 * 3600),
            UsageWindow(id: "weekly", title: "Weekly", remainingPercent: 71, resetsAt: now.addingTimeInterval(3 * 86400), duration: 7 * 86400),
        ])
        XCTAssertEqual(LaunchQuota.line(provider: .claude, modelTitle: "Opus 5.5", usage: snapshot, now: now, calendar: utc),
                       "Claude session: 38% left · resets 23:00")
    }

    func testQuotaLinePrefersTheTighterLimitIncludingTheChosenModelsOwn() {
        let snapshot = usage(.claude, [
            UsageWindow(id: "session", title: "Session", remainingPercent: 80, resetsAt: now.addingTimeInterval(3600), duration: 5 * 3600),
            UsageWindow(id: "weekly", title: "Weekly", remainingPercent: 40, resetsAt: now.addingTimeInterval(3 * 86400), duration: 7 * 86400),
            UsageWindow(id: "weekly-model:opus", title: "Opus weekly", remainingPercent: 12, resetsAt: now.addingTimeInterval(2 * 86400),
                        duration: 7 * 86400, model: "Opus"),
        ])
        XCTAssertEqual(LaunchQuota.line(provider: .claude, modelTitle: "Opus 5.5", usage: snapshot, now: now, calendar: utc),
                       "Claude Opus weekly: 12% left · resets Wed 18:00")
        XCTAssertEqual(LaunchQuota.line(provider: .claude, modelTitle: "Sonnet 5.5", usage: snapshot, now: now, calendar: utc),
                       "Claude weekly: 40% left · resets Thu 18:00")
    }

    func testQuotaLineTieGoesToTheShorterWindowAndCodexUsesItsOwnLimits() {
        let codex = usage(.codex, [
            UsageWindow(id: "codex:secondary", title: "Weekly", remainingPercent: 50, resetsAt: nil, duration: 7 * 86400),
            UsageWindow(id: "codex:primary", title: "5 hours", remainingPercent: 50, resetsAt: now.addingTimeInterval(1800), duration: 5 * 3600),
            UsageWindow(id: "other:primary", title: "Spark · 5 hours", remainingPercent: 1, resetsAt: nil, duration: 5 * 3600),
        ])
        XCTAssertEqual(LaunchQuota.line(provider: .codex, modelTitle: nil, usage: codex, now: now, calendar: utc),
                       "Codex 5-hour: 50% left · resets 18:30")
    }

    func testQuotaLineIsHiddenWhenUnknown() {
        let session = UsageWindow(id: "session", title: "Session", remainingPercent: 38, resetsAt: now.addingTimeInterval(3600), duration: 5 * 3600)
        XCTAssertNil(LaunchQuota.line(provider: .claude, modelTitle: nil, usage: .loading, now: now, calendar: utc))
        XCTAssertNil(LaunchQuota.line(provider: .claude, modelTitle: nil, usage: .disabled, now: now, calendar: utc))
        XCTAssertNil(LaunchQuota.line(provider: .codex, modelTitle: nil, usage: usage(.claude, [session]), now: now, calendar: utc))
        XCTAssertNil(LaunchQuota.line(provider: .claude, modelTitle: nil, usage: usage(.claude, [session], issue: .signInRequired), now: now, calendar: utc))
        XCTAssertNil(LaunchQuota.line(provider: .claude, modelTitle: nil, usage: usage(.claude, [session], updated: now.addingTimeInterval(-3600)),
                                      now: now, calendar: utc), "a stale reading isn't shown")
        let expired = UsageWindow(id: "session", title: "Session", remainingPercent: 2, resetsAt: now.addingTimeInterval(-60), duration: 5 * 3600)
        XCTAssertNil(LaunchQuota.line(provider: .claude, modelTitle: nil, usage: usage(.claude, [expired]), now: now, calendar: utc))
        let unknown = UsageWindow(id: "session", title: "Session", remainingPercent: nil, resetsAt: nil, duration: 5 * 3600)
        XCTAssertNil(LaunchQuota.line(provider: .claude, modelTitle: nil, usage: usage(.claude, [unknown]), now: now, calendar: utc))
    }
}
