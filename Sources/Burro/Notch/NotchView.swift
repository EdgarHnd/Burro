// A compact attention queue keeps live status separate from stable pointer and keyboard targets.
import SwiftUI
import BurroCore

struct NotchView: View {
    var store: AppStore
    @Bindable var presentation: NotchPresentation
    var onToggle: () -> Void
    var onPin: () -> Void
    var onCollapse: () -> Void
    var onSelect: (AgentSession) -> Void
    var onInspect: (AgentSession) -> Void
    var onOpenDashboard: () -> Void
    var onContentChange: () -> Void
    var compact = false
    @State private var list = NotchListState()
    @State private var expandedGroups: Set<String> = []
    @State private var expandedWorkspaces: Set<String> = []
    @State private var hoveredWorkspace: String?
    @State private var showingHealth = false
    @State private var pendingDeletion: NotchCleanup?
    @State private var deletionError: String?

    private var activity: AgentActivitySnapshot { store.agentActivity }
    private var workspaces: [NotchWorkspace] {
        NotchWorkspace.grouped(list.groups) { store.workspacePath(for: $0) }
    }
    private var projects: [NotchProject] {
        NotchProject.grouped(workspaces) { store.projectPath(for: $0) }
    }
    private var summary: WorkspaceSummary {
        let cleanupIDs = Set(cleanup.map(\.id))
        return WorkspaceSummary(NotchWorkspace.grouped(NotchFeed(sessions: activity.sessions,
            includeIdle: presentation.includeIdle, codeOnly: true).groups) { store.workspacePath(for: $0) }.filter { !cleanupIDs.contains($0.id) })
    }
    private var cleanup: [NotchCleanup] {
        NotchCleanup.inventory(worktrees: store.snapshot.worktrees, sessions: activity.sessions)
    }
    private var unlistedCleanup: [NotchCleanup] {
        let visible = Set(workspaces.map(\.id))
        return cleanup.filter { !visible.contains($0.id) }
    }
    private var rowCount: Int {
        unlistedCleanup.count + projects.count + workspaces.reduce(0) { total, workspace in
            total + 1 + (expandedWorkspaces.contains(workspace.id)
                ? workspace.groups.reduce(0) { $0 + 1 + (expandedGroups.contains($1.id) ? $1.workers.count : 0) } : 0)
        }
    }

