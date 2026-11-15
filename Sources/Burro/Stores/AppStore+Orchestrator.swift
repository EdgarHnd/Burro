// What the orchestrator sees: Burro's current picture of machines, chats, projects, worktrees,
// to-dos (with ids), usage windows, the main project's cached Shipped days and week, and notes only
// when you allow it, flattened for the tool server. Built on demand, in memory, from state Burro
// holds; nothing from tracked activity is ever included. Also sends a proposal the orchestrator
// made, only when you click Send on its card: a reply goes through the same path as the Chats
// composer, a new chat through the same launch as New chat, and a new chat on another machine
// through the remote launch backend (folder validated there first), after which that machine is
// checked straight away. Each remote machine's remembered folders (paths only) go in the snapshot. To-dos it adds or completes are applied
// here through the to-do store (tagged "orchestrator"); Undo reverses only a change that happened,
// on the to-do it touched, found by id.
import Foundation
import BurroCore

extension AppStore {
    func orchestratorState() -> OrchestratorState {
        let summary = homeSummary
        let machineRows = summary.machines.map { machine in
            let facts = machines.facts[machine.id]
            // Another machine's remembered folders (paths only), so a proposed chat can name one.
            let host = remoteHosts.first { $0.id.uuidString == machine.id && $0.enabled }
            let folders = host.map(OrchestratorFolderCache.folders)
            return OrchestratorState.Machine(
                id: machine.id, name: machine.name, connection: Self.connectionText(machine.connection), lastSeen: machine.lastSeen,
                os: facts?.os, versions: Dictionary(uniqueKeysWithValues: (facts?.versions ?? [:]).map { ($0.key.rawValue, $0.value) }),
                folders: folders?.isEmpty == false ? folders : nil)
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
            OrchestratorState.Todo(text: $0.text, done: $0.done, day: $0.day, project: $0.project, id: $0.id)
        }
        var seen = Set<String>()
        let chats = notchChatSessions.filter { !Orchestrator.owns($0) && seen.insert($0.id).inserted }
        return OrchestratorState(
            mainProject: mainProject?.path, machines: machineRows, projects: projects, chats: chats, worktrees: trees,
            todos: todoRows, hosts: remoteHosts,
            profiles: Dictionary(uniqueKeysWithValues: usage.preferences.profiles.map { ($0.key.rawValue, $0.value) }),
            usage: orchestratorUsageRows(), shipped: orchestratorShippedRows(), notesAccess: orchestrator.notesAccess,
            notes: orchestrator.notesAccess ? orchestratorNoteRows() : nil)
    }

    private func orchestratorUsageRows() -> [OrchestratorState.UsageRow] {
        usage.snapshot.providers.flatMap { provider in
            provider.windows.map {
                OrchestratorState.UsageRow(provider: provider.id.title, window: $0.title, remainingPercent: $0.remainingPercent,
                                           resetsAt: $0.resetsAt, model: $0.model)
            }
        }
    }

    /// The last seven days and this week, from what the Shipped store has cached; never fetched here.
    private func orchestratorShippedRows(now: Date = Date(), calendar: Calendar = .current) -> [OrchestratorState.ShippedRow] {
        let repository = shipped.repository
        func row(_ day: Date) -> OrchestratorState.ShippedRow? {
            let summary = shipped.daySummary(day), digest = shipped.dayDigest(day)
            guard summary != nil || digest != nil else { return nil }
            return OrchestratorState.ShippedRow(
                period: "day", date: TodoDay.key(day, calendar: calendar), repository: repository, summary: summary,
                merged: digest?.merged.map { "#\($0.number) \($0.title) (\($0.author))" } ?? [],
                production: digest?.production.map { "\($0.title): \($0.status)" } ?? [], inProgress: digest?.inProgress.count ?? 0)
        }
        let today = calendar.startOfDay(for: now)
        var rows = (0..<7).compactMap { calendar.date(byAdding: .day, value: -$0, to: today).flatMap(row) }
        let week = ShippedPeriod.containing(today, .week, calendar: calendar)
        let days = rows.filter { $0.date >= TodoDay.key(week.start, calendar: calendar) }
        let summary = shipped.period(week, through: now)?.summary?.text
        if summary != nil || !days.isEmpty {
            rows.append(OrchestratorState.ShippedRow(period: "week", date: TodoDay.key(week.start, calendar: calendar), repository: repository,
                                                     summary: summary, merged: days.flatMap(\.merged), production: days.flatMap(\.production),
                                                     inProgress: days.map(\.inProgress).max() ?? 0))
        }
        return rows
    }

    private func orchestratorNoteRows() -> [OrchestratorState.NoteRow] {
        notes.sorted.prefix(50).map {
            OrchestratorState.NoteRow(title: $0.title.isEmpty ? "Untitled" : $0.title, text: String($0.content.prefix(4000)), updatedAt: $0.updatedAt)
        }
    }

