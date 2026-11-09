// What the orchestrator sees: Burro's current picture of machines, chats, projects, worktrees
// and to-dos, flattened for the tool server. Built on demand, in memory, from state Burro holds.
import Foundation
import BurroCore

extension AppStore {
    func orchestratorState() -> OrchestratorState {
        let summary = homeSummary
        let machineRows = summary.machines.map { machine in
            let facts = machines.facts[machine.id]
            return OrchestratorState.Machine(
                id: machine.id, name: machine.name, connection: Self.connectionText(machine.connection), lastSeen: machine.lastSeen,
                os: facts?.os, versions: Dictionary(uniqueKeysWithValues: (facts?.versions ?? [:]).map { ($0.key.rawValue, $0.value) }))
        }
        let projects = summary.projects.map {
            OrchestratorState.Project(name: $0.name, path: $0.id, isRepository: $0.isRepository, worktrees: $0.worktrees,
                                      readyToRemove: $0.readyToRemove, tokensToday: $0.tokensToday, lastActive: $0.lastActive)
        }
        let trees = availableWorktrees.map { tree in
            OrchestratorState.WorktreeRow(
                path: tree.path, repository: tree.repository, repositoryPath: tree.repositoryPath, branch: tree.branch,
                isPrimary: tree.isPrimary, changed: tree.facts.changed, untracked: tree.facts.untracked, unpushed: tree.facts.unpushed,
                lastCommit: tree.facts.lastCommit, activity: tree.activity, readyToRemove: cleanupEligibility(tree).allowed)
        }
        let today = TodoDay.key()
        let todoRows = todos.items.filter { $0.day == today || !$0.done }.sorted { $0.order < $1.order }.map {
            OrchestratorState.Todo(text: $0.text, done: $0.done, day: $0.day, project: $0.project)
        }
        var seen = Set<String>()
        let chats = notchChatSessions.filter { !Orchestrator.owns($0) && seen.insert($0.id).inserted }
        return OrchestratorState(
            mainProject: mainProject?.path, machines: machineRows, projects: projects, chats: chats, worktrees: trees,
            todos: todoRows, hosts: remoteHosts,
            profiles: Dictionary(uniqueKeysWithValues: usage.preferences.profiles.map { ($0.key.rawValue, $0.value) }))
    }

    private static func connectionText(_ connection: HomeMachine.Connection) -> String {
        switch connection {
        case .local: "this Mac"
        case .online: "online"
        case .stale: "not answering lately"
        case .offline: "offline"
        case .connecting: "connecting"
        case .paused: "paused in Burro"
        }
    }

    func askOrchestrator(_ text: String) { orchestrator.send(text) }
    func showOrchestrator() { page = .orchestrator }
}
