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
    var onSelectPage: (NotchPage) -> Void
    var onNavigationBounds: ([NotchPage: CGRect]) -> Void
    var onContentChange: () -> Void
    var compact = false
    @State private var list = NotchListState()
    @State private var expandedGroups: Set<String> = []
    @State private var showingHealth = false
    @State private var workspacePaths: [String: String] = [:]
    private var workspaces: [NotchWorkspace] {
        NotchWorkspace.grouped(list.groups) { workspacePaths[$0.id] ?? store.workspacePath(for: $0) }
    }
    private var showingUsage: Bool { presentation.navigation.visible == .usage }
    private var activity: AgentActivitySnapshot { store.agentActivity }
    private var rowCount: Int {
        list.groups.reduce(0) { $0 + 1 + (expandedGroups.contains($1.id) ? $1.workers.count : 0) } + workspaces.filter { !$0.path.isEmpty }.count
    }

    var body: some View {
        Group {
            if compact {
                compactStatus.frame(height: presentation.compactGeometry.headerHeight)
                    .contentShape(Rectangle()).onTapGesture(perform: onToggle)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Burro: \(activity.workingCount) running, \(activity.scheduledCount) scheduled, \(activity.waitingCount) need input, \(activity.doneCount) done and unread")
                    .accessibilityAddTraits(.isButton).accessibilityAction { onToggle() }
            } else {
                VStack(spacing: 0) {
                    expandedHeader.frame(height: presentation.expandedGeometry.headerHeight)
                    expandedBody
                }
            }
        }
        .coordinateSpace(name: "NotchNavigationRoot")
        .onPreferenceChange(NotchTabBoundsKey.self) { bounds in
            guard !compact else { return }
            Task { @MainActor in onNavigationBounds(bounds) }
        }
        .accessibilityHidden(compact == presentation.expanded)
        .preferredColorScheme(.dark)
        .transaction { $0.animation = nil }
        .onAppear { reconcile() }
        .onChange(of: activity.sessions) { _, _ in reconcile() }
        .onChange(of: presentation.holdingList) { _, _ in reconcile() }
        .onChange(of: presentation.expanded) { _, expanded in
            if !expanded { showingHealth = false }
            reconcile(force: !expanded)
        }
        .onChange(of: presentation.includeIdle) { _, _ in reconcile(force: true) }
        .onChange(of: presentation.navigation.visible) { _, page in
            updateGeometry()
            if page == .usage { Task { await store.refreshUsage() } }
        }
        .onChange(of: presentation.navigation.isPreviewing) { _, _ in updateGeometry() }
        .onChange(of: rowCount) { _, _ in updateGeometry() }
        .onChange(of: store.didCheckAgents) { _, _ in updateGeometry() }
    }
    private func reconcile(force: Bool = false) {
        guard !compact else { return }
        let holding = !force && presentation.expanded && presentation.holdingList
        list.reconcile(NotchFeed(sessions: activity.sessions, includeIdle: presentation.includeIdle), holding: holding)
        if !holding || workspacePaths.isEmpty {
            workspacePaths = Dictionary(list.groups.flatMap(\.members).map { ($0.id, store.workspacePath(for: $0)) }, uniquingKeysWith: { first, _ in first })
        }
        updateGeometry()
    }
    private func updateGeometry() {
        guard !compact else { return }
        presentation.visibleRows = showingUsage || presentation.navigation.isPreviewing ? max(5, rowCount) : rowCount
        onContentChange()
    }
    private var compactStatus: some View {
        HStack(spacing: 0) {
            statusCount(activity.workingCount > 0 ? activity.workingCount : activity.scheduledCount,
                symbol: activity.workingCount == 0 && activity.scheduledCount > 0 ? "clock" : "waveform.path",
                color: activity.workingCount > 0 ? AgentState.working.color : (activity.scheduledCount > 0 ? AgentState.scheduled.color : .gray))
                .frame(maxWidth: .infinity)
            Color.clear.frame(width: presentation.compactGeometry.hardwareGap)
            statusCount(activity.attentionCount, symbol: "tray.fill",
                color: activity.waitingCount > 0 ? NotchStyle.attention : (activity.doneCount > 0 ? .blue : .gray))
                .frame(maxWidth: .infinity)
        }.padding(.horizontal, 8)
    }
    private func statusCount(_ number: Int, symbol: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8, weight: .medium))
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
            HStack(spacing: 12) {
                navigationTabs
                Spacer(minLength: 4)
                if presentation.navigation.isPreviewing {
                    Label("Preview", systemImage: "eye").foregroundStyle(.secondary)
                        .help("Move away to return; click the tab to keep this view")
                } else if !showingUsage {
                    if activity.waitingCount > 0 { count(activity.waitingCount, "need you", NotchStyle.attention) }
                    if activity.doneCount > 0 { count(activity.doneCount, "done", .blue) }
                    if activity.workingCount == 0 && activity.scheduledCount > 0 {
                        count(activity.scheduledCount, "scheduled", AgentState.scheduled.color)
                    } else { count(activity.workingCount, "running", AgentState.working.color) }
                }
                Menu {
                    Toggle("Include idle chats", isOn: $presentation.includeIdle)
                    Button("Refresh status") { Task { await store.refreshAgents(); await store.refreshRemotes() } }
                    Button("Usage limits") { onSelectPage(.usage); showingHealth = false; Task { await store.refreshUsage() } }
                    Button("Monitoring details") { onSelectPage(.agents); showingHealth = true }
                } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Notch options")
            }.font(.system(size: 10, weight: .medium)).frame(height: 32).padding(.horizontal, 22)
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.horizontal, 22)
            if showingUsage {
                NotchUsageView(snapshot: store.providerUsage, enabled: store.usageEnabled,
                    onEnable: { store.usageEnabled = true }, onConnectClaude: store.connectClaudeUsage, checking: store.checkingUsage)
            }
            else if showingHealth && !presentation.navigation.isPreviewing { NotchHealthView(store: store) }
            else if !store.didCheckAgents { loading }
            else if list.groups.isEmpty { empty }
            else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(workspaces) { workspace in
                            if !workspace.path.isEmpty { workspaceHeader(workspace) }
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
                    }.padding(.horizontal, 12).padding(.vertical, 4)
                }.scrollIndicators(.automatic)
            }
            footer
        }.frame(maxHeight: .infinity)
    }
    private func workspaceHeader(_ workspace: NotchWorkspace) -> some View {
        let session = workspace.sessions.first
        let branch = session.flatMap { store.workspaceBranch(for: $0) }
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: "folder").foregroundStyle(NotchStyle.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(workspace.path.isEmpty ? "Background workers" : "Folder: " + URL(fileURLWithPath: workspace.path).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(session?.remote?.hostName ?? "This Mac") · Branch: \(branch ?? "unavailable")")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(workspace.groups.count) \(workspace.groups.count == 1 ? "chat" : "chats")")
                if let session, let delivery = store.workspaceDelivery(for: session) {
                    Text(delivery).font(.system(size: 9))
                        .help("Checkout status from local Git refs; not a per-chat delivery or cleanup guarantee")
                }
            }.foregroundStyle(.secondary)
        }.font(.system(size: 10, weight: .medium)).padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
            .help(workspace.path.isEmpty ? "Workers without a known parent chat" : workspace.path)
    }
    private var navigationTabs: some View {
        HStack(spacing: 2) {
            ForEach(NotchPage.allCases, id: \.self) { page in
                let selected = presentation.navigation.selected == page
                let preview = presentation.navigation.preview == page
                Button { showingHealth = false; onSelectPage(page) } label: {
                    Label(page.title, systemImage: page.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 9).frame(height: 24)
                        .foregroundStyle(selected || preview ? .white : .gray)
                        .background(.white.opacity(selected ? 0.12 : (preview ? 0.06 : 0)), in: Capsule())
                        .overlay { Capsule().strokeBorder(.white.opacity(preview ? 0.28 : 0), lineWidth: 1) }
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
                    .accessibilityLabel(page.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityValue(preview ? "Preview" : (selected ? "Selected" : ""))
                    .help("Hover to preview \(page.title.lowercased()); click to keep it open")
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: NotchTabBoundsKey.self,
                                value: [page: geometry.frame(in: .named("NotchNavigationRoot"))])
                        }
                    }
            }
        }.fixedSize()
    }
    @ViewBuilder private func groupRow(_ group: NotchGroup) -> some View {
        if let session = group.root {
            HStack(spacing: 0) {
                NotchAgentRow(session: session, workspace: session.remote?.hostName ?? "This Mac",
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
            if showingUsage {
                Text("Remaining · all machines").foregroundStyle(.secondary)
            } else if showingHealth {
                Button { showingHealth = false; onSelectPage(.agents) } label: { Label("Agents", systemImage: "chevron.left") }
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
            if showingUsage {
                Button(store.checkingUsage ? "Refreshing…" : "Refresh") { Task { await store.refreshUsage(force: true) } }
                    .disabled(store.checkingUsage).help("Fetch current limits from your connected accounts")
            }
            if list.pendingChanges > 0 && !showingHealth && !showingUsage {
                Button("Update list") { reconcile(force: true) }.foregroundStyle(NotchStyle.accent)
                    .help("Apply pending list changes; rows stay still while you interact")
            }
            Button { if showingUsage { store.filter = .usage }; onOpenDashboard() } label: { Image(systemName: "arrow.up.right") }
                .help(showingUsage ? "Open usage dashboard in Burro" : "Open worktrees in Burro")
                .accessibilityLabel(showingUsage ? "Open usage dashboard in Burro" : "Open worktrees in Burro")
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
private struct NotchTabBoundsKey: PreferenceKey {
    static let defaultValue: [NotchPage: CGRect] = [:]
    static func reduce(value: inout [NotchPage: CGRect], nextValue: () -> [NotchPage: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
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