    /// Applies a to-do change the orchestrator asked for; returns why not, or nil. Records on the
    /// action whether the list changed and which to-do it touched, so Undo reverses only that.
    func applyOrchestratorTodo(_ action: OrchestratorAction) -> String? {
        switch action.kind {
        case .addTodo:
            guard let id = action.todoID, id.hasPrefix(TodoLedger.localPrefix) else { return "This to-do has no id." }
            todos.add(action.text, project: action.project, clientId: String(id.dropFirst(TodoLedger.localPrefix.count)),
                      source: OrchestratorAction.todoSource)
            let added = todos.item(id: id) != nil
            try? orchestrator.actionStore.recordLocal(action.id, changed: added, todoID: id)
            return added ? nil : "Burro couldn't add that to-do."
        case .completeTodo:
            guard let id = action.todoID, let item = todos.item(id: id) else { return "That to-do isn't on the list any more." }
            if !item.done { todos.toggle(item) }
            try? orchestrator.actionStore.recordLocal(action.id, changed: !item.done, todoID: item.id)
            return nil
        default:
            return "Not a to-do change."
        }
    }

    /// Reverses one, only when applying changed something: removes the to-do it added, or reopens
    /// the one it completed. Found by id alone, never by text.
    func undoOrchestratorTodo(_ action: OrchestratorAction) -> String? {
        guard let id = action.undoTarget else { return nil }
        guard let item = todos.item(id: id) else { return "That to-do isn't on the list any more." }
        switch action.kind {
        case .addTodo: todos.remove(item)
        case .completeTodo: if item.done { todos.toggle(item) }
        default: return "Not a to-do change."
        }
        return nil
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

    /// The live chat a reply proposal targets, and its machine.
    func orchestratorTarget(_ action: OrchestratorAction) -> (session: AgentSession, host: RemoteHost?)? {
        guard action.kind == .reply, let id = action.chatID?.lowercased() else { return nil }
        guard let session = notchChatSessions.first(where: { $0.id.lowercased() == id }) else { return nil }
        return (session, remoteHosts.first { $0.id == session.remote?.hostID })
    }

    /// Sends one proposal, with the text as edited on its card. Only called from its Send button.
    func sendOrchestratorAction(_ action: OrchestratorAction, text: String) async {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, orchestrator.beginSending(action.id) else { return }
        let outcome: Result<(message: String, chatID: String?), Error>
        switch action.kind {
        case .reply:
            if let (session, host) = orchestratorTarget(action) {
                let request = ReplyRequest(text: message)
                // The card's Send is the owner's click for this reply: an idle Claude background
                // session is stopped and continued with it, as from the composer.
                let sent = await Task.detached(priority: .userInitiated) {
                    Result { try ChatReply.send(request, to: session, host: host, stopIdleBackground: true) }
                }.value
                outcome = sent.map { (message: $0, chatID: nil) }
            } else {
                outcome = .failure(LaunchError.failed("Burro can't see that chat right now, so it can't send the reply."))
            }
        case .start:
            guard let provider = action.provider, let folder = action.folder else {
                outcome = .failure(LaunchError.failed("This proposal is missing its agent or folder."))
                break
            }
            let request = LaunchRequest(provider: provider, prompt: message, folder: folder, model: action.model, effort: action.effort,
                                        access: action.launchAccess)
            if action.isRemoteStart {
                outcome = await startOrchestratorChat(request, on: action)
                break
            }
            do {
                let result = try await startChat(request, openWhenStarted: false)
                let id = (provider == .codex ? "codex:" : "claude:") + result.sessionID.lowercased()
                outcome = .success((message: "Started \(provider.title) in \(URL(fileURLWithPath: folder).lastPathComponent).", chatID: id))
            } catch {
                outcome = .failure(error)
            }
        case .addTodo, .completeTodo:
            // Applied at once with Undo, never sent (beginSending refuses them).
            outcome = .failure(LaunchError.failed("To-do changes aren't sent."))
        }
        orchestrator.finishSending(action.id, text: message, outcome: outcome)
    }

    /// A proposed chat on another machine: validates the folder there, starts it through the remote
    /// launch backend off the main thread, then has that machine checked straight away.
    private func startOrchestratorChat(_ request: LaunchRequest, on action: OrchestratorAction) async -> Result<(message: String, chatID: String?), Error> {
        guard let id = action.host, let host = remoteHosts.first(where: { $0.id == id }), host.enabled else {
            return .failure(LaunchError.failed("\(action.machine ?? "That machine") isn't set up in Burro any more."))
        }
        let started = await Task.detached(priority: .userInitiated) { () -> Result<RemoteLaunchResult, Error> in
            Result {
                var request = request
                if request.provider == .claude {
                    request.folder = try RemoteLaunch.validate(host: host, path: request.folder).path
                    return try RemoteLaunch.startClaude(request, host: host)
                }
                return try RemoteLaunch.startCodex(request, host: host)
            }
        }.value
        requestRemoteCheck(host.id)
        return started.map { result in
            (message: "Started \(request.provider.title) in \(URL(fileURLWithPath: result.launch.folder).lastPathComponent) on \(host.name).",
             chatID: result.chatID)
        }
    }

    func askOrchestrator(_ text: String) { orchestrator.send(text) }
    func showOrchestrator() { page = .orchestrator }
}

/// Each machine's offered folders, read from its cache file at most every five minutes (the
/// snapshot is rebuilt every few seconds during a turn, and that file also holds its chats).
@MainActor private enum OrchestratorFolderCache {
    static var entries: [UUID: (at: Date, folders: [String])] = [:]
    static func folders(_ host: RemoteHost) -> [String] {
        let now = Date()
        if let entry = entries[host.id], now.timeIntervalSince(entry.at) < 300 { return entry.folders }
        let folders = OrchestratorMachines.offered(RemoteLaunch.cachedFolders(host: host))
        entries[host.id] = (now, folders)
        return folders
    }
}
