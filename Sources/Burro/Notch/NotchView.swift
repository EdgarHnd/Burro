// A compact attention queue keeps live status separate from stable pointer and keyboard targets.
// Collapsed, the notch shows the running (or scheduled) count with a waveform on the left and, on
// the right, the number of chats waiting on you in amber with an amber dot (or, when none wait,
// unread results in blue); a side with a zero count is left empty, so an idle notch is plain black.
// Expanded, the Agents tab lists "Needs you" cards (quick reply or hand-off, NotchAttentionRows)
// above "Working" lines; chats that only have a result to read are counted in the footer's
// "N ready to read" (it opens Chats) beside the pin. Each card is keyed by the chat it answers,
// and reply holds are dropped for chats no listed group targets any more. Sections are fixed while you interact, like
// the rows. The list reports its height to the panel in NotchGeometry's row slots
// (NotchListLayout), so the panel's own sizing is unchanged.
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
    /// A quick-reply field has focus / holds typed text: the controller keeps the panel open.
    var onReply: (_ focused: Bool, _ edited: Bool) -> Void = { _, _ in }
    var compact = false
    /// Snapshot tests only: invented drafts, questions, checks and turn durations.
    var fixture: NotchFixture? = nil
    @State private var list = NotchListState()
    @State private var expandedGroups: Set<String> = []
    @State private var showingHealth = false
    @State private var workspacePaths: [String: String] = [:]
    /// Each listed group's section, decided when the list reconciles (fixed while holding).
    @State private var sectionOf: [String: NotchSection] = [:]
    @State private var focusedReplies: Set<String> = []
    @State private var editedReplies: Set<String> = []
    private var showingUsage: Bool { presentation.navigation.visible == .usage }
    private var showingMac: Bool { presentation.navigation.visible == .mac }
    private var activity: AgentActivitySnapshot { store.agentActivity }
    private var chatSessions: [AgentSession] { presentation.chatScope == .today ? store.notchChatSessions : activity.sessions }
    private var needsYouGroups: [NotchGroup] { list.groups.filter { sectionOf[$0.id] == .needsYou } }
    private var workingGroups: [NotchGroup] { list.groups.filter { sectionOf[$0.id] == .working } }
    private var rowCount: Int {
        if presentation.chatScope == .today { return list.groups.count }
        let cards = needsYouGroups.count
        let lines = workingGroups.reduce(0) { $0 + 1 + (expandedGroups.contains($1.id) ? $1.workers.count : 0) }
        return NotchListLayout.slots(cards: cards, lines: lines, headers: (cards > 0 ? 1 : 0) + (lines > 0 ? 1 : 0))
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
                    expandedHeader.frame(height: presentation.expandedGeometry.headerHeight).background(.black)
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
        .foregroundStyle(AppAppearance.text)
        .tint(AppAppearance.text)
        .transaction { $0.animation = nil }
        .onAppear { reconcile() }
        .onChange(of: chatSessions) { _, _ in reconcile() }
        .onChange(of: Calendar.current.startOfDay(for: activity.sampledAt)) { _, _ in reconcile() }
        .onChange(of: presentation.holdingList) { _, _ in reconcile() }
        .onChange(of: presentation.expanded) { _, expanded in
            if !expanded { showingHealth = false; focusedReplies = []; reportReplies() }
            reconcile(force: !expanded)
        }
        .onChange(of: presentation.includeIdle) { _, _ in reconcile(force: true) }
        .onChange(of: presentation.chatScope) { _, _ in reconcile(force: true) }
        .onChange(of: presentation.navigation.visible) { _, page in
            updateGeometry()
            if page == .usage { Task { await store.refreshUsage() } }
        }
        .onChange(of: presentation.navigation.isPreviewing) { _, _ in updateGeometry() }
        .onChange(of: rowCount) { _, _ in updateGeometry() }
        .onChange(of: showingHealth) { _, _ in updateGeometry() }
        .onChange(of: store.didCheckAgents) { _, _ in updateGeometry() }
    }
    private func reconcile(force: Bool = false) {
        guard !compact else { return }
        let holding = !force && presentation.expanded && presentation.holdingList
        list.reconcile(NotchFeed(sessions: chatSessions, includeIdle: presentation.includeIdle, scope: presentation.chatScope), holding: holding)
        if !holding || sectionOf.isEmpty {
            sectionOf = Dictionary(list.groups.compactMap { group in NotchAttentionList.section(group).map { (group.id, $0) } },
                                   uniquingKeysWith: { first, _ in first })
        }
        // Reply holds only for chats a listed group still targets.
        let focused = NotchAttentionList.liveReplyIDs(focusedReplies, groups: list.groups)
        let edited = NotchAttentionList.liveReplyIDs(editedReplies, groups: list.groups)
        if focused != focusedReplies || edited != editedReplies {
            focusedReplies = focused; editedReplies = edited; reportReplies()
        }
        if !holding || workspacePaths.isEmpty {
            workspacePaths = Dictionary(list.groups.flatMap(\.members).map { ($0.id, store.workspacePath(for: $0)) }, uniquingKeysWith: { first, _ in first })
        }
        updateGeometry()
    }
    private func replyHold(_ id: String, focused: Bool, edited: Bool) {
        if focused { focusedReplies.insert(id) } else { focusedReplies.remove(id) }
        if edited { editedReplies.insert(id) } else { editedReplies.remove(id) }
        reportReplies()
    }
    private func reportReplies() { onReply(!focusedReplies.isEmpty, !editedReplies.isEmpty) }
    private func updateGeometry() {
        guard !compact else { return }
        let rows = showingHealth || showingUsage || showingMac || presentation.navigation.isPreviewing ? 5 : min(5, rowCount)
        if presentation.visibleRows != rows { presentation.visibleRows = rows }
        onContentChange()
    }
    private var compactStatus: some View {
        let status = NotchCompactStatus(working: activity.workingCount, scheduled: activity.scheduledCount,
                                        waiting: activity.waitingCount, done: activity.doneCount)
        return HStack(spacing: 0) {
            Group {
                switch status.left {
                case .working(let count): statusCount(count, symbol: "waveform", color: AgentState.working.color, leading: true)
                case .scheduled(let count): statusCount(count, symbol: "clock", color: AgentState.scheduled.color, leading: true)
                case .none: statusCount(0, symbol: "waveform", color: .gray, leading: true)
                }
            }.frame(maxWidth: .infinity)
            Color.clear.frame(width: presentation.compactGeometry.hardwareGap)
            Group {
                switch status.right {
                case .needsYou(let count): statusCount(count, symbol: nil, color: NotchStyle.attention, leading: false)
                case .toRead(let count): statusCount(count, symbol: nil, color: AppAppearance.blue, leading: false)
                case .none: statusCount(0, symbol: nil, color: .gray, leading: false)
                }
            }.frame(maxWidth: .infinity)
        }.padding(.horizontal, 8)
    }
    /// One side of the compact notch: a glyph and the count on the left, the count and a dot on
    /// the right. A side with nothing to count stays empty ("–" on both until the first check).
    @ViewBuilder private func statusCount(_ number: Int, symbol: String?, color: Color, leading: Bool) -> some View {
        if !store.didCheckAgents || number > 0 {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
                Text(store.didCheckAgents ? "\(number)" : "–").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                if !leading && store.didCheckAgents { Circle().fill(color).frame(width: 6, height: 6) }
            }.foregroundStyle(store.didCheckAgents ? color : .gray).fixedSize()
        } else {
            Color.clear.frame(height: 1) // keeps both sides centred around the camera
        }
    }
    private var expandedHeader: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                BurroMark(active: presentation.expanded, working: activity.workingCount > 0)
                    .frame(width: 22, height: 22)
                Text("Burro").font(.system(size: 12, weight: .semibold, design: .rounded))
            }.frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: presentation.expandedGeometry.hardwareGap)
            HStack(spacing: 8) {
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
                } else if showingMac {
                    if !store.health.report.leftovers.isEmpty {
                        count(store.health.report.leftovers.count, "left running", NotchStyle.attention)
                    }
                } else if !showingUsage && !showingHealth && presentation.chatScope == .today {
                    count(list.groups.count, "today", AppAppearance.text)
                } else if !showingUsage {
                    if activity.waitingCount > 0 { count(activity.waitingCount, "need you", NotchStyle.attention) }
                    if activity.doneCount > 0 { count(activity.doneCount, "done", .blue) }
                    if activity.workingCount == 0 && activity.scheduledCount > 0 {
                        count(activity.scheduledCount, "scheduled", AgentState.scheduled.color)
                    } else { count(activity.workingCount, "running", AgentState.working.color) }
                }
                Menu {
                    Picker("Chats", selection: Binding(get: { presentation.chatScope }, set: { scope in
                        showingHealth = false
                        presentation.chatScope = scope
                        onSelectPage(.agents)
                    })) {
                        Text("Active chats").tag(NotchChatScope.activity)
                        Text("Today's chats").tag(NotchChatScope.today)
                    }.pickerStyle(.inline)
                    Divider()
                    if presentation.chatScope == .activity {
                        Toggle("Include idle and unverified chats", isOn: $presentation.includeIdle)
                    }
                    Button("Refresh status") { Task { await store.refreshAgents(); await store.refreshRemotes() } }
                    Button("Usage limits") { onSelectPage(.usage); showingHealth = false; Task { await store.refreshUsage() } }
                    Button("Mac health") { onSelectPage(.mac); showingHealth = false }
                    Button("Monitoring details") { onSelectPage(.agents); showingHealth = true }
                } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Notch options").help("Notch options")
            }.font(.system(size: 10, weight: .medium)).frame(height: 32).padding(.horizontal, 22)
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.horizontal, 22)
            if showingUsage {
                NotchUsageView(snapshot: store.providerUsage, enabled: store.usageEnabled,
                    onEnable: { store.usageEnabled = true }, onConnectClaude: store.connectClaudeUsage, checking: store.checkingUsage)
            }
            else if showingMac {
                NotchMacView(health: store.health, keepAwake: store.keepAwake, active: presentation.expanded) { store.page = .health; onOpenDashboard() }
            }
            else if showingHealth && !presentation.navigation.isPreviewing { NotchHealthView(store: store) }
            else if !store.didCheckAgents { loading }
            else if presentation.chatScope == .today {
                if list.groups.isEmpty { empty }
                else { NotchTodayView(groups: list.groups, active: presentation.expanded, select: onSelect, inspect: onInspect) }
            }
            else if needsYouGroups.isEmpty && workingGroups.isEmpty { empty }
            else { attentionList }
            footer
        }.frame(maxHeight: .infinity)
    }
    /// Needs you (cards) above Working (lines), in the list's held order.
    private var attentionList: some View {
        let needs = needsYouGroups, working = workingGroups
        return ScrollView {
            VStack(spacing: NotchListLayout.gap) {
                if !needs.isEmpty {
                    NotchSectionHeader(title: "Needs you", count: needs.count, tint: NotchStyle.attention)
                    ForEach(needs) { group in needsCard(group) }
                }
                if !working.isEmpty {
                    NotchSectionHeader(title: "Working", count: working.count, tint: AgentState.working.color)
                    ForEach(working) { group in
                        workingLine(group)
                        if expandedGroups.contains(group.id) {
                            ForEach(group.workers) { worker in
                                NotchWorkingLine(session: worker, place: place(worker), available: !group.unavailableIDs.contains(worker.id),
                                                 turn: turn(worker.id),
                                                 select: { onSelect(worker) }, inspect: { onInspect(worker) })
                                    .padding(.leading, 16)
                            }
                        }
                    }
                }
            }.padding(.horizontal, 20).padding(.vertical, NotchListLayout.inset)
        }.scrollIndicators(.automatic)
    }
    @ViewBuilder private func needsCard(_ group: NotchGroup) -> some View {
        if let session = NotchAttentionList.target(group) {
            let brief = fixture == nil ? store.brief.file.open.first { $0.kind.needsYou && $0.chatID?.lowercased() == session.id.lowercased() } : nil
            NotchNeedsYouCard(store: store, session: session, place: place(session),
                              question: fixture.map { $0.questions[session.id] } ?? brief.map { $0.question ?? $0.headline },
                              draft: fixture.map { $0.drafts[session.id] } ?? store.brief.draft(chatID: session.id, actions: store.orchestrator.actions),
                              host: store.remoteHosts.first { $0.id == session.remote?.hostID },
                              available: !group.unavailableIDs.contains(session.id), active: presentation.expanded,
                              now: activity.sampledAt, checkOverride: fixture?.checks[session.id],
                              open: { onSelect(session) }, inspect: { onInspect(session) },
                              currentTarget: { list.groups.first { $0.id == group.id }.flatMap(NotchAttentionList.target)?.id },
                              hold: { id, focused, edited in replyHold(id, focused: focused, edited: edited) })
                // A new target is a new card: no text, draft or focus carries over to another chat.
                .id(session.id)
        }
    }
    @ViewBuilder private func workingLine(_ group: NotchGroup) -> some View {
        if let session = group.root {
            NotchWorkingLine(session: session, place: place(session), available: !group.unavailableIDs.contains(session.id),
                             workerState: workerState(group), turn: turn(session.id),
                             workers: group.workers.count, workersExpanded: expandedGroups.contains(group.id),
                             toggleWorkers: group.workers.isEmpty ? nil : { toggleGroup(group.id) },
                             select: { onSelect(session) }, inspect: { onInspect(session) })
        } else {
            let live = group.workers.filter { $0.remote?.stale != true && !group.unavailableIDs.contains($0.id) }
            NotchWorkersLine(count: group.workers.count, machine: group.workers.first?.remote?.hostName ?? "This Mac",
                             needsYou: live.contains { $0.state == .waiting }, running: live.contains { $0.state == .working },
                             expanded: expandedGroups.contains(group.id)) { toggleGroup(group.id) }
        }
    }
    private func turn(_ id: String) -> TimeInterval? { fixture.map { $0.turns[id] } ?? store.turnClock.turn(id, now: activity.sampledAt) }
    /// "This Mac · focustown": the machine and the chat's folder (its worktree's when Burro knows it).
    private func place(_ session: AgentSession) -> String {
        let path = workspacePaths[session.id] ?? session.cwd
        return "\(session.remote?.hostName ?? "This Mac") · \(URL(fileURLWithPath: path).lastPathComponent)"
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
                        .foregroundStyle(selected || preview ? AppAppearance.text : AppAppearance.secondary)
                        .background(selected ? AppAppearance.background : (preview ? AppAppearance.surface : .clear), in: Capsule())
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
        }.padding(2).background(AppAppearance.raised, in: Capsule()).fixedSize()
    }
    private func workerState(_ group: NotchGroup) -> AgentState? {
        let live = group.workers.filter { $0.remote?.stale != true && !group.unavailableIDs.contains($0.id) }
        if live.contains(where: { $0.state == .waiting }) { return .waiting }
        return live.contains(where: { $0.state == .working }) ? .working : nil
    }
    private func toggleGroup(_ id: String) {
        if expandedGroups.contains(id) { expandedGroups.remove(id) } else { expandedGroups.insert(id) }
    }
    private var footer: some View {
        HStack(spacing: 10) {
            let showsAgents = !showingUsage && !showingMac && !showingHealth && presentation.chatScope == .activity
            if showsAgents && activity.doneCount > 0 {
                Button { store.go(to: .remote); onOpenDashboard() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(AppAppearance.blue).frame(width: 6, height: 6)
                        Text("\(activity.doneCount) ready to read").font(.system(size: 11.5, weight: .medium)).foregroundStyle(AppAppearance.text)
                    }
                }.help("Open Chats to read the finished results").fixedSize()
            }
            if showsAgents && activity.doneCount > 0 && activity.unverifiedSessions.isEmpty && store.notchNotices.isEmpty {
                EmptyView()
            } else if showingUsage {
                Text("Remaining · all machines").foregroundStyle(.secondary)
            } else if showingMac {
                Text("This Mac · live").foregroundStyle(.secondary)
            } else if showingHealth {
                Button { showingHealth = false; onSelectPage(.agents) } label: { Label("Agents", systemImage: "chevron.left") }
            } else if presentation.chatScope == .today {
                Text("Today · Last active").foregroundStyle(.secondary)
                if !store.notchNotices.isEmpty {
                    Button { showingHealth = true } label: { Image(systemName: "info.circle") }
                        .foregroundStyle(.secondary).help("Show monitoring and history coverage")
                        .accessibilityLabel("Monitoring details")
                }
            } else if !activity.unverifiedSessions.isEmpty {
                Button { showingHealth = true } label: {
                    Label("\(activity.unverifiedSessions.count) chat statuses unavailable", systemImage: "info.circle")
                        .lineLimit(1)
                }.foregroundStyle(.secondary).help("Show unverified chats and monitoring details")
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
            if list.pendingChanges > 0 && !showingHealth && !showingUsage && !showingMac {
                Button("Update list") { reconcile(force: true) }.foregroundStyle(NotchStyle.accent)
                    .help("Apply pending list changes; rows stay still while you interact")
            }
            Button(action: onPin) { Image(systemName: presentation.pinned ? "pin.fill" : "pin") }
                .foregroundStyle(presentation.pinned ? NotchStyle.accent : .secondary)
                .accessibilityLabel(presentation.pinned ? "Unpin panel" : "Pin panel open")
                .help(presentation.pinned ? "Unpin panel" : "Keep panel open")
            Button {
                store.page = showingUsage ? .usage : (showingMac ? .health : .home)
                onOpenDashboard()
            } label: { Image(systemName: "arrow.up.right") }
                .help(dashboardLabel).accessibilityLabel(dashboardLabel)
        }.buttonStyle(.plain).font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 22).frame(height: 37).background(.white.opacity(0.035))
    }
    private var dashboardLabel: String {
        showingUsage ? "Open usage dashboard in Burro" : (showingMac ? "Open Mac Health in Burro" : "Open Burro")
    }
    private func count(_ number: Int, _ title: String, _ color: Color) -> some View {
        HStack(spacing: 3) { Text("\(number)").foregroundStyle(color).monospacedDigit(); Text(title).foregroundStyle(.secondary) }
            .lineLimit(1).fixedSize()
    }
    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: presentation.chatScope == .today ? "clock" : "checkmark")
                .font(.system(size: 20, weight: .light)).foregroundStyle(NotchStyle.accent)
            Text(presentation.chatScope == .today ? "No chats today" :
                (activity.warnings.isEmpty && activity.unverifiedSessions.isEmpty ? "All quiet" : "No confirmed activity"))
                .font(.system(size: 13, weight: .medium))
            Text(presentation.chatScope == .today ? "Chats active today will appear here." : "Chats needing you will appear here.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
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
    static let accent = AppAppearance.green
    static let attention = AppAppearance.amber
    static let claude = AppAppearance.claude
}
