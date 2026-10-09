// App-wide scan lifecycle and local preferences; monitoring never writes to tracked repositories.
import AppKit
import Foundation
import Observation
import BurroCore

@MainActor @Observable final class AppStore {
    var snapshot = ScanSnapshot.empty
    var scanning = false
    var didScan = false
    var cleanupTarget: CleanupRequest?
    var cleaningWorktree = false
    var cleanupDetailsPresented = false
    let cleanupBatch: CleanupBatchStore
    typealias Scan = @Sendable (ScanConfiguration) async -> ScanSnapshot
    @ObservationIgnored private let scan: Scan
    private var scanGeneration = 0
    var scanConfiguration: ScanConfiguration {
        ScanConfiguration(repositories: repositories, discover: discover,
            protectedPaths: protectedPaths, baseOverrides: baseOverrides)
    }
    func cleanupEligibility(_ tree: Worktree) -> CleanupEligibility {
        WorktreeCleanup.eligibility(tree, home: scanConfiguration.home, warnings: snapshot.warnings, registeredPaths: snapshot.worktrees.map(\.path))
    }
    func reviewCleanup(_ trees: [Worktree]) {
        guard !cleaningWorktree, !trees.isEmpty else { return }
        cleanupTarget = CleanupRequest(trees: trees)
    }
    func cleanupBlocker(_ tree: Worktree) -> String? {
        guard let current = availableWorktrees.first(where: { $0.id == tree.id }),
              current.head == tree.head, current.branch == tree.branch,
              current.repositoryPath == tree.repositoryPath, current.facts.base == tree.facts.base else {
            return "This checkout changed. Select it again to review the latest state."
        }
        let eligibility = cleanupEligibility(current)
        return eligibility.allowed ? nil : eligibility.reasons.joined(separator: "\n")
    }
    @discardableResult func confirmCleanup(_ request: CleanupRequest) -> Task<Void, Never>? {
        guard !cleaningWorktree else { return nil }
        let trees = request.trees.filter { cleanupBlocker($0) == nil }
        guard cleanupBatch.begin(trees) else { return nil }
        cleaningWorktree = true; cleanupTarget = nil
        scanGeneration += 1; scanning = false // Discard any older scan before hiding rows.
        worktreeSelection.subtract(cleanupBatch.hiddenPaths)
        let configuration = scanConfiguration
        return Task {
            await cleanupBatch.run(configuration: configuration)
            await refresh(afterCleanup: true)
            cleanupBatch.settle()
            cleaningWorktree = false
        }
    }
    var availableWorktrees: [Worktree] { snapshot.worktrees.filter { !cleanupBatch.hiddenPaths.contains($0.id) } }
    var selectedWorktrees: [Worktree] { visibleWorktrees.filter { worktreeSelection.contains($0.id) } }
    var readyWorktrees: [Worktree] { visibleWorktrees.filter { cleanupEligibility($0).allowed } }
    var selectedReadyCount: Int { selectedWorktrees.filter { cleanupEligibility($0).allowed }.count }
    func selectReadyWorktrees() { worktreeSelection = Set(readyWorktrees.map(\.id)) }
    func reconcileSelection(selectFirst: Bool = false) {
        worktreeSelection.formIntersection(Set(visibleWorktrees.map(\.id)))
        if selectFirst && worktreeSelection.isEmpty { selection = visibleWorktrees.first?.id }
    }
    func comparisonBranches(_ tree: Worktree) async -> [String] {
        await Task.detached(priority: .utility) {
            let result = CommandRunner().git(tree.repositoryPath, ["for-each-ref", "--format=%(refname:short)", "refs/remotes", "refs/heads"])
            guard result.succeeded else { return [] }
            return result.output.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }.sorted()
        }.value
    }
    var agentActivity = AgentActivitySnapshot.empty
    var usage: UsageStore
    var providerUsage: ProviderUsageSnapshot { usage.snapshot }
    var checkingUsage: Bool { usage.checking }
    var usageEnabled: Bool { get { usage.enabled } set { usage.enabled = newValue } }
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
    var worktreeSelection: Set<String> = []
    var selection: String? {
        get { worktreeSelection.count == 1 ? worktreeSelection.first : nil }
        set { worktreeSelection = Set([newValue].compactMap { $0 }) }
    }
    var filter: WorktreeFilter = .all
    var repositories: [String] { didSet { save() } }
    var protectedPaths: Set<String> { didSet { save() } }
    var discover: Bool { didSet { save() } }
    var baseOverrides: [String: String] { didSet { save() } }
    private var monitorTask: Task<Void, Never>?
    private var remoteMonitorTask: Task<Void, Never>?
    private var agentRefresh: AgentRefreshCoordinator?
    private var agentWatcher: AgentFileWatcher?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, cleanupBatch: CleanupBatchStore? = nil,
         scan: @escaping Scan = { await Scanner().scan($0) }) {
        self.defaults = defaults
        self.scan = scan
        self.cleanupBatch = cleanupBatch ?? CleanupBatchStore()
        usage = UsageStore(defaults: defaults)
        remoteHosts = defaults.data(forKey: "remoteHosts").flatMap { try? JSONDecoder().decode([RemoteHost].self, from: $0) } ?? []
        PreferencesMigration.migrate(into: defaults, legacy: defaults.persistentDomain(forName: "local.grove.worktrees") ?? [:])
        notchEnabled = defaults.object(forKey: "notchEnabled") as? Bool ?? true
        notchPreferMainDisplay = defaults.bool(forKey: "notchPreferMainDisplay")
        repositories = defaults.stringArray(forKey: "repositories") ?? []
        protectedPaths = Set(defaults.stringArray(forKey: "protectedPaths") ?? [])
        discover = defaults.object(forKey: "discover") as? Bool ?? true
        baseOverrides = defaults.dictionary(forKey: "baseOverrides") as? [String: String] ?? [:]
    }
    func matches(_ filter: WorktreeFilter, tree: Worktree) -> Bool {
        if filter == .candidates { return cleanupEligibility(tree).allowed }
        if filter == .protected { return cleanupEligibility(tree).status == .protected }
        return filter.matches(tree)
    }
    var visibleWorktrees: [Worktree] {
        let trees = availableWorktrees.filter { tree in
            matches(filter, tree: tree) && (search.isEmpty || [tree.branch, tree.repository, tree.path] .contains { $0.localizedCaseInsensitiveContains(search) } || tree.agents.contains { $0.title.localizedCaseInsensitiveContains(search) })
        }
        if filter == .cleanup {
            return trees.sorted { a, b in
                let left = cleanupEligibility(a).allowed, right = cleanupEligibility(b).allowed
                if left != right { return left }
                return a.path.localizedStandardCompare(b.path) == .orderedAscending
            }
        }
        return trees
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
    var selected: Worktree? { selectedWorktrees.count == 1 ? selectedWorktrees.first : nil }
    var activeAgents: [AgentSession] { agentActivity.sessions.filter { $0.state == .working } }
    var repositoriesFound: [(path: String, name: String)] {
        Dictionary(grouping: snapshot.worktrees, by: \.repositoryPath).map { (path: $0.key, name: $0.value.first?.repository ?? $0.key) }.sorted { $0.name < $1.name }
    }
    func start() {
        guard monitorTask == nil else { return }
        // Owned by the app store so closing the window keeps the menu-bar monitor alive.
        usage.start()
        let coordinator = AgentRefreshCoordinator { [weak self] in
            guard let self else { return 15 }
            await self.refreshAgents()
            return AgentRefreshCoordinator.interval(states: self.localActivity.sessions.map(\.state),
                warnings: !self.localActivity.warnings.isEmpty, watching: self.agentWatcher?.isRunning == true)
        }
        agentRefresh = coordinator
        agentWatcher = AgentFileWatcher(paths: AgentFileWatcher.paths(home: FileManager.default.homeDirectoryForCurrentUser.path)) { [weak coordinator] in
            Task { @MainActor in coordinator?.changed() }
        }
        coordinator.start()
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
    func stop() {
        usage.stop()
        agentWatcher?.stop(); agentWatcher = nil
        agentRefresh?.stop(); agentRefresh = nil
        monitorTask?.cancel(); monitorTask = nil
        remoteMonitorTask?.cancel(); remoteMonitorTask = nil
    }
    func refreshUsage(force: Bool = false, allowClaudePrompt: Bool = false) async {
        await usage.refresh(force: force, allowClaudePrompt: allowClaudePrompt)
    }
    func connectClaudeUsage() { usage.connectClaude() }
    func refreshAgents() async {
        guard !checkingAgents else { return }
        checkingAgents = true
        let result = await Task.detached(priority: .utility) { AgentMonitor().sample() }.value
        localActivity = result; checkingAgents = false; didCheckAgents = true
        rebuildAgentActivity()
    }
    func workspaceLabel(for session: AgentSession) -> String {
        if let tree = worktree(for: session) {
            return "Worktree: \(URL(fileURLWithPath: tree.path).lastPathComponent) · Branch: \(tree.branch)"
        }
        return "\(session.remote?.hostName ?? "This Mac") · Folder: \(URL(fileURLWithPath: session.cwd).lastPathComponent)"
    }
    func workspacePath(for session: AgentSession) -> String {
        worktree(for: session)?.path ?? session.cwd
    }
    func workspaceBranch(for session: AgentSession) -> String? {
        worktree(for: session)?.branch
    }
    func workspaceDelivery(for session: AgentSession) -> String? {
        guard let tree = worktree(for: session) else { return nil }
        let facts = tree.facts
        if !facts.errors.isEmpty || facts.merged == nil || facts.unpushed == nil { return "Git unknown" }
        if facts.operationInProgress { return "Git operation" }
        if facts.changed > 0 || facts.untracked > 0 { return "Uncommitted" }
        if let count = facts.unpushed, count > 0 { return "Unpushed" }
        return facts.integrationSummary
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
    // Keep browsing history separate from the live activity/safety inventory.
    var notchChatSessions: [AgentSession] {
        var sessions = agentActivity.sessions.filter { $0.remote == nil }
        for host in remoteHosts where host.enabled {
            guard var snapshot = remoteSnapshots[host.id] else { continue }
            snapshot.host = host
            sessions += snapshot.displaySessions().map { localActivity.readState.applying(to: $0) }
        }
        return sessions
    }
    var selectedRemote: AgentSession? { notchChatSessions.first { $0.remote != nil && $0.id == remoteSelection } }
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
        var sessions = localActivity.sessions
        var warnings = localActivity.warnings
        for host in remoteHosts where host.enabled {
            guard var result = remoteSnapshots[host.id] else { continue }
            result.host = host
            result.sessions = result.sessions.filter { $0.state != .inactive || localActivity.readState.applying(to: $0).isDone }
            sessions += result.displaySessions().map { localActivity.readState.applying(to: $0) }
            if result.state == .offline { warnings.append("\(host.name): connection unavailable") }
            warnings += result.warnings.map { "\(host.name): \($0)" }
        }
        agentActivity = AgentActivitySnapshot(sessions: sessions, warnings: warnings, sampledAt: localActivity.sampledAt)
    }
    func refresh(afterCleanup: Bool = false) async {
        guard !scanning && (!cleaningWorktree || afterCleanup) else { return }
        scanning = true
        let generation = scanGeneration
        let config = ScanConfiguration(repositories: repositories, discover: discover, protectedPaths: protectedPaths, baseOverrides: baseOverrides)
        let scan = self.scan
        var result = await Task.detached(priority: .utility) { await scan(config) }.value
        guard generation == scanGeneration else { return }
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
        snapshot = result; scanning = false; didScan = true
        if afterCleanup { cleanupBatch.settle() }
        reconcileSelection(selectFirst: !afterCleanup && worktreeSelection.isEmpty)
    }
    func protect(_ tree: Worktree) {
        guard !cleaningWorktree else { return }
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
