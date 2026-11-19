// The Worktrees page's content in the dashboard layout (Today's), from plain values so snapshot
// tests draw exactly what the app shows: the shared page header (the page title, or the scoped
// repository or bench, with the safety promise and "This Mac · scanned 2 min ago" as its sentence),
// a strip of four numbers (Worktrees with the in use / safe / uncommitted proportion bar under it,
// Safe to clean, Reclaimable, Uncommitted work in amber above zero), then one joined surface holding
// the filter chips, scope and sort menus, the "Showing only …" line, the cleanup progress strip and
// the full-width table (or the "No worktrees match" state), and the monitoring notices below it.
// The first scan shows a skeleton; no repository at all shows "Add your first repository". The bulk
// bar, ⌘⌫, the inspector and git gc's confirmation stay with WorktreeListView, which owns the state.
import SwiftUI
import BurroCore

struct WorktreePageData {
    enum Phase { case scanning, empty, board }
    var phase: Phase
    var title = "Worktrees"
    /// The repository or bench Home scoped the page to.
    var scopeName: String? = nil
    var scanned = "This Mac"
    var model: WorktreeBoardModel
    var compact = false
    var warnings: [String] = []
    /// The cleanup batch has items (its progress strip shows).
    var showsCleanupStatus = false

    /// The full table's column minimums and padding need about 924 points.
    nonisolated static func compact(tableWidth: CGFloat) -> Bool { tableWidth < 924 }
}

struct WorktreePage<Status: View>: View {
    var data: WorktreePageData
    var actions: WorktreeBoardActions
    var addRepository: () -> Void = {}
    var showEveryRepository: () -> Void = {}
    @ViewBuilder var cleanupStatus: () -> Status

    private var model: WorktreeBoardModel { data.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: data.title, inset: 0, eyebrow: data.scopeName == nil ? "This Mac" : "Worktrees",
                       sentence: WorktreeComposition.sentence(scanned: data.scanned), top: 0, bottom: 0) { EmptyView() }
                .help("Worktrees on this Mac. Repositories are read when this page opens or you refresh (⌘R).")
            switch data.phase {
            case .scanning:
                loading
            case .empty:
                JoinedPanels {
                    PanelCell {
                        AppEmptyState(title: "Add your first repository", symbol: "arrow.triangle.branch",
                                      detail: "Burro finds local Codex and Claude workspaces. You can also choose a repository.") {
                            Button("Add repository…", action: addRepository)
                        }.frame(minHeight: 280)
                    }
                }
            case .board:
                StatStrip(cells: cells)
                JoinedPanels {
                    PanelCell(padding: 0) { board }
                }
                notices
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cells: [StatCellData] {
        WorktreeComposition.stats(model.summary, idleUncommitted: idleUncommitted).map { stat in
            var cell = StatCellData(id: stat.id, label: stat.label, value: stat.value, muted: stat.unknown, sub: stat.sub, help: stat.help)
            if stat.warning { cell.valueColor = AppAppearance.amber }
            if stat.id == "total", model.summary.total > 0 {
                cell.footer = AnyView(WorktreeProportionBar(summary: model.summary, idleUncommitted: idleUncommitted))
            }
            return cell
        }
    }

    private var idleUncommitted: Int { model.rows.filter { $0.kind == .uncommitted }.count }

    private var board: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                WorktreeFilterBar(model: model, actions: actions)
                if let scope = data.scopeName {
                    HStack(spacing: 8) {
                        Text("Showing only \(scope)").font(.system(size: 13)).foregroundStyle(AppAppearance.secondary)
                        Button("Show every repository", action: showEveryRepository).buttonStyle(.link).font(.system(size: 13))
                    }
                }
                if data.showsCleanupStatus { cleanupStatus() }
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            if model.groups.isEmpty {
                Rectangle().fill(AppAppearance.separator).frame(height: 1)
                AppEmptyState(title: model.cleaning ? "Cleanup is running" : "No worktrees match",
                              symbol: "line.3.horizontal.decrease.circle",
                              detail: model.cleaning ? "You can keep browsing while Burro rechecks and moves the selected folders."
                                : "Try another filter, or clear the search above the page.") {
                    if model.filter != .all { Button("Show all") { actions.setFilter(.all) } }
                }
                .frame(minHeight: 220)
            } else {
                WorktreeTableCard(model: model, actions: actions, compact: data.compact)
            }
        }
    }

    private var loading: some View {
        JoinedPanels {
            PanelCell {
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
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Loading worktrees and agent sessions")
    }

    @ViewBuilder private var notices: some View {
        if !data.warnings.isEmpty {
            DisclosureGroup("\(data.warnings.count) monitoring notice\(data.warnings.count == 1 ? "" : "s") · why some rows say Cannot verify") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(data.warnings, id: \.self) {
                        Text($0).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 6)
            }
            .font(.system(size: 12)).foregroundStyle(AppAppearance.amber)
        }
    }
}

/// In use, safe, uncommitted (not in use), and the rest, in proportion: the Worktrees cell's footer.
struct WorktreeProportionBar: View {
    var summary: WorktreeBoardSummary
    var idleUncommitted: Int
    var body: some View {
        let parts: [(Int, Color)] = [(summary.inUse, AppAppearance.green), (summary.safe, AppAppearance.tertiary),
                                     (idleUncommitted, AppAppearance.amber)]
        let rest = max(0, summary.total - parts.map(\.0).reduce(0, +))
        GeometryReader { proxy in
            let all = parts + [(rest, AppAppearance.raised)]
            let total = max(1, all.map(\.0).reduce(0, +))
            let gaps = CGFloat(max(0, all.filter { $0.0 > 0 }.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(Array(all.enumerated()), id: \.offset) { _, part in
                    if part.0 > 0 {
                        RoundedRectangle(cornerRadius: 2).fill(part.1)
                            .frame(width: max(3, (proxy.size.width - gaps) * CGFloat(part.0) / CGFloat(total)))
                    }
                }
            }
        }
        .frame(height: 6)
        .help("In use (green), safe to clean (grey), uncommitted work not in use (amber), and the rest")
        .accessibilityHidden(true)
    }
}
