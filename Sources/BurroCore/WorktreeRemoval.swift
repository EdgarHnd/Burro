import Foundation

public enum WorktreeRemoval {
    public static func assessment(_ tree: Worktree) -> Assessment {
        let baseline = SafetyPolicy.assess(primary: tree.isPrimary, locked: tree.isLocked, missing: tree.isMissing,
            prunable: tree.isPrunable, branch: tree.branch, facts: tree.facts, agents: tree.agents,
            processes: tree.processes, protected: tree.protectedByUser, coverageWarnings: [])
        let coverage = tree.assessment.reasons.filter { !baseline.reasons.contains($0) }
        var facts = tree.facts
        facts.ignoredCount = 0 // Explicitly accepted in the Delete confirmation.
        return SafetyPolicy.assess(primary: tree.isPrimary, locked: tree.isLocked, missing: tree.isMissing,
            prunable: tree.isPrunable, branch: tree.branch, facts: facts,
            agents: tree.agents.filter { $0.pinned || ![.idle, .inactive].contains($0.state) },
            processes: tree.processes, protected: tree.protectedByUser, coverageWarnings: coverage)
    }
    /// Never force removal or delete the branch. Git performs the final dirty/locked check.
    public static func remove(_ tree: Worktree) -> String? {
        guard !tree.isPrimary, !tree.protectedByUser, assessment(tree).level == .candidate else {
            return "This worktree cannot be removed: " + assessment(tree).reasons.joined(separator: "; ")
        }
        let deadline = Date().addingTimeInterval(15)
        let runner = CommandRunner(deadline: deadline)
        let listed = runner.git(tree.repositoryPath, ["worktree", "list", "--porcelain", "-z"])
        let records = GitParser.worktrees(listed.output)
        guard listed.succeeded, let record = records.first(where: { $0.path == tree.path }),
              records.first?.path != tree.path, !record.locked, !record.prunable, record.head == tree.head else {
            return "Worktree registration changed. Refresh and review it again."
        }
        let facts = GitReader(deadline: deadline).facts(record, base: tree.facts.base, includeDiff: false)
        guard facts.errors.isEmpty, facts.merged == true, facts.unpushed == 0,
              facts.changed == 0, facts.untracked == 0, !facts.operationInProgress else {
            return "Worktree changed or contains local data. Nothing was deleted; inspect it in Burro."
        }
        // Recursive filesystem deletion must not inherit the inspection deadline.
        let result = CommandRunner().git(tree.repositoryPath, ["worktree", "remove", "--", tree.path], timeout: 600)
        if result.timedOut {
            return "Removal exceeded ten minutes and may be partially complete. Refresh to inspect the remaining folder and Git registration before retrying."
        }
        guard result.succeeded else { return "Git refused removal: " + (result.error.isEmpty ? "Git exited with code \(result.code). Refresh to inspect the folder and registration." : result.error) }
        return nil
    }
}
