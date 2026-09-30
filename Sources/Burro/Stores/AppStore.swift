// App-wide scan lifecycle and local preferences; monitoring never writes to tracked repositories.
import AppKit
import Foundation
import Observation
import BurroCore

@MainActor @Observable final class AppStore {
    var snapshot = ScanSnapshot.empty
    var scanning = false
    var deletingWorktreeID: String?
    var deletionPhase = "Checking…"
    private var removedWorktreePaths: Set<String> = []
    var didScan = false
    var agentActivity = AgentActivitySnapshot.empty
    var remoteHosts: [RemoteHost] { didSet { save(); rebuildAgentActivity() } }
    var remoteSnapshots: [UUID: RemoteHostSnapshot] = [:]
    var checkingRemotes = false
    var remoteSelection: String?
    private var localActivity = AgentActivitySnapshot.empty
    var checkingAgents = false
    var didCheckAgents = false
    var notchEnabled: Bool { didSet { save(); onNotchPreferenceChange?() } }
    var notchPreferMainDisplay: Bool { didSet { save(); onNotchPreferenceChange?() } }
    @ObservationIgnored var onNotchPreferenceChange: (() -> Void)?
    var search = ""
    var selection: String?
    var filter: WorktreeFilter = .all
    var repositories: [String] { didSet { save() } }
    var protectedPaths: Set<String> { didSet { save() } }
    var discover: Bool { didSet { save() } }
    var baseOverrides: [String: String] { didSet { save() } }
    private var monitorTask: Task<Void, Never>?
    private var remoteMonitorTask: Task<Void, Never>?
    private var agentMonitorTask: Task<Void, Never>?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        remoteHosts = defaults.data(forKey: "remoteHosts").flatMap { try? JSONDecoder().decode([RemoteHost].self, from: $0) } ?? []
        PreferencesMigration.migrate(into: defaults, legacy: defaults.persistentDomain(forName: "local.grove.worktrees") ?? [:])
        notchEnabled = defaults.object(forKey: "notchEnabled") as? Bool ?? true
        notchPreferMainDisplay = defaults.bool(forKey: "notchPreferMainDisplay")
        repositories = defaults.stringArray(forKey: "repositories") ?? []
        protectedPaths = Set(defaults.stringArray(forKey: "protectedPaths") ?? [])
        discover = defaults.object(forKey: "discover") as? Bool ?? true
        baseOverrides = defaults.dictionary(forKey: "baseOverrides") as? [String: String] ?? [:]
    }
    var visibleWorktrees: [Worktree] {
        snapshot.worktrees.filter { tree in
            filter.matches(tree) && (search.isEmpty || [tree.branch, tree.repository, tree.path] .contains { $0.localizedCaseInsensitiveContains(search) } || tree.agents.contains { $0.title.localizedCaseInsensitiveContains(search) })
        }
    }
    var notchNotices: [NotchNotice] {
        var notices: [NotchNotice] = []
        if !localActivity.warnings.isEmpty {
            notices.append(NotchNotice(id: "local", source: "This Mac", summary: "This Mac: status limited",
                messages: Array(Set(localActivity.warnings)).sorted(), checkedAt: localActivity.sampledAt))
        }
        for host in remoteHosts where host.enabled {
            guard let result = remoteSnapshots[host.id] else {
                notices.append(NotchNotice(id: host.id.uuidString, source: host.name, summary: "\(host.name): connecting…",
                    messages: ["Waiting for the first connection."], checkedAt: nil))
                continue
            }
            let stale = result.sampledAt.map { Date().timeIntervalSince($0) > 30 } ?? true
            if result.state == .offline || stale {
                notices.append(NotchNotice(id: host.id.uuidString, source: host.name, summary: "\(host.name): status unavailable",
                    messages: [result.error ?? "The last sample has expired. Retrying automatically."],
                    checkedAt: result.sampledAt, connectionIssue: true))
            } else if !result.warnings.isEmpty {
                let historyOnly = result.warnings.allSatisfy { $0.hasPrefix("Codex history exceeds the inspection limit") }
                notices.append(NotchNotice(id: host.id.uuidString, source: host.name,
                    summary: "\(host.name): \(historyOnly ? "history limited" : "status limited")",
                    messages: Array(Set(result.warnings)).sorted(), checkedAt: result.sampledAt))
            }
        }
        return notices.sorted { $0.connectionIssue && !$1.connectionIssue }
    }
    var selected: Worktree? { snapshot.worktrees.first { $0.id == selection } }
    var activeAgents: [AgentSession] { agentActivity.sessions.filter { $0.state == .working } }
    var repositoriesFound: [(path: String, name: String)] {
        Dictionary(grouping: snapshot.worktrees, by: \.repositoryPath).map { (path: $0.key, name: $0.value.first?.repository ?? $0.key) }.sorted { $0.name < $1.name }
    }
    func start() {
        guard monitorTask == nil else { return }
        // Owned by the app store so closing the window keeps the menu-bar monitor alive.
        agentMonitorTask = Task {
            while !Task.isCancelled {
                await refreshAgents()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        remoteMonitorTask = Task {
            while !Task.isCancelled {
                await refreshRemotes()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        monitorTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
    func refreshAgents() async {
        guard !checkingAgents else { return }
        checkingAgents = true
        let result = await Task.detached(priority: .utility) { AgentMonitor().sample() }.value
        localActivity = result; checkingAgents = false; didCheckAgents = true
        rebuildAgentActivity()
    }
    func workspacePath(for session: AgentSession) -> String {
        if session.remote == nil { return worktree(for: session)?.path ?? session.cwd }
        // Remote paths must never be resolved against this Mac's filesystem.
        return ((session.checkoutPath ?? session.cwd) as NSString).standardizingPath
    }
    func projectPath(for session: AgentSession) -> String {
        if let tree = worktree(for: session) { return tree.repositoryPath }
        return session.repositoryPath ?? workspacePath(for: session)
    }
    func workspaceTitle(for session: AgentSession) -> String {
        if let tree = worktree(for: session) { return tree.branch }
        return session.checkoutBranch ?? URL(fileURLWithPath: workspacePath(for: session)).lastPathComponent
    }
    func workspaceLabel(for session: AgentSession) -> String {
        let path = workspacePath(for: session)
        let folder = URL(fileURLWithPath: path).lastPathComponent
        let host = session.remote?.hostName ?? "This Mac"
        if let tree = worktree(for: session) { return "\(host) · \(folder) · \(tree.branch)" }
        return "\(host) · \(folder)" + (session.checkoutBranch.map { " · " + $0 } ?? "")
    }
    func selectAgent(_ session: AgentSession) {
        search = ""
        if session.remote != nil { filter = .remote; remoteSelection = session.id; return }
        filter = .all
        selection = worktree(for: session)?.path
    }
    private func worktree(for session: AgentSession) -> Worktree? {
        guard session.remote == nil else { return nil }
        let roots = snapshot.worktrees.map(\.path)
        let attached = session.attachedPaths.compactMap { Paths.owner(of: $0, in: roots) }.first
        let owner = attached ?? Paths.owner(of: session.cwd, in: roots)
        return snapshot.worktrees.first { $0.path == owner }
    }
    var remoteSessions: [AgentSession] { agentActivity.visibleSessions(includeIdle: true).filter { $0.remote != nil } }
    var selectedRemote: AgentSession? { remoteSessions.first { $0.id == remoteSelection } }
    func connection(for host: RemoteHost) -> RemoteHostSnapshot {
        guard host.enabled else { return RemoteHostSnapshot(host: host, state: .disabled) }
        return remoteSnapshots[host.id] ?? RemoteHostSnapshot(host: host)
    }
    func saveRemoteHost(_ host: RemoteHost) {
        if let i = remoteHosts.firstIndex(where: { $0.id == host.id }) {
            if remoteHosts[i].destination != host.destination || remoteHosts[i].port != host.port { remoteSnapshots[host.id] = nil }
            remoteHosts[i] = host
        } else { remoteHosts.append(host) }
        Task { await refreshRemotes() }
    }
    func removeRemoteHost(_ id: UUID) {
        remoteSnapshots[id] = nil
        remoteHosts.removeAll { $0.id == id }
    }
    func refreshRemotes() async {
        guard !checkingRemotes else { return }
        let hosts = remoteHosts.filter(\.enabled)
        guard !hosts.isEmpty else { rebuildAgentActivity(); return }
        checkingRemotes = true
        // Keep slow/offline hosts out of the local 3-second activity loop; cap parallel SSH processes.
        let results = await Task.detached(priority: .utility) {
            var values: [RemoteHostSnapshot] = []
            for offset in stride(from: 0, to: hosts.count, by: 4) {
                let batch = Array(hosts[offset..<min(offset + 4, hosts.count)])
                await withTaskGroup(of: RemoteHostSnapshot.self) { group in
                    for host in batch { group.addTask { RemoteAgentMonitor().sample(host) } }
                    for await value in group { values.append(value) }
                }
            }
            return values
        }.value
        for result in results {
            // A response for a removed/edited/paused host must not resurrect old data.
            guard remoteHosts.contains(result.host) else { continue }
            remoteSnapshots[result.host.id] = result.state == .offline
                ? RemoteHostSnapshot.mergeFailure(host: result.host, error: result.error ?? "Connection unavailable",
                    previous: remoteSnapshots[result.host.id], now: result.attemptedAt)
                : result
        }
        checkingRemotes = false
        rebuildAgentActivity()
    }
    private func rebuildAgentActivity() {
        var sessions = localActivity.sessions.map { source in
            var session = source
            if let tree = worktree(for: session) {
                session.deliveryStatus = DeliveryStatus.evaluate(tree.facts)
                session.checkoutPath = tree.path; session.checkoutBranch = tree.branch
                session.upstreamBehind = tree.facts.upstreamBehind
                session.workspaceDiff = tree.facts.workspaceDiff
            }
            return session
        }
        var warnings = localActivity.warnings
        for host in remoteHosts where host.enabled {
            guard var result = remoteSnapshots[host.id] else { continue }
            result.host = host
            result.sessions = result.sessions.filter { $0.state != .inactive || localActivity.readState.applying(to: $0).showsCompletion }
            sessions += result.displaySessions().map { localActivity.readState.applying(to: $0) }
            if result.state == .offline { warnings.append("\(host.name): connection unavailable") }
            warnings += result.warnings.map { "\(host.name): \($0)" }
        }
        agentActivity = AgentActivitySnapshot(sessions: sessions, warnings: warnings, sampledAt: localActivity.sampledAt)
    }
    func refresh() async {
        guard !scanning else { return }
        scanning = true
        let config = ScanConfiguration(repositories: repositories, discover: discover, protectedPaths: protectedPaths, baseOverrides: baseOverrides, refreshReferences: true)
        var result = await Task.detached(priority: .utility) { await Scanner().scan(config) }.value
        for i in result.worktrees.indices {
            let tree = result.worktrees[i]
            let protected = protectedPaths.contains(tree.path)
            if tree.protectedByUser != protected {
                result.worktrees[i].protectedByUser = protected
                result.worktrees[i].assessment = SafetyPolicy.assess(primary: tree.isPrimary, locked: tree.isLocked,
                    missing: tree.isMissing, prunable: tree.isPrunable, branch: tree.branch, facts: tree.facts,
                    agents: tree.agents, processes: tree.processes, protected: protected, coverageWarnings: result.warnings)
            }
        }
        result.worktrees.removeAll { removedWorktreePaths.contains($0.path) }
        snapshot = result; scanning = false; didScan = true
        rebuildAgentActivity()
        if selection == nil || !result.worktrees.contains(where: { $0.id == selection }) { selection = visibleWorktrees.first?.id }
    }
    func deleteMergedWorktree(_ item: NotchCleanup) async -> String? {
        guard item.id.hasPrefix("local:") else { return "Remote removal is not supported yet." }
        guard deletingWorktreeID == nil else { return "Another worktree deletion is already in progress." }
        guard let existing = snapshot.worktrees.first(where: { $0.path == item.path }) else { return "This worktree is no longer registered." }
        deletingWorktreeID = item.id; deletionPhase = "Checking…"
        defer { deletingWorktreeID = nil }
        var config = ScanConfiguration(repositories: [existing.repositoryPath], discover: false,
            protectedPaths: protectedPaths, baseOverrides: baseOverrides)
        config.onlyWorktree = item.path
        config.inspectionDeadline = Date().addingTimeInterval(20)
        let fresh = await Task.detached(priority: .userInitiated) { [config] in await Scanner().scan(config) }.value
        guard var tree = fresh.worktrees.first(where: { $0.path == item.path }) else {
            return "Could not finish checking this worktree. Please retry."
        }
        tree.protectedByUser = protectedPaths.contains(tree.path)
        if let index = snapshot.worktrees.firstIndex(where: { $0.path == item.path }) { snapshot.worktrees[index] = tree }
        deletionPhase = "Deleting…"
        let error = await Task.detached(priority: .userInitiated) { [tree] in WorktreeRemoval.remove(tree) }.value
        if error == nil {
            removedWorktreePaths.insert(item.path)
            snapshot.worktrees.removeAll { $0.path == item.path }
        }
        rebuildAgentActivity()
        return error
    }

    func protect(_ tree: Worktree) {
        if protectedPaths.contains(tree.path) { protectedPaths.remove(tree.path) } else { protectedPaths.insert(tree.path) }
        // Apply protection immediately, then rescan all other evidence.
        if let i = snapshot.worktrees.firstIndex(where: { $0.id == tree.id }) {
            snapshot.worktrees[i].protectedByUser = protectedPaths.contains(tree.path)
            if protectedPaths.contains(tree.path) { snapshot.worktrees[i].assessment = Assessment(level: .keep, reasons: ["Protected by you"] + tree.assessment.reasons) }
        }
        Task { await refresh() }
    }
    func addRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.message = "Choose a Git repository or one of its worktrees."
        panel.prompt = "Add repository"
        guard panel.runModal() == .OK else { return }
        repositories = Array(Set(repositories + panel.urls.map { Paths.canonical($0.path) })).sorted()
        Task { await refresh() }
    }
    func reveal(_ tree: Worktree) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: tree.path) }
    func openTerminal(_ tree: Worktree) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: tree.path)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
    func copyPath(_ tree: Worktree) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(tree.path, forType: .string) }
    private func save() {
        if let data = try? JSONEncoder().encode(remoteHosts) { defaults.set(data, forKey: "remoteHosts") }
        defaults.set(notchEnabled, forKey: "notchEnabled")
        defaults.set(notchPreferMainDisplay, forKey: "notchPreferMainDisplay")
        defaults.set(repositories, forKey: "repositories")
        defaults.set(Array(protectedPaths), forKey: "protectedPaths")
        defaults.set(discover, forKey: "discover")
        defaults.set(baseOverrides, forKey: "baseOverrides")
    }
}
