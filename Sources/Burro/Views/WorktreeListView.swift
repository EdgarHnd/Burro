// The Worktrees page: a header saying what is never removed, a summary strip, filter chips with
// counts and a sort menu, then one table group per repository with checkboxes, the linked chat,
// a state chip, changes, last activity and size. Ticking rows shows a bulk bar whose "Move to
// Trash…" opens the existing confirmation (WorktreeCleanupSheet via AppStore.reviewCleanup) with
// only the rows cleanup eligibility allows; that sheet, AppStore.confirmCleanup and
// WorktreeCleanup.remove each check them again, so bulk is never weaker than one at a time.
// A row's branch opens its details (WorktreeDetailView) in an inspector; "Review each" steps
// through the ticked rows there. Sizes and repository health are measured by WorktreeInsightsStore
// only while this page is on screen; "Run git gc" asks first and never runs by itself.
// Home's repository and bench links (store.filter) scope the page, as does the scope menu beside
// the sort menu (All repositories, a bench, a repository); the top bar's search filters it. Other
// pages' status filters become this page's chips (Protected included).
import AppKit
import SwiftUI
import BurroCore

struct WorktreeListView: View {
    @Bindable var store: AppStore
    @State private var filter: WorktreeBoardFilter = .all
    @State private var sort: WorktreeBoardSort = .lastActivity
    @State private var checked: Set<String> = []
    @State private var collapsed: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var inspected: String?
    @State private var reviewQueue: [String] = []
    @State private var gcTarget: WorktreeBoardGroup?
    @State private var onScreen = false
    @State private var width: CGFloat = 1200
    private var insights: WorktreeInsightsStore { store.worktreeInsights }

