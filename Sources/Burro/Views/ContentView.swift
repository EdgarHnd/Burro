// Source-list navigation gives worktree evidence and account usage their own desktop layouts.
import SwiftUI
import BurroCore

struct ContentView: View {
    @Bindable var store: AppStore
    var notch: NotchController
    var body: some View {
        Group {
            if store.filter == .usage {
                NavigationSplitView {
                    sidebar
                } detail: {
                    UsageDashboardView(usage: store.usage)
                }
            } else {
                workspace
                    .searchable(text: $store.search, placement: .toolbar, prompt: "Branch, repository, or agent")
            }
        }
        .navigationTitle("Burro")
        .navigationSubtitle(store.filter == .usage ? "Accounts & usage" : "Worktrees & agents")
        .toolbar {
            ToolbarItemGroup {
                Button { notch.show() } label: { Label("Agent notch", systemImage: "rectangle.topthird.inset.filled") }
                    .help("Show agent notch (⇧⌘B)")
                if store.filter != .usage {
                    if store.scanning { ProgressView().controlSize(.small).accessibilityLabel("Refreshing worktrees") }
                    Button { Task { await store.refreshRemotes(); await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Refresh worktrees (⌘R)").disabled(store.scanning)
                    Button { store.filter = .cleanup } label: { Label("Cleanup", systemImage: "trash") }
                        .help("Review inactive worktrees and cleanup blockers")
                    Button { store.addRepository() } label: { Label("Add repository", systemImage: "folder.badge.plus") }
                        .help("Add a repository")
                }
            }
        }
        .sheet(item: $store.cleanupTarget) { request in
            WorktreeCleanupSheet(store: store, request: request)
        }
        .sheet(isPresented: $store.cleanupDetailsPresented) {
            CleanupResultsView(batch: store.cleanupBatch)
        }
        .frame(minWidth: 1000, minHeight: 590)
        .onChange(of: store.filter) { _, filter in
            if filter != .usage { store.reconcileSelection(selectFirst: true) }
        }
        .onChange(of: store.search) { _, _ in store.reconcileSelection() }
        .modifier(AppTheme())
    }
    private var sidebar: some View {
        SidebarView(store: store).navigationSplitViewColumnWidth(min: 180, ideal: Layout.sidebar, max: 260)
    }
    private var workspace: some View {
        NavigationSplitView {
            sidebar
        } content: {
            Group {
                if store.filter == .remote { RemoteSessionsView(store: store) }
                else { WorktreeListView(store: store) }
            }.background(AppAppearance.background).navigationSplitViewColumnWidth(min: 440, ideal: 650)
        } detail: {
            if store.filter == .remote { RemoteSessionDetailView(store: store) }
            else if store.selectedWorktrees.count > 1 { WorktreeSelectionView(store: store) }
            else if let tree = store.selected { WorktreeDetailView(store: store, tree: tree) }
            else { AppEmptyState("Select a worktree", symbol: "arrow.triangle.branch", detail: "Agent activity and cleanup checks appear here.") }
        }
    }
}
