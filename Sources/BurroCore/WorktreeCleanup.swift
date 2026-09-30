// User-initiated cleanup preserves the checkout in Trash; background scans remain read-only.
import Foundation

public enum CleanupStatus: String, Codable, Sendable {
    case ready = "Ready to remove", inUse = "In use", localChanges = "Local changes"
    case protected = "Protected", managed = "Archive in Codex", needsBranch = "Save commits first"
    case gitBusy = "Git in progress", unknown = "Cannot verify"
}
public struct CleanupEligibility: Sendable {
    public var status: CleanupStatus
    public var reasons: [String]
    public var managedByCodex: Bool
    public var allowed: Bool { status == .ready }
    public var summary: String { reasons.first ?? status.rawValue }
}
public enum CleanupError: Error, LocalizedError {
    case blocked(String)
    public var errorDescription: String? { switch self { case .blocked(let message): message } }
}
public actor WorktreeCleanup {
    public init() {}
    public static func eligibility(_ tree: Worktree, home: String, warnings: [String], registeredPaths: [String] = []) -> CleanupEligibility {
        let managed = Paths.contains(Paths.canonical(home + "/.codex/worktrees"), tree.path)
            || tree.agents.contains { $0.provider == .codex && $0.attachedPaths.contains { Paths.contains(tree.path, $0) } }
        func verdict(_ status: CleanupStatus, _ reasons: [String]) -> CleanupEligibility {
            CleanupEligibility(status: status, reasons: reasons, managedByCodex: managed)
        }
        if tree.isPrimary { return verdict(.protected, ["Main checkout of this repository"]) }
        if tree.protectedByUser { return verdict(.protected, ["Protected by you"]) }
        if tree.isLocked { return verdict(.protected, ["Git has locked this worktree"]) }
        if ["main", "master", "staging", "develop"].contains(tree.branch) { return verdict(.protected, ["Protected branch: " + tree.branch]) }
        if tree.agents.contains(where: { $0.pinned }) { return verdict(.protected, ["A pinned Codex chat is attached"]) }
        if registeredPaths.contains(where: { $0 != tree.path && Paths.contains(tree.path, $0) }) {
            return verdict(.protected, ["Another registered worktree is nested inside this folder"])
        }
        let open = tree.agents.filter { $0.state.keepsWorktree }.count
        if open > 0 || !tree.processes.isEmpty {
            return verdict(.inUse, (open > 0 ? ["\(open) attached chat(s) still open or active"] : [])
                + (tree.processes.isEmpty ? [] : ["\(tree.processes.count) process(es) using this folder"]))
        }
        if tree.facts.operationInProgress { return verdict(.gitBusy, ["Finish the Git operation or resolve its lock first"]) }
        if tree.isMissing || tree.isPrunable { return verdict(.unknown, ["The folder or its Git registration is missing; inspect it manually"]) }
        let errors = tree.facts.errors + warnings
        if !errors.isEmpty { return verdict(.unknown, Array(Set(errors)).sorted()) }
        if tree.facts.changed > 0 || tree.facts.untracked > 0 {
            return verdict(.localChanges,
                (tree.facts.changed > 0 ? ["\(tree.facts.changed) modified or staged file(s); save or discard them first"] : [])
                + (tree.facts.untracked > 0 ? ["\(tree.facts.untracked) untracked file(s); save or discard them first"] : []))
        }
        if managed { return verdict(.managed, ["Archive from its chat in Codex to preserve snapshots and attachments"]) }
        guard tree.facts.retentionChecked == true else { return verdict(.unknown, ["Commit preservation has not been checked yet"]) }
        guard let branch = tree.facts.retainedBranchName else {
            return verdict(.needsBranch, ["No local branch preserves this detached commit. Create a branch at HEAD before removing the folder."])
        }
        // Removing a checkout does not delete its branch. Integration and publication
        // are useful context, not removal gates when a verified local branch retains HEAD.
        return verdict(.ready, ["Commits stay on " + branch,
            tree.facts.ignoredCount > 0 ? "Ignored files move to Trash with the folder" : "Clean checkout; no attached chats or processes"])
    }
    public func remove(_ expected: Worktree, configuration: ScanConfiguration) async throws -> URL {
        try await remove(expected, configuration: configuration, trash: { source in
            var destination: NSURL?
            try FileManager.default.trashItem(at: source, resultingItemURL: &destination)
            guard let destination else { throw CleanupError.blocked("The folder was moved to Trash, but its new location could not be determined. Refresh the list before continuing.") }
            return destination as URL
        })
    }
    // The injected mover is used only by tests with disposable repositories.
    func remove(_ expected: Worktree, configuration: ScanConfiguration,
                trash: @Sendable (URL) throws -> URL) async throws -> URL {
        var config = configuration
        config.repositories = [expected.repositoryPath]; config.discover = false
        let scan = await Scanner().scan(config)
        guard let fresh = scan.worktrees.first(where: { $0.path == expected.path }),
              fresh.head == expected.head, fresh.branch == expected.branch,
              fresh.repositoryPath == expected.repositoryPath, fresh.facts.base == expected.facts.base else {
            throw CleanupError.blocked("This worktree changed or disappeared. Refresh and review it again.")
        }
        guard !config.protectedPaths.contains(where: { Paths.contains(fresh.path, $0) }) else {
            throw CleanupError.blocked("This folder or a nested worktree is protected by you.")
        }
        let eligibility = Self.eligibility(fresh, home: config.home, warnings: scan.warnings, registeredPaths: scan.worktrees.map(\.path))
        guard eligibility.allowed else { throw CleanupError.blocked(eligibility.reasons.joined(separator: "\n")) }
        let runner = CommandRunner()
        func registered() throws -> [WorktreeRecord] {
            let result = runner.git(fresh.repositoryPath, ["worktree", "list", "--porcelain", "-z"])
            guard result.succeeded else { throw CleanupError.blocked("Git registrations could not be verified.") }
            return GitParser.worktrees(result.output)
        }
        let records = try registered()
        guard let record = records.first(where: { $0.path == fresh.path }),
              record.head == fresh.head, record.branch == fresh.branch, !record.locked, !record.prunable,
              records.first?.path != fresh.path,
              Paths.canonical(fresh.path) == fresh.path else {
            throw CleanupError.blocked("The worktree registration changed. Refresh and review it again.")
        }
        // Git facts are read once more immediately before the filesystem operation.
        var latest = fresh; latest.facts = GitReader().facts(record, base: fresh.facts.base)
        let processes = ProcessReader.snapshot()
        let agents = AgentReader().read(home: config.home, processes: processes, now: Date())
        latest.agents = agents.sessions.filter {
            Paths.contains(fresh.path, $0.cwd) || $0.attachedPaths.contains { Paths.contains(fresh.path, $0) }
        }
        latest.processes = processes.processes.filter { Paths.contains(fresh.path, $0.cwd) }
        let final = Self.eligibility(latest, home: config.home, warnings: scan.warnings + agents.warnings + processes.warnings,
            registeredPaths: records.map(\.path))
        guard final.allowed else { throw CleanupError.blocked(final.reasons.joined(separator: "\n")) }
        guard let retained = latest.facts.retainedBranch,
              runner.git(fresh.repositoryPath, ["merge-base", "--is-ancestor", fresh.head, retained]).succeeded else {
            throw CleanupError.blocked("The branch preserving this worktree changed. Refresh and review it again.")
        }
        let destination = try trash(URL(fileURLWithPath: fresh.path))
        // Never follow a replacement directory at the old path or prune other worktrees.
        let after: [WorktreeRecord]
        do { after = try registered() }
        catch { throw CleanupError.blocked("Your folder is preserved at \(destination.path). Git registrations could not be read; no further cleanup was attempted.") }
        guard runner.git(fresh.repositoryPath, ["merge-base", "--is-ancestor", fresh.head, retained]).succeeded,
              !FileManager.default.fileExists(atPath: fresh.path),
              let registration = after.first(where: { $0.path == fresh.path }),
              registration.head == fresh.head, registration.branch == fresh.branch, !registration.locked else {
            throw CleanupError.blocked("Your folder is preserved at \(destination.path). Git registration or commit preservation changed; the registration was left untouched. Refresh and inspect it manually.")
        }
        let removal = runner.git(fresh.repositoryPath, ["worktree", "remove", "--", fresh.path])
        guard removal.succeeded else {
            throw CleanupError.blocked("Your folder is preserved at \(destination.path). Git could not remove the missing-folder registration. The branch was kept. Refresh and inspect it manually.")
        }
        return destination
    }
}