    var body: some View {
        let model = makeModel()
        ScrollView {
            content(model).padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 28)
                .frame(maxWidth: 1280).frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.selection.isEmpty {
                WorktreeBulkBar(model: model, actions: actions(model))
                    .padding(.horizontal, 28).padding(.bottom, 14)
                    .frame(maxWidth: 1280).frame(maxWidth: .infinity)
            }
        }
        .background(AppAppearance.background)
        .onDeleteCommand { moveToTrash(model) }
        .inspector(isPresented: Binding(get: { inspectedTree != nil }, set: { if !$0 { closeInspector() } })) {
            inspector.inspectorColumnWidth(min: 300, ideal: 340, max: 480)
        }
        .confirmationDialog(gcTarget.map { "Run git gc on \($0.name)?" } ?? "", isPresented: Binding(
            get: { gcTarget != nil }, set: { if !$0 { gcTarget = nil } }), titleVisibility: .visible, presenting: gcTarget) { group in
            Button("Run git gc") { insights.runGC(repository: group.repositoryPath); gcTarget = nil }
            Button("Cancel", role: .cancel) { gcTarget = nil }
        } message: { _ in
            Text("Git repacks this repository's objects in the background so status and diff are fast again in every worktree. It can take several minutes and use a lot of CPU; chats can keep working. Unreachable objects, reflogs and worktree registrations are all kept, so nothing that can be recovered now is lost.")
        }
        .background(WindowOcclusionReader { onScreen = $0 })
        .task(id: MeasureKey(onScreen: onScreen, scannedAt: store.snapshot.scannedAt, count: store.availableWorktrees.count)) {
            guard onScreen, store.didScan else { return }
            while !Task.isCancelled {
                let rows = model.rows
                let repositories = Array(Set(rows.map(\.tree.repositoryPath))).sorted()
                let order = rows.filter { $0.kind == .safe } + rows.filter { $0.kind != .safe }
                await insights.measure(repositories: repositories, paths: order.map(\.id))
                try? await Task.sleep(for: .seconds(600))
            }
        }
        .onAppear { adoptStoreFilter(); adoptStoreSelection() }
        .onChange(of: store.filter) { _, _ in adoptStoreFilter() }
        .onChange(of: store.cleaningWorktree) { _, cleaning in
            // Rows sent to cleanup leave the selection, so a failed one comes back unticked.
            if cleaning { checked.subtract(store.cleanupBatch.items.map(\.id)) }
        }
        .onChange(of: store.availableWorktrees.map(\.id)) { _, ids in
            if let inspected, !ids.contains(inspected) { closeInspector() }
        }
    }

    // MARK: Content

    @ViewBuilder private func content(_ model: WorktreeBoardModel) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            if !store.didScan {
                loading
            } else if store.snapshot.worktrees.isEmpty {
                AppEmptyState(title: "Add your first repository", symbol: "arrow.triangle.branch",
                              detail: "Burro finds local Codex and Claude workspaces. You can also choose a repository.") {
                    Button("Add repository…") { store.addRepository() }
                }.frame(minHeight: 320)
            } else {
                WorktreeSummaryStrip(summary: model.summary, idleUncommitted: model.rows.filter { $0.kind == .uncommitted }.count)
                WorktreeFilterBar(model: model, actions: actions(model))
                if let scope { scopeLine(scope) }
                if !store.cleanupBatch.items.isEmpty { CleanupStatusView(store: store) }
                if model.groups.isEmpty {
                    AppEmptyState(title: store.cleaningWorktree ? "Cleanup is running" : "No worktrees match",
                                  symbol: "line.3.horizontal.decrease.circle",
                                  detail: store.cleaningWorktree ? "You can keep browsing while Burro rechecks and moves the selected folders."
                                    : "Try another filter, or clear the search in the top bar.") {
                        if filter != .all { Button("Show all") { filter = .all } }
                    }
                    .frame(minHeight: 220).modifier(AppCardSurface())
                } else {
                    WorktreeTableCard(model: model, actions: actions(model), compact: compact)
                }
                notices
            }
        }
    }

    private var compact: Bool { width - (inspectedTree == nil ? 0 : 340) < 900 }

    private var header: some View { WorktreePageHeader(title: scope?.name ?? "Worktrees", scanned: scanned) }

    private var scanned: String {
        if store.scanning { return "This Mac · scanning…" }
        guard store.didScan else { return "This Mac" }
        return "This Mac · scanned " + WorktreeBoardFormat.ago(store.snapshot.scannedAt, now: Date(), calendar: .current)
    }

    private var loading: some View {
        VStack(spacing: 14) {
            ForEach(0..<6, id: \.self) { _ in
                HStack {
                    RoundedRectangle(cornerRadius: 3).fill(AppAppearance.raised).frame(width: 220, height: 12)
                    Spacer()
                    RoundedRectangle(cornerRadius: 3).fill(AppAppearance.raised).frame(width: 80, height: 12)
                }
            }
            Text("Reading worktrees and agent sessions…").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
        }
        .padding(20).modifier(AppCardSurface())
        .accessibilityElement(children: .ignore).accessibilityLabel("Loading worktrees and agent sessions")
    }

    @ViewBuilder private var notices: some View {
        if !store.snapshot.warnings.isEmpty {
            DisclosureGroup("\(store.snapshot.warnings.count) monitoring notice\(store.snapshot.warnings.count == 1 ? "" : "s") · why some rows say Cannot verify") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.snapshot.warnings, id: \.self) {
                        Text($0).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 6)
            }
            .font(.system(size: 12)).foregroundStyle(AppAppearance.amber)
        }
    }

    // MARK: Scope from Home (a repository or a bench)

    private var scope: (name: String, filter: WorktreeFilter)? {
        switch store.filter {
        case .repository(let path): (URL(fileURLWithPath: path).lastPathComponent, store.filter)
        case .bench(let id): (store.benches.bench(id)?.name ?? "Bench", store.filter)
        default: nil
        }
    }
    private func scopeLine(_ scope: (name: String, filter: WorktreeFilter)) -> some View {
        HStack(spacing: 8) {
            Text("Showing only \(scope.name)").font(.system(size: 13)).foregroundStyle(AppAppearance.secondary)
            Button("Show every repository") { store.filter = .all }.buttonStyle(.link).font(.system(size: 13))
        }
    }
    /// Status filters other pages set (the top bar's cleanup button) become this page's chips.
    private func adoptStoreFilter() {
        switch store.filter {
        case .cleanup, .candidates: filter = .safe; store.filter = .all
        case .inUse, .working: filter = .inUse; store.filter = .all
        case .protected: filter = .protected; store.filter = .all
        case .inactive: filter = .all; store.filter = .all
        case .all, .repository, .bench: break
        }
    }
    /// A link from a chat ("Open worktree") selects one worktree before switching here; show it.
    private func adoptStoreSelection() {
        guard let path = store.selection, path != store.visibleWorktrees.first?.id,
              store.availableWorktrees.contains(where: { $0.id == path }) else { return }
        inspected = path
    }

    // MARK: Model and actions

    private func makeModel() -> WorktreeBoardModel {
        let rows = store.visibleWorktrees.map { tree in
            WorktreeBoardRow(tree: tree, eligibility: store.cleanupEligibility(tree), size: insights.sizes[tree.path])
        }
        let now = Date()
        return WorktreeBoardModel(rows: rows, groups: WorktreeBoard.groups(rows, filter: filter, sort: sort, now: now),
            summary: WorktreeBoard.summary(rows), counts: WorktreeBoard.counts(rows, now: now), filter: filter, sort: sort,
            selection: WorktreeBoard.prune(checked, rows: rows), collapsed: collapsed, expanded: expanded,
            health: insights.health, gc: insights.gc, gcUnavailable: insights.gcRunning || store.cleaningWorktree,
            cleaning: store.cleaningWorktree, inspected: inspected, now: now,
            scope: scope?.filter ?? .all, scopeTitle: scope?.name ?? "All repositories",
            scopeBenches: store.benches.benches.map { (id: $0.id, name: $0.name) },
            scopeRepositories: store.repositoriesFound)
    }

    private func actions(_ model: WorktreeBoardModel) -> WorktreeBoardActions {
        WorktreeBoardActions(
            setFilter: { filter = $0 },
            setSort: { sort = $0 },
            setScope: { scope in checked = []; store.filter = scope },
            toggle: { id in
                guard model.rows.contains(where: { $0.id == id && $0.selectable }) else { return }
                if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
            },
            selectSafe: { group in
                checked.formUnion(WorktreeBoard.safeIDs(group.rows))
                if group.rows.count > WorktreeBoardModel.foldLimit { expanded.insert(group.id) }
                collapsed.remove(group.id)
            },
            selectAllSafe: { checked.formUnion(model.safeIDs) },
            clearSelection: { checked = []; reviewQueue = [] },
            toggleCollapsed: { id in if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) } },
            toggleExpanded: { id in if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } },
            inspect: { tree in reviewQueue = []; inspected = tree.id; store.selection = tree.id },
            openChat: { store.selectAgent($0) },
            askGC: { gcTarget = $0 },
            dismissGC: { insights.dismissGC($0) },
            reviewEach: {
                let ordered = model.groups.flatMap(\.rows).map(\.id).filter { model.selection.contains($0) }
                reviewQueue = ordered; inspected = ordered.first
            },
            moveToTrash: { moveToTrash(model) },
            review: { store.reviewCleanup([$0]) },
            reveal: { store.reveal($0) },
            terminal: { store.openTerminal($0) },
            copyPath: { store.copyPath($0) },
            protect: { store.protect($0) })
    }

    /// Opens the existing confirmation with the bulk set only: rows cleanup eligibility allows.
    private func moveToTrash(_ model: WorktreeBoardModel) {
        let bulk = model.bulk
        guard !bulk.isEmpty, !store.cleaningWorktree else { return }
        store.reviewCleanup(bulk)
    }

    // MARK: Inspector

    private var inspectedTree: Worktree? {
        inspected.flatMap { path in store.availableWorktrees.first { $0.id == path } }
    }
    private func closeInspector() { inspected = nil; reviewQueue = [] }

    @ViewBuilder private var inspector: some View {
        if let tree = inspectedTree {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if let index = reviewQueue.firstIndex(of: tree.id) {
                        Text("Reviewing \(index + 1) of \(reviewQueue.count)").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppAppearance.secondary)
                        Spacer()
                        Button { inspected = reviewQueue[index - 1] } label: { Image(systemName: "chevron.left") }
                            .disabled(index == 0).help("Previous selected worktree").accessibilityLabel("Previous")
                        Button { inspected = reviewQueue[index + 1] } label: { Image(systemName: "chevron.right") }
                            .disabled(index + 1 >= reviewQueue.count).help("Next selected worktree").accessibilityLabel("Next")
                    } else {
                        Text(tree.repository).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppAppearance.secondary)
                        Spacer()
                    }
                    Button { closeInspector() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(AppAppearance.secondary)
                        .help("Close details").accessibilityLabel("Close details")
                }
                .padding(.horizontal, Layout.inset).padding(.vertical, 10)
                Divider()
                WorktreeDetailView(store: store, tree: tree)
            }
            .background(AppAppearance.surface)
        } else {
            AppEmptyState("Select a worktree", symbol: "arrow.triangle.branch", detail: "Agent activity and cleanup checks appear here.")
        }
    }
}

private struct MeasureKey: Equatable {
    var onScreen: Bool
    var scannedAt: Date
    var count: Int
}
