// The desktop shell: Home is the landing page; worktrees, usage, Mac health and remote
// sessions open from it, the toolbar's page switcher, or ⌘1–⌘5.
import SwiftUI
import BurroCore

struct ContentView: View {
    @Bindable var store: AppStore
    var notch: NotchController
    var body: some View {
        Group {
            switch store.page {
            case .home: HomeView(store: store, notch: notch)
            case .today: TodayView(store: store)
            case .machines: MachinesView(store: store)
            case .worktrees:
                worktrees.searchable(text: $store.search, placement: .toolbar, prompt: "Branch, repository, or agent")
            case .usage: UsageDashboardView(usage: store.usage)
            case .health: MacHealthView(health: store.health)
            case .remote: remote
            }
        }
        .navigationTitle(store.page == .home ? "Burro" : store.page.title)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                TopBarButton(symbol: "calendar", help: "Today (⌘2)", selected: store.page == .today) { store.page = .today }
                TopBarButton(symbol: "house", help: "Home (⌘1)", selected: store.page == .home) { store.page = .home }
                if store.page != .home && store.page != .today {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(AppAppearance.tertiary)
                        Label(store.page.title, systemImage: store.page.icon).font(.system(size: 13, weight: .semibold))
                            .labelStyle(.titleAndIcon)
                    }.padding(.horizontal, 4)
                }
            }
            // Push the action icons to the trailing edge (the window has no title to do it).
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
            #endif
            ToolbarItemGroup(placement: .automatic) {
                if store.page == .worktrees {
                    if store.scanning { ProgressView().controlSize(.small).accessibilityLabel("Refreshing worktrees") }
                    Button { store.filter = .cleanup } label: { Label("Cleanup", systemImage: "trash") }
                        .help("Review inactive worktrees and cleanup blockers")
                    Button { store.addRepository() } label: { Label("Add repository", systemImage: "folder.badge.plus") }
                        .help("Add a repository")
                }
                if [.worktrees, .remote, .today, .machines].contains(store.page) {
                    Button { Task { await store.refreshCurrentPage() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Refresh (⌘R)").disabled(store.refreshingCurrentPage)
                }
            }
            ToolbarItemGroup(placement: .automatic) {
                TopBarButton(symbol: "tray", help: "Inbox: chats that need you or have results to read",
                             badge: store.agentActivity.attentionCount, selected: false) { store.page = .today }
                TopBarButton(symbol: "arrow.triangle.branch", help: "Worktrees (⌘3)", selected: store.page == .worktrees) { store.page = .worktrees }
                TopBarButton(symbol: "server.rack", help: "Machines (⌘4)", selected: store.page == .machines || store.page == .remote) { store.page = .machines }
                TopBarButton(symbol: "gauge.with.dots.needle.33percent", help: "Usage (⌘5)", selected: store.page == .usage) { store.page = .usage }
                TopBarButton(symbol: "heart.text.square", help: "Mac Health (⌘6)", badge: store.health.report.leftovers.count,
                             badgeColor: AppAppearance.amber, selected: store.page == .health) { store.page = .health }
                TopBarButton(symbol: "sparkles", help: "New chat (⌘N)", selected: false) { store.newChatPresented = true }
            }
        }
        .sheet(item: $store.cleanupTarget) { request in
            WorktreeCleanupSheet(store: store, request: request)
        }
        .sheet(isPresented: $store.cleanupDetailsPresented) {
            CleanupResultsView(batch: store.cleanupBatch)
        }
        .sheet(isPresented: $store.newChatPresented) { NewChatSheet(store: store) }
        .frame(minWidth: 1000, minHeight: 620)
        .onChange(of: store.page) { _, page in
            if page == .worktrees { store.reconcileSelection(selectFirst: true) }
            if page.showsWorktrees { Task { await store.refreshWorktreesIfDue() } }
        }
        .onChange(of: store.filter) { _, _ in store.reconcileSelection(selectFirst: true) }
        .onChange(of: store.search) { _, _ in store.reconcileSelection() }
        .modifier(AppTheme())
    }
    private var worktrees: some View {
        NavigationSplitView {
            SidebarView(store: store).navigationSplitViewColumnWidth(min: 180, ideal: Layout.sidebar, max: 260)
        } content: {
            WorktreeListView(store: store).background(AppAppearance.background)
                .navigationSplitViewColumnWidth(min: 440, ideal: 650)
        } detail: {
            if store.selectedWorktrees.count > 1 { WorktreeSelectionView(store: store) }
            else if let tree = store.selected { WorktreeDetailView(store: store, tree: tree) }
            else { AppEmptyState("Select a worktree", symbol: "arrow.triangle.branch", detail: "Agent activity and cleanup checks appear here.") }
        }
    }
    private var remote: some View {
        NavigationSplitView {
            RemoteSessionsView(store: store).background(AppAppearance.background)
                .navigationSplitViewColumnWidth(min: 360, ideal: 520)
        } detail: {
            RemoteSessionDetailView(store: store)
        }
    }
}

/// A top-bar icon with an optional count badge; the current page gets a soft circle behind it.
struct TopBarButton: View {
    var symbol: String
    var help: String
    var badge: Int = 0
    var badgeColor: Color = .red
    var selected: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 26)
                    .background(selected ? AppAppearance.raised : .clear, in: Capsule())
                if badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)").font(.system(size: 9, weight: .bold)).monospacedDigit()
                        .foregroundStyle(.white).padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                        .background(badgeColor, in: Capsule())
                        .offset(x: 7, y: -5)
                }
            }
        }
        .help(help).accessibilityLabel(badge > 0 ? "\(help), \(badge)" : help)
    }
}
