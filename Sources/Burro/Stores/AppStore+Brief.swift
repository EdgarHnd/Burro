// Connects the Brief (OrchestratorBriefStore) to what AppStore holds: SSH hosts and Claude
// profiles for reading transcripts, Claude's usage windows for the budget, each chat's project for
// memory notes, the Orchestrator's proposals list (reloaded when a draft is added or removed) and
// Runs tab (reloaded when a triage run is logged), and the needs-you banner, which takes triage's
// headline once it exists.
import Foundation
import BurroCore

extension AppStore {
    func wireBrief() {
        brief.hosts = { [weak self] in self?.remoteHosts ?? [] }
        brief.profiles = { [weak self] in self?.usage.preferences.profiles ?? [:] }
        brief.usage = { [weak self] in
            guard let self, self.usage.enabled, let claude = self.usage.snapshot.providers.first(where: { $0.id == .claude }),
                  claude.issue == nil else { return nil }
            return TriageUsage(claude: claude.windows)
        }
        brief.project = { [weak self] session in self?.briefProject(session) ?? (URL(fileURLWithPath: session.cwd).lastPathComponent, nil) }
        brief.proposalsChanged = { [weak self] in self?.orchestrator.reloadActions() }
        brief.runLogged = { [weak self] in self?.orchestrator.reloadRuns() }
        brief.headlineReady = { [weak self] chat, headline in self?.chatNotifier.updateHeadline(chatID: chat, headline: headline) }
    }

    /// A chat's project: on this Mac, the repository owning its worktree; elsewhere, its folder.
    private func briefProject(_ session: AgentSession) -> (name: String, path: String?) {
        if session.remote == nil {
            let path = workspacePath(for: session)
            if let tree = snapshot.worktrees.first(where: { $0.path == path }) { return (tree.repository, tree.repositoryPath) }
            return (URL(fileURLWithPath: session.cwd).lastPathComponent, session.cwd)
        }
        return (URL(fileURLWithPath: session.cwd).lastPathComponent, session.cwd)
    }
}