    var body: some View {
        Group {
            if compact {
                compactStatus.frame(height: presentation.compactGeometry.headerHeight)
                    .contentShape(Rectangle()).onTapGesture(perform: onToggle)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Burro: \(summary.workingCount) running, \(summary.scheduledCount) scheduled, \(summary.waitingCount) need input, \(summary.doneCount) completed worktrees, \(cleanup.count) to clean up")
                    .accessibilityAddTraits(.isButton).accessibilityAction { onToggle() }
            } else {
                VStack(spacing: 0) {
                    expandedHeader.frame(height: presentation.expandedGeometry.headerHeight)
                    expandedBody
                }
            }
        }
        .accessibilityHidden(compact == presentation.expanded)
        .preferredColorScheme(.dark)
        .alert("Delete merged worktree?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), presenting: pendingDeletion) { item in
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                pendingDeletion = nil
                Task {
                    deletionError = await store.deleteMergedWorktree(item)
                    reconcile(force: true)
                }
            }
        } message: { item in
            Text("Remove \(item.path)? The branch will be kept. Ignored files (including .env.local and dependencies) will also be deleted. Idle attached chats do not block removal; running agents and uncommitted changes still do.")
        }
        .alert("Could not delete worktree", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("OK") { deletionError = nil }
        } message: { Text(deletionError ?? "") }
        .transaction { $0.animation = nil }
        .onAppear { reconcile() }
        .onChange(of: activity.sessions) { _, _ in reconcile() }
        .onChange(of: presentation.holdingList) { _, _ in reconcile() }
        .onChange(of: presentation.expanded) { _, expanded in
            if !expanded { showingHealth = false; hoveredWorkspace = nil }
            reconcile(force: !expanded)
        }
        .onChange(of: presentation.includeIdle) { _, _ in reconcile(force: true) }
        .onChange(of: rowCount) { _, _ in updateGeometry() }
        .onChange(of: store.didCheckAgents) { _, _ in updateGeometry() }
    }
    private func reconcile(force: Bool = false) {
        guard !compact else { return }
        list.reconcile(NotchFeed(sessions: activity.sessions, includeIdle: presentation.includeIdle, codeOnly: true),
            holding: !force && presentation.expanded && presentation.holdingList)
        updateGeometry()
    }
    private func updateGeometry() {
        guard !compact else { return }
        presentation.visibleRows = rowCount
        onContentChange()
    }
    private var compactStatus: some View {
        HStack(spacing: 0) {
            statusCount(summary.workingCount > 0 ? summary.workingCount : summary.scheduledCount,
                symbol: summary.workingCount == 0 && summary.scheduledCount > 0 ? "clock" : "wrench",
                color: summary.workingCount > 0 ? AgentState.working.color : (summary.scheduledCount > 0 ? AgentState.scheduled.color : .gray),
                pulsing: summary.workingCount > 0)
                .frame(maxWidth: .infinity)
            Color.clear.frame(width: presentation.compactGeometry.hardwareGap)
            HStack(spacing: 8) {
            statusCount(summary.attentionCount, symbol: "tray.fill",
                color: summary.waitingCount > 0 ? NotchStyle.attention : (summary.pendingCount > 0 ? .yellow : (summary.mergedCount > 0 ? .purple : (summary.doneCount > 0 ? .blue : .gray))))
            statusCount(cleanup.count, symbol: "trash", color: .blue)
                .help("Merged worktrees that still exist: \(cleanup.count)")
            }.frame(maxWidth: .infinity)
        }.padding(.horizontal, 8)
    }
    private func statusCount(_ number: Int, symbol: String, color: Color, pulsing: Bool = false) -> some View {
        HStack(spacing: 4) {
            if pulsing { RunningPulse() }
            else { Image(systemName: symbol).font(.system(size: 8, weight: .medium)) }
            Text(store.didCheckAgents ? "\(number)" : "–").font(.system(size: 10, weight: .medium)).monospacedDigit()
        }.foregroundStyle(color).fixedSize()
    }
    private var expandedHeader: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("🧈").font(.system(size: 18)).frame(width: 22, height: 22)
                Text("Burro").font(.system(size: 12, weight: .semibold, design: .rounded))
            }.frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: presentation.expandedGeometry.hardwareGap)
            HStack(spacing: 8) {
                Button(action: onPin) { Image(systemName: presentation.pinned ? "pin.fill" : "pin") }
                    .foregroundStyle(presentation.pinned ? NotchStyle.accent : .secondary)
                    .accessibilityLabel(presentation.pinned ? "Unpin panel" : "Pin panel")
                    .help(presentation.pinned ? "Unpin panel" : "Keep panel open")
                Button(action: onCollapse) { Image(systemName: "chevron.up") }
                    .accessibilityLabel("Collapse agent panel").help("Collapse")
            }.buttonStyle(NotchIconButtonStyle()).frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(.horizontal, 22)
    }
    private var expandedBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(summary.workspaces.count + cleanup.count) worktrees").foregroundStyle(.secondary)
                if summary.waitingCount > 0 { count(summary.waitingCount, "need you", NotchStyle.attention) }
                if summary.count(.uncommitted) > 0 { count(summary.count(.uncommitted), "uncommitted", .yellow) }
                if summary.count(.needsPush) > 0 { count(summary.count(.needsPush), "needs push", .yellow) }
                if summary.count(.behind) > 0 { count(summary.count(.behind), "needs pull", .yellow) }
                if summary.count(.inProgress) > 0 { count(summary.count(.inProgress), "Git operation", .yellow) }
                if summary.needsMergeCount > 0 { count(summary.needsMergeCount, "needs merge", .yellow) }
                if summary.mergedCount > 0 { count(summary.mergedCount, "merged", .purple) }
                if summary.unknownDeliveryCount > 0 { count(summary.unknownDeliveryCount, "done", .blue) }
                count(summary.workingCount, "running", AgentState.working.color)
                HStack(spacing: 3) {
                    Image(systemName: "trash").foregroundStyle(.blue)
                    count(cleanup.count, "to clean up", .blue)
                }.fixedSize()
                if summary.scheduledCount > 0 { count(summary.scheduledCount, "scheduled", AgentState.scheduled.color) }
                Spacer(minLength: 0)
                Menu {
                    Toggle("Include idle chats", isOn: $presentation.includeIdle)
                    Button("Refresh status") { Task {
                        await GitReferenceRefresh.shared.invalidate()
                        await store.refresh(); await store.refreshAgents(); await store.refreshRemotes()
                    } }
                    Button("Monitoring details") { showingHealth = true }
                } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Agent list options")
            }.font(.system(size: 10, weight: .medium)).frame(height: 32).padding(.horizontal, 22)
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.horizontal, 22)
            if showingHealth { NotchHealthView(store: store) }
            else if !store.didCheckAgents { loading }
            else if list.groups.isEmpty && cleanup.isEmpty { empty }
            else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if !unlistedCleanup.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Merged · Cleanup", systemImage: "trash").foregroundStyle(.blue).font(.headline)
                                ForEach(unlistedCleanup) { tree in
                                    HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(tree.title).font(.system(size: 12, weight: .medium))
                                        Text("\(tree.machine) · \(tree.path)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        if !tree.canDelete {
                                            Text(tree.blockers.joined(separator: "; "))
                                                .font(.system(size: 9)).foregroundStyle(.orange).lineLimit(3)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    deleteButton(tree)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        }
                        ForEach(projects) { project in
                            VStack(spacing: 0) {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder.fill").foregroundStyle(NotchStyle.accent)
                                    Text(project.name).font(.system(size: 12, weight: .bold)).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text("\(project.machine) · \(project.workspaces.count) \(project.workspaces.count == 1 ? "worktree" : "worktrees")")
                                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                }.padding(.horizontal, 12).frame(height: 36)
                                    .background(.white.opacity(0.06)).help(project.path)
                                Rectangle().fill(.white.opacity(0.09)).frame(height: 1)
                                ForEach(project.workspaces) { workspace in
                                    workspaceRow(workspace)
                                    if expandedWorkspaces.contains(workspace.id) {
                                        workspaceChats(workspace).padding(.leading, 14)
                                    }
                                }
                            }.background(.white.opacity(0.025))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.09), lineWidth: 1))
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 10)
                }.scrollIndicators(.hidden)
            }
            footer
        }.frame(maxHeight: .infinity)
    }
    @ViewBuilder private func workspaceChats(_ workspace: NotchWorkspace) -> some View {
        ForEach(workspace.groups) { group in
            groupRow(group)
            if expandedGroups.contains(group.id) {
                ForEach(group.workers) { worker in
                    NotchAgentRow(session: worker, workspace: store.workspaceLabel(for: worker),
                        available: !group.unavailableIDs.contains(worker.id),
                        select: { onSelect(worker) }, inspect: { onInspect(worker) })
                        .padding(.leading, 18)
                }
            }
        }
    }
    @ViewBuilder private func workspaceRow(_ workspace: NotchWorkspace) -> some View {
        if let session = workspace.sessions.first {
            let expanded = expandedWorkspaces.contains(workspace.id)
            let behind = workspace.sessions.compactMap(\.upstreamBehind).max() ?? 0
            HStack(spacing: 0) {
            Button {
                hoveredWorkspace = nil
                if expanded { expandedWorkspaces.remove(workspace.id) }
                else { expandedWorkspaces.insert(workspace.id) }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "arrow.triangle.branch")
                        .frame(width: 30, height: 30).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.workspaceTitle(for: session)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text("\(session.remote?.hostName ?? "This Mac") · \(URL(fileURLWithPath: store.workspacePath(for: session)).lastPathComponent)\(behind > 0 ? " · Behind by \(behind)" : "")")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        if let edits = workspace.sessions.compactMap(\.workspaceDiff).first {
                            HStack(spacing: 4) {
                                if edits.added + edits.removed > 0 || edits.exact {
                                    Text("+\(edits.added)").foregroundStyle(.green)
                                    Text("−\(edits.removed)").foregroundStyle(.red)

                                }
                            }.font(.system(size: 9, weight: .medium)).monospacedDigit()
                                .help("Net Git diff from the comparison branch’s merge base, including readable untracked text files.")
                        }
                    }
                    Spacer(minLength: 6)
                    HStack(spacing: 8) {
                        Text("\(workspace.groups.count) \(workspace.groups.count == 1 ? "chat" : "chats")")
                            .font(.system(size: 11, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.9))
                        if workspace.status == .running { RunningPulse() }
                        if cleanup.contains(where: { $0.id == workspace.id }) {
                            Label("Merged", systemImage: "trash").foregroundStyle(.blue)
                        } else {
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(workspace.status.rawValue).foregroundStyle(workspace.status.color)
                                if [.running, .waiting, .scheduled].contains(workspace.status), let delivery = workspace.gitDelivery {
                                    Text(delivery.rawValue).font(.system(size: 9)).foregroundStyle(WorkspaceStatus(delivery).color)
                                }
                            }
                        }
                    }.fixedSize(horizontal: true, vertical: false)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary).frame(width: 24, height: 40)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { hoveredWorkspace = workspace.id }
                        }
                        .popover(isPresented: Binding(get: { hoveredWorkspace == workspace.id },
                            set: { if !$0 { hoveredWorkspace = nil } }), arrowEdge: .trailing) {
                            workspacePreview(workspace, session: session)
                        }
                        .accessibilityLabel("Preview chats")
                }.font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 10).frame(height: 56).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityHint("Click to expand chats; hover over the far-right chevron to preview")
            if let item = cleanup.first(where: { $0.id == workspace.id }) { deleteButton(item).padding(.trailing, 10) }
            }
        }
    }
    @ViewBuilder private func deleteButton(_ item: NotchCleanup) -> some View {
        if !item.canDelete {
            Button("Review") {
                store.search = ""
                store.filter = .all
                store.selection = item.path
                onOpenDashboard()
            }.buttonStyle(.bordered).disabled(!item.id.hasPrefix("local:"))
                .help(item.blockers.joined(separator: "\n"))
        } else {
        Button(role: .destructive) {
            pendingDeletion = item
        } label: {
            Text(store.deletingWorktreeID == item.id ? store.deletionPhase : "Delete")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.red.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.red.opacity(0.45)))
        }.buttonStyle(.plain)
            .disabled(store.deletingWorktreeID != nil || !item.id.hasPrefix("local:"))
            .help("Delete this merged worktree; keep its branch")
        }
    }
    private func workspacePreview(_ workspace: NotchWorkspace, session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.workspaceTitle(for: session)).font(.headline).lineLimit(1)
            Text(store.workspacePath(for: session)).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            VStack(spacing: 0) {
                ForEach(workspace.previewGroups) { group in groupRow(group) }
            }
            if workspace.previewOverflow > 0 {
                Button("+\(workspace.previewOverflow) more — show all chats") {
                    hoveredWorkspace = nil
                    expandedWorkspaces.insert(workspace.id)
                }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NotchStyle.accent).padding(.vertical, 6)
            }
        }.padding(12).frame(width: 480).preferredColorScheme(.dark)
    }
    @ViewBuilder private func groupRow(_ group: NotchGroup) -> some View {
        if let session = group.root {
            HStack(spacing: 0) {
                NotchAgentRow(session: session, workspace: store.workspaceLabel(for: session),
                    available: !group.unavailableIDs.contains(session.id), workerState: workerState(group),
                    select: { onSelect(session) }, inspect: { onInspect(session) })
                if !group.workers.isEmpty { workerDisclosure(group) }
            }
        } else {
            Button { toggleGroup(group.id) } label: {
                HStack(spacing: 11) {
                    Image(systemName: "square.stack.3d.up").frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Background workers").font(.system(size: 12, weight: .medium))
                        Text("\(group.workers.count) \(group.workers.count == 1 ? "worker" : "workers") · \(group.workers.first?.remote?.hostName ?? "This Mac")")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    if group.workers.contains(where: { $0.state == .waiting && $0.remote?.stale != true && !group.unavailableIDs.contains($0.id) }) {
                        Text("Needs input").font(.system(size: 10, weight: .medium)).foregroundStyle(NotchStyle.attention)
                    } else if group.workers.contains(where: { $0.state == .working && $0.remote?.stale != true && !group.unavailableIDs.contains($0.id) }) {
                        Text("Running").font(.system(size: 10, weight: .medium)).foregroundStyle(AgentState.working.color)
                    }
                    Image(systemName: expandedGroups.contains(group.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }.padding(.horizontal, 10).frame(height: 56).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("\(expandedGroups.contains(group.id) ? "Hide" : "Show") \(group.workers.count) background workers on \(group.workers.first?.remote?.hostName ?? "This Mac")")
        }
    }
    private func workerState(_ group: NotchGroup) -> AgentState? {
        let live = group.workers.filter { $0.remote?.stale != true && !group.unavailableIDs.contains($0.id) }
        if live.contains(where: { $0.state == .waiting }) { return .waiting }
        return live.contains(where: { $0.state == .working }) ? .working : nil
    }
    private func workerDisclosure(_ group: NotchGroup) -> some View {
        Button { toggleGroup(group.id) } label: {
            HStack(spacing: 3) {
                Text("\(group.workers.count)").monospacedDigit()
                Image(systemName: expandedGroups.contains(group.id) ? "chevron.down" : "chevron.right")
            }.font(.system(size: 10, weight: .medium)).padding(7)
        }.buttonStyle(.plain)
            .foregroundStyle(group.workers.contains { $0.state == .waiting } ? NotchStyle.attention : .secondary)
            .help("\(group.workers.count) background workers")
            .accessibilityLabel("\(expandedGroups.contains(group.id) ? "Hide" : "Show") workers for \(group.title)")
    }
    private func toggleGroup(_ id: String) {
        if expandedGroups.contains(id) { expandedGroups.remove(id) } else { expandedGroups.insert(id) }
    }
    private var footer: some View {
        HStack(spacing: 10) {
            if showingHealth {
                Button { showingHealth = false } label: { Label("Agents", systemImage: "chevron.left") }
            } else if let notice = store.notchNotices.first {
                Button { showingHealth = true } label: {
                    Label(store.notchNotices.count == 1 ? notice.summary : "\(store.notchNotices.count) monitoring notices", systemImage: "info.circle")
                        .lineLimit(1).truncationMode(.middle)
                }.foregroundStyle(notice.connectionIssue ? NotchStyle.attention : .secondary)
                    .help("Show monitoring details")
            } else {
                Label(store.didCheckAgents ? "Up to date" : "Checking…", systemImage: store.didCheckAgents ? "checkmark" : "ellipsis").foregroundStyle(.secondary)
                    .help("Last local check: \(activity.sampledAt.formatted())")
            }
            Spacer(minLength: 0)
            if list.pendingChanges > 0 && !showingHealth {
                Button("Update list") { reconcile(force: true) }.foregroundStyle(NotchStyle.accent)
                    .help("Apply pending list changes; rows stay still while you interact")
            }
            Button(action: onOpenDashboard) { Image(systemName: "arrow.up.right") }
                .help("Open worktrees in Burro").accessibilityLabel("Open worktrees in Burro")
        }.buttonStyle(.plain).font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 22).frame(height: 37).background(.white.opacity(0.035))
    }
    private func count(_ number: Int, _ title: String, _ color: Color) -> some View {
        HStack(spacing: 3) { Text("\(number)").foregroundStyle(color).monospacedDigit(); Text(title).foregroundStyle(.secondary) }
    }
    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 20, weight: .light)).foregroundStyle(NotchStyle.accent)
            Text(activity.warnings.isEmpty ? "All quiet" : "No activity detected").font(.system(size: 13, weight: .medium))
            Text("Chats needing you will appear here.").font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(12)
    }
    private var loading: some View {
        VStack(spacing: 16) {
            ForEach(0..<3) { _ in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.05)).frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.08)).frame(width: 200, height: 8)
                        RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.04)).frame(width: 130, height: 6)
                    }
                    Spacer()
                }
            }
            Spacer(minLength: 0)
        }.padding(22).accessibilityElement(children: .ignore).accessibilityLabel("Loading agent status")
    }
}
private struct NotchIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .medium))
            .frame(width: 25, height: 25).background(.white.opacity(configuration.isPressed ? 0.12 : 0.05), in: Circle())
    }
}
enum NotchStyle {
    static let background = Color.black
    static let accent = Color(red: 0.78, green: 0.87, blue: 0.66)
    static let attention = Color(red: 0.96, green: 0.70, blue: 0.36)
    static let claude = Color(red: 0.85, green: 0.64, blue: 0.47)
}

extension WorkspaceStatus {
    var color: Color {
        switch self {
        case .waiting: return NotchStyle.attention
        case .running: return AgentState.working.color
        case .scheduled: return AgentState.scheduled.color
        case .uncommitted, .needsPush, .needsMerge, .behind, .inProgress: return .yellow
        case .merged: return .purple
        case .done: return .blue
        default: return .secondary
        }
    }
}

/// Timeline-driven opacity avoids animating list layout or pointer targets.
private struct RunningPulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * .pi
            Circle().fill(AgentState.working.color)
                .opacity(reduceMotion ? 1 : 0.65 + 0.25 * sin(phase))
                .frame(width: 5, height: 5)
        }.accessibilityHidden(true)
    }
}
