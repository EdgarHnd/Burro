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
            case .worktrees:
                worktrees.searchable(text: $store.search, placement: .toolbar, prompt: "Branch, repository, or agent")
            case .usage: UsageDashboardView(usage: store.usage)
            case .health: MacHealthView(health: store.health)
            case .remote: remote
            }
        }
        .navigationTitle(store.page == .home ? "Burro" : store.page.title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Page", selection: $store.page) {
                    ForEach(AppPage.allCases) { page in
                        Text(page.title).tag(page).help("\(page.title) (⌘\(page.shortcut.character))")
                    }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityLabel("Page")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if store.page == .worktrees {
                    if store.scanning { ProgressView().controlSize(.small).accessibilityLabel("Refreshing worktrees") }
                    Button { store.filter = .cleanup } label: { Label("Cleanup", systemImage: "trash") }
                        .help("Review inactive worktrees and cleanup blockers")
                    Button { store.addRepository() } label: { Label("Add repository", systemImage: "folder.badge.plus") }
                        .help("Add a repository")
                }
                if store.page == .worktrees || store.page == .remote || store.page == .home {
                    Button { Task { await store.refreshCurrentPage() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Refresh (⌘R)").disabled(store.refreshingCurrentPage)
                }
                Button { notch.show() } label: { Label("Agent notch", systemImage: "rectangle.topthird.inset.filled") }
                    .help("Show agent notch (⇧⌘B)")
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
