// The desktop shell: Home is the landing page; worktrees, usage, Mac health and remote
// sessions open from it, the toolbar's page switcher, or ⌘1–⌘5.
import SwiftUI
import BurroCore

struct ContentView: View {
    @Bindable var store: AppStore
    var notch: NotchController
    var body: some View {
        VStack(spacing: 0) {
            TopBar(store: store, notch: notch)
            Group {
                switch store.page {
                case .home: HomeView(store: store, notch: notch)
                case .today: TodayView(store: store)
                case .worktrees: worktrees
                case .machines: MachinesView(store: store)
                case .usage: UsageDashboardView(usage: store.usage)
                case .health: MacHealthView(health: store.health)
                case .remote: remote
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle(store.page == .home ? "Burro" : store.page.title)
        .toolbar(.hidden, for: .windowToolbar)
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
                .toolbar(removing: .sidebarToggle)
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
