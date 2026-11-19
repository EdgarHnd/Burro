// The desktop window: Home is the landing page; every other page opens from it, the sidebar,
// or ⌘1–⌘8 (Home, Orchestrator, Today, Chats, Worktrees, Machines, Usage, Mac Health). AppShell
// draws the sidebar and the strip above the page; this view picks the page and owns the sheets.
import SwiftUI
import BurroCore

struct ContentView: View {
    @Bindable var store: AppStore
    var notch: NotchController
    var body: some View {
        AppShell(store: store) {
            Group {
                switch store.page {
                case .home: HomeView(store: store, notch: notch)
                case .orchestrator: OrchestratorPage(store: store)
                case .today: TodayView(store: store)
                case .worktrees: worktrees
                case .machines: MachinesView(store: store)
                case .usage: UsageDashboardView(usage: store.usage)
                case .health: MacHealthView(health: store.health, keepAwake: store.keepAwake)
                case .remote: remote
                case .timeline: ShippedTimelineView(store: store)
                }
            }
        }
        .navigationTitle(store.page == .home ? "Burro" : store.page.title)
        .toolbar(.hidden, for: .windowToolbar)
        .sheet(item: $store.cleanupTarget) { request in
            WorktreeCleanupSheet(store: store, request: request)
        }
        .sheet(isPresented: $store.cleanupDetailsPresented) {
            CleanupResultsView(batch: store.cleanupBatch)
        }
        .sheet(isPresented: $store.newChatPresented) { NewChatSheet(store: store) }
        .modifier(CommandPaletteHost(store: store))
        .frame(minWidth: 1000, minHeight: 620)
        .onChange(of: store.page) { _, page in
            if page == .worktrees { store.reconcileSelection(selectFirst: true) }
            if page.showsWorktrees { Task { await store.refreshWorktreesIfDue() } }
        }
        .onChange(of: store.filter) { _, _ in store.reconcileSelection(selectFirst: true) }
        .onChange(of: store.search) { _, _ in store.reconcileSelection() }
        .modifier(AppTheme())
    }
    private var worktrees: some View { WorktreeListView(store: store) }
    private var remote: some View { ChatsView(store: store) }
}
