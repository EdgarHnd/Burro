// Explain each assessment and expose the exact agents, Git evidence, and local processes.
import SwiftUI
import BurroCore

struct WorktreeDetailView: View {
    var store: AppStore
    var tree: Worktree
    @State private var showHistory = false
    @State private var comparisonBranches: [String] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: Layout.gap) {
                    HStack {
                        Image(systemName: "arrow.triangle.branch").font(.title2).foregroundStyle(.secondary)
                        Spacer()
                        Button { store.protect(tree) } label: {
                            Image(systemName: tree.protectedByUser ? "lock.fill" : "lock.open")
                        }.buttonStyle(.borderless).help(tree.protectedByUser ? "Remove your protection" : "Protect this worktree")
                            .accessibilityLabel(tree.protectedByUser ? "Remove protection" : "Protect worktree")
                    }
                    Text(URL(fileURLWithPath: tree.path).lastPathComponent).font(AppAppearance.sectionTitle).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Label("Branch: " + tree.branch, systemImage: "arrow.triangle.branch").font(.callout).textSelection(.enabled)
                    Text(tree.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Finder", systemImage: "folder") { store.reveal(tree) }
                        Button("Terminal", systemImage: "terminal") { store.openTerminal(tree) }
                        Button { store.copyPath(tree) } label: { Image(systemName: "doc.on.doc") }.help("Copy path")
                    }.controlSize(.small).disabled(tree.isMissing)
                }
                Divider()
                VStack(alignment: .leading, spacing: Layout.gap) {
                    let eligibility = store.cleanupEligibility(tree)
                    HStack { sectionLabel("CLEANUP"); Spacer(); CleanupBadge(status: eligibility.status) }
                    ForEach(eligibility.reasons, id: \.self) { reason in
                        Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if eligibility.managedByCodex {
                        Text("Use Archive in Codex for this checkout; it preserves a recoverable snapshot.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(eligibility.allowed ? "Move to Trash…" : "Show blockers…", systemImage: "trash") { store.reviewCleanup([tree]) }
                        .disabled(store.cleaningWorktree)

                }
                Divider()
                agents
                Divider()
                VStack(alignment: .leading, spacing: Layout.gap) {
                    sectionLabel("CODE & COMMITS")
                    Text(tree.facts.integrationSummary).font(.callout).textSelection(.enabled)
                    if let branch = tree.facts.retainedBranchName {
                        fact("Commits retained on", branch)
                    }
                    Text("Removing the folder keeps the branch. Whether its code has landed is shown separately above.")
                        .font(.caption).foregroundStyle(.secondary)
                    fact("Tracked changes", "\(tree.facts.changed)")
                    fact("Untracked", "\(tree.facts.untracked)")
                    if !(tree.facts.changedPaths ?? []).isEmpty { paths("Modified or staged files", tree.facts.changedPaths ?? [], total: tree.facts.changed) }
                    if !(tree.facts.untrackedPaths ?? []).isEmpty { paths("Untracked files", tree.facts.untrackedPaths ?? [], total: tree.facts.untracked) }
                    fact("Ignored", "\(tree.facts.ignoredCount)")
                    fact("Unpushed", tree.facts.unpushed.map(String.init) ?? "Unknown")
                    Picker("Compare with", selection: Binding(
                        get: { store.baseOverrides[tree.repositoryPath] ?? "" },
                        set: { store.baseOverrides[tree.repositoryPath] = $0; Task { await store.refresh() } })) {
                        Text("Automatic (\(tree.facts.base ?? "unavailable"))").tag("")
                        ForEach(Array(Set(comparisonBranches + [store.baseOverrides[tree.repositoryPath]].compactMap { $0 }).sorted()), id: \.self) { Text($0).tag($0) }
                    }.controlSize(.small).disabled(store.scanning || store.cleaningWorktree)
                    Text("Applies to this repository. Uses local Git refs; choose your integration branch, such as origin/staging.")
                        .font(.caption2).foregroundStyle(.secondary)
                    fact("HEAD", String(tree.head.prefix(9)))
                    if let commit = tree.facts.lastCommit { HStack { Text("Last commit"); Spacer(); Text(commit, style: .relative) }.font(.caption).foregroundStyle(.secondary) }
                    if !tree.facts.ignored.isEmpty {
                        DisclosureGroup("Ignored data") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(tree.facts.ignored, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                                if tree.facts.ignoredCount > tree.facts.ignored.count { Text("More entries not shown").font(.caption).foregroundStyle(.tertiary) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !tree.processes.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: Layout.gap) {
                        sectionLabel("LOCAL PROCESSES")
                        ForEach(tree.processes, id: \.pid) { process in fact(process.name, "PID \(process.pid)") }
                    }
                }
                Text("Cleanup rechecks activity and Git evidence, then preserves the folder in Trash and keeps the branch. Emptying Trash is permanent. Git refs are not fetched automatically.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }.padding(Layout.inset)
        }.background(AppAppearance.surface).frame(minWidth: 280, idealWidth: Layout.inspector)
        .task(id: tree.repositoryPath) {
            let branches = await store.comparisonBranches(tree)
            if !Task.isCancelled { comparisonBranches = branches }
        }
        .onChange(of: tree.id) { _, _ in showHistory = false }
    }
    private var agents: some View {
        let live = tree.agents.filter { $0.state.keepsWorktree }
        let historical = tree.agents.filter { !$0.state.keepsWorktree }
        return VStack(alignment: .leading, spacing: Layout.gap) {
            HStack { sectionLabel("AGENTS"); Spacer(); Text("\(live.count) open").font(.caption).foregroundStyle(.secondary) }
            if live.isEmpty { Text("No live agent sessions detected").font(.callout).foregroundStyle(.secondary) }
            ForEach(live) { session in AgentRow(session: session) }
            if !historical.isEmpty {
                DisclosureGroup("Recent history (\(historical.count))", isExpanded: $showHistory) {
                    VStack(alignment: .leading, spacing: Layout.gap) {
                        ForEach(historical.prefix(10)) { session in AgentRow(session: session) }
                        if historical.count > 10 { Text("Showing 10 most recent chats").font(.caption2).foregroundStyle(.tertiary) }
                    }.padding(.top, Layout.gap)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func paths(_ label: String, _ entries: [String], total: Int) -> some View {
        DisclosureGroup(label) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entries, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                if total > entries.count { Text("More entries not shown").font(.caption).foregroundStyle(.tertiary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        }.font(.caption).foregroundStyle(.secondary)
    }
    private func sectionLabel(_ label: String) -> some View { Text(label).font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(.secondary) }
    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).textSelection(.enabled).multilineTextAlignment(.trailing) }.font(.caption)
    }
}
struct AgentRow: View {
    let session: AgentSession
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                AgentAvatar(session: session, size: 18)
                Text(session.provider.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.primary)
                if session.pinned { Image(systemName: "pin.fill").font(.caption2) }
                Spacer()
                Text(session.state.rawValue).font(.caption2).foregroundStyle(session.state.color)
            }
            Text(session.title).font(.callout).lineLimit(2).foregroundStyle(.primary).help(session.title)
            HStack {
                Text(session.updatedAt, style: .relative)
                if let pid = session.pid { Text("· PID \(pid)") }
            }.font(.caption2).foregroundStyle(.tertiary)
        }.help(session.evidence)
    }
}
