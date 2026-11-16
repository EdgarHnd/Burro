// The Worktrees page drawn from plain values (WorktreeBoardModel) and callbacks, so it can be
// rendered with sample data in tests: the summary strip, the filter chips (including Protected),
// the scope menu (all repositories, one bench or one repository: the store's own scope) and the
// sort menu, the table
// card with one group per repository (header, repository-health line with Run git gc, rows, "Show
// N more"), and the bulk bar shown while rows are ticked. Columns collapse below about 900 pt: the
// chat and changes move under the branch. Nothing here decides safety; the rows carry the cleanup
// decision and the bulk set comes from WorktreeBoard.bulkSet. ⌘⌫ in the bulk bar opens the Move
// to Trash confirmation only while no text field or editor is being edited (WorktreeTrashKey).
import SwiftUI
import BurroCore

struct WorktreeBoardModel {
    var rows: [WorktreeBoardRow]
    var groups: [WorktreeBoardGroup]
    var summary: WorktreeBoardSummary
    var counts: [WorktreeBoardFilter: Int]
    var filter: WorktreeBoardFilter = .all
    var sort: WorktreeBoardSort = .lastActivity
    /// Ticked ids, already pruned to rows that can be ticked.
    var selection: Set<String> = []
    var collapsed: Set<String> = []
    var expanded: Set<String> = []
    var health: [String: RepositoryObjectStats] = [:]
    var gc: [String: WorktreeInsightsStore.GCState] = [:]
    /// Another gc or a cleanup is running.
    var gcUnavailable = false
    var cleaning = false
    var inspected: String?
    var now: Date
    var calendar: Calendar = .current
    /// The store's scope (`.all`, `.repository`, `.bench`) and what the scope menu lists.
    var scope: WorktreeFilter = .all
    var scopeTitle = "All repositories"
    var scopeBenches: [(id: UUID, name: String)] = []
    var scopeRepositories: [(path: String, name: String)] = []
    static let foldLimit = 9

    var bulk: [Worktree] { WorktreeBoard.bulkSet(selection, rows: rows) }
    var selectedRows: [WorktreeBoardRow] { rows.filter { selection.contains($0.id) } }
    var safeIDs: Set<String> { WorktreeBoard.safeIDs(groups.flatMap(\.rows)) }
}

struct WorktreeBoardActions {
    var setFilter: (WorktreeBoardFilter) -> Void = { _ in }
    var setSort: (WorktreeBoardSort) -> Void = { _ in }
    var setScope: (WorktreeFilter) -> Void = { _ in }
    var toggle: (String) -> Void = { _ in }
    var selectSafe: (WorktreeBoardGroup) -> Void = { _ in }
    var selectAllSafe: () -> Void = {}
    var clearSelection: () -> Void = {}
    var toggleCollapsed: (String) -> Void = { _ in }
    var toggleExpanded: (String) -> Void = { _ in }
    var inspect: (Worktree) -> Void = { _ in }
    var openChat: (AgentSession) -> Void = { _ in }
    var askGC: (WorktreeBoardGroup) -> Void = { _ in }
    var dismissGC: (String) -> Void = { _ in }
    var reviewEach: () -> Void = {}
    var moveToTrash: () -> Void = {}
    var review: (Worktree) -> Void = { _ in }
    var reveal: (Worktree) -> Void = { _ in }
    var terminal: (Worktree) -> Void = { _ in }
    var copyPath: (Worktree) -> Void = { _ in }
    var protect: (Worktree) -> Void = { _ in }
}

// MARK: Header

struct WorktreePageHeader: View {
    var title: String
    var scanned: String
    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(AppAppearance.text)
                Text("Nothing is removed while a chat uses it or while it holds uncommitted work. Branches are always kept.")
                    .font(.system(size: 15)).foregroundStyle(AppAppearance.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text(scanned).font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                .help("Worktrees on this Mac. Repositories are read when this page opens or you refresh (⌘R).")
        }
    }
}

// MARK: Summary

struct WorktreeSummaryStrip: View {
    var summary: WorktreeBoardSummary
    /// Rows whose state is "Uncommitted work" (in-use rows with changes are counted as in use here).
    var idleUncommitted: Int
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 36) { numbers; bar.frame(minWidth: 160, maxWidth: .infinity) }
            VStack(alignment: .leading, spacing: 14) { FlowLayout(spacing: 28) { numbers }; bar }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(AppCardSurface())
    }
    @ViewBuilder private var numbers: some View {
        number("\(summary.total)", summary.total == 1 ? "worktree" : "worktrees")
        number("\(summary.safe)", "safe to clean")
        number(WorktreeBoardFormat.bytes(summary.reclaimable), "reclaimable")
            .help(summary.reclaimable == nil ? "Measuring the safe folders…" : "Disk space the safe folders take. It is freed when you empty the Trash.")
        number("\(summary.uncommitted)", "with uncommitted work", color: summary.uncommitted > 0 ? AppAppearance.amber : AppAppearance.text)
    }
    private func number(_ value: String, _ label: String, color: Color = AppAppearance.text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value).font(.system(size: 26, weight: .bold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.system(size: 13)).foregroundStyle(AppAppearance.secondary)
        }.fixedSize().accessibilityElement(children: .combine)
    }
    /// In use, safe, uncommitted (not in use), and the rest, in proportion.
    private var bar: some View {
        let parts: [(Int, Color)] = [(summary.inUse, AppAppearance.green), (summary.safe, AppAppearance.tertiary),
                                     (idleUncommitted, AppAppearance.amber)]
        let rest = max(0, summary.total - parts.map(\.0).reduce(0, +))
        return GeometryReader { proxy in
            let all = parts + [(rest, AppAppearance.raised)]
            let total = max(1, all.map(\.0).reduce(0, +))
            let gaps = CGFloat(max(0, all.filter { $0.0 > 0 }.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(Array(all.enumerated()), id: \.offset) { _, part in
                    if part.0 > 0 {
                        RoundedRectangle(cornerRadius: 3).fill(part.1)
                            .frame(width: max(3, (proxy.size.width - gaps) * CGFloat(part.0) / CGFloat(total)))
                    }
                }
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

// MARK: Filters

struct WorktreeFilterBar: View {
    var model: WorktreeBoardModel
    var actions: WorktreeBoardActions
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            FlowLayout(spacing: 8) {
                ForEach(WorktreeBoardFilter.allCases, id: \.self) { filter in
                    WorktreeFilterChip(title: filter.title, count: model.counts[filter] ?? 0, dot: Self.dot(filter),
                                       pressed: model.filter == filter) { actions.setFilter(filter) }
                }
            }
            Spacer(minLength: 8)
            scopeMenu
            Text("Sort").font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary)
            Menu {
                ForEach(WorktreeBoardSort.allCases, id: \.self) { sort in
                    Button { actions.setSort(sort) } label: {
                        if sort == model.sort { Label(sort.title, systemImage: "checkmark") } else { Text(sort.title) }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(model.sort.title).font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(AppAppearance.text)
                .padding(.horizontal, 10).frame(height: 26)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppAppearance.hairline))
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Sort rows within each repository").accessibilityLabel("Sort by \(model.sort.title)")
        }
    }
    /// All repositories, one bench or one repository (the store's scope, as Home's links set it).
    private var scopeMenu: some View {
        Menu {
            scopeButton("All repositories", .all)
            if !model.scopeBenches.isEmpty {
                Section("Benches") { ForEach(model.scopeBenches, id: \.id) { scopeButton($0.name, .bench($0.id)) } }
            }
            if !model.scopeRepositories.isEmpty {
                Section("Repositories") { ForEach(model.scopeRepositories, id: \.path) { scopeButton($0.name, .repository($0.path)) } }
            }
        } label: {
            HStack(spacing: 5) {
                Text(model.scopeTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(AppAppearance.text)
            .padding(.horizontal, 10).frame(height: 26).frame(maxWidth: 200)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppAppearance.hairline))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Show every repository, one bench or one repository").accessibilityLabel("Showing \(model.scopeTitle)")
    }
    private func scopeButton(_ title: String, _ scope: WorktreeFilter) -> some View {
        Button { actions.setScope(scope) } label: {
            if model.scope == scope { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
    static func dot(_ filter: WorktreeBoardFilter) -> Color? {
        switch filter {
        case .inUse: AppAppearance.green
        case .safe: AppAppearance.tertiary
        case .uncommitted: AppAppearance.amber
        case .all, .untouched, .protected: nil
        }
    }
}

struct WorktreeFilterChip: View {
    var title: String
    var count: Int
    var dot: Color?
    var pressed: Bool
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
                Text(title).font(.system(size: 13, weight: pressed ? .semibold : .medium))
                Text("\(count)").font(.system(size: 13)).monospacedDigit().opacity(0.75)
            }
            .foregroundStyle(pressed ? AppAppearance.background : AppAppearance.secondary)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(pressed ? AppAppearance.text : (hovering ? AppAppearance.hover : .clear)))
            .overlay(Capsule().strokeBorder(pressed ? .clear : AppAppearance.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).fixedSize().onHover { hovering = $0 }
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(pressed ? .isSelected : [])
    }
}

// MARK: Table

/// Shares column widths between the header and every row. Fixed columns keep their width; the
/// rest split what is left by weight, never below their minimum.
struct WorktreeColumnsLayout: SwiftUI.Layout {
    var compact: Bool
    static let spacing: CGFloat = 12
    private var specs: [(fixed: CGFloat?, weight: CGFloat, minimum: CGFloat)] {
        compact ? [(22, 0, 0), (nil, 1, 160), (130, 0, 0), (104, 0, 0), (64, 0, 0)]
            : [(22, 0, 0), (nil, 2.1, 200), (nil, 1.7, 150), (130, 0, 0), (nil, 1.4, 150), (104, 0, 0), (64, 0, 0)]
    }
    private func widths(_ total: CGFloat) -> [CGFloat] {
        let fixed = specs.compactMap(\.fixed).reduce(0, +) + Self.spacing * CGFloat(specs.count - 1)
        let flexible = max(0, total - fixed), weights = specs.map(\.weight).reduce(0, +)
        return specs.map { $0.fixed ?? max($0.minimum, flexible * $0.weight / weights) }
    }
    private var minimumWidth: CGFloat {
        specs.map { $0.fixed ?? $0.minimum }.reduce(0, +) + Self.spacing * CGFloat(specs.count - 1)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimumWidth
        let heights = zip(subviews, widths(width)).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
        return CGSize(width: width, height: heights.max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(bounds.width)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: nil))
            x += width + Self.spacing
        }
    }
}

struct WorktreeTableCard: View {
    var model: WorktreeBoardModel
    var actions: WorktreeBoardActions
    var compact: Bool
    var body: some View {
        VStack(spacing: 0) {
            header
            ForEach(model.groups) { group in
                WorktreeGroupSection(model: model, group: group, actions: actions, compact: compact)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppAppearance.cardRadius, style: .continuous))
        .modifier(AppCardSurface())
    }
    private var header: some View {
        WorktreeColumnsLayout(compact: compact) {
            Color.clear.frame(height: 1)
            label("Branch")
            if !compact { label("Chat") }
            label("State")
            if !compact { label("Changes") }
            label("Last activity").frame(maxWidth: .infinity, alignment: .trailing)
            label("Size").frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 7)
        .accessibilityHidden(true)
    }
    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.9)
            .foregroundStyle(AppAppearance.tertiary).lineLimit(1)
    }
}

struct WorktreeGroupSection: View {
    var model: WorktreeBoardModel
    var group: WorktreeBoardGroup
    var actions: WorktreeBoardActions
    var compact: Bool
    private var collapsed: Bool { model.collapsed.contains(group.id) }
    private var expanded: Bool { model.expanded.contains(group.id) }
    private var selectedHere: Int { group.rows.filter { model.selection.contains($0.id) }.count }
    private var safeHere: [WorktreeBoardRow] { group.rows.filter { $0.kind == .safe && $0.selectable } }
    var body: some View {
        VStack(spacing: 0) {
            header
            if !collapsed {
                if let stats = model.health[group.repositoryPath], stats.needsAttention || model.gc[group.repositoryPath] != nil {
                    health(stats)
                } else if model.gc[group.repositoryPath] != nil {
                    health(nil)
                }
                let shown = expanded ? group.rows : Array(group.rows.prefix(WorktreeBoardModel.foldLimit))
                ForEach(shown) { row in
                    WorktreeRowView(row: row, selected: model.selection.contains(row.id), inspected: model.inspected == row.id,
                                    now: model.now, calendar: model.calendar, compact: compact, cleaning: model.cleaning, actions: actions)
                }
                if group.rows.count > WorktreeBoardModel.foldLimit {
                    HStack {
                        Button(expanded ? "Show fewer" : "Show \(group.rows.count - WorktreeBoardModel.foldLimit) more in \(group.name)") {
                            actions.toggleExpanded(group.id)
                        }
                        .buttonStyle(.link).font(.system(size: 13)).foregroundStyle(AppAppearance.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .overlay(alignment: .top) { divider }
                }
            }
        }
    }
    private var divider: some View { Rectangle().fill(AppAppearance.separator).frame(height: 1) }
    private var header: some View {
        HStack(spacing: 10) {
            Button { actions.toggleCollapsed(group.id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppAppearance.tertiary).rotationEffect(.degrees(collapsed ? 0 : 90))
                    Text(group.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppAppearance.text).lineLimit(1)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(collapsed ? "Expand \(group.name)" : "Collapse \(group.name)")
            .accessibilityLabel(group.name).accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            Text(headerDetail).font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if collapsed {
                Button("Expand") { actions.toggleCollapsed(group.id) }
            } else {
                Button("Select safe ones") { actions.selectSafe(group) }
                    .disabled(safeHere.isEmpty || model.cleaning)
                    .help(safeHere.isEmpty ? "Nothing here is safe to clean" : "Tick the \(safeHere.count) safe worktree\(safeHere.count == 1 ? "" : "s") in \(group.name)")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(AppAppearance.background.opacity(0.55))
        .overlay(alignment: .top) { divider }
    }
    private var headerDetail: String {
        var parts = ["\(group.total) worktree\(group.total == 1 ? "" : "s")", "\(group.safe) safe"]
        if group.safe > 0, let bytes = group.reclaimable { parts.append(WorktreeBoardFormat.bytes(bytes) + " reclaimable") }
        if group.rows.count != group.total { parts.append("\(group.rows.count) shown") }
        if selectedHere > 0 { parts.append("\(selectedHere) selected") }
        return parts.joined(separator: " · ")
    }
    @ViewBuilder private func health(_ stats: RepositoryObjectStats?) -> some View {
        let state = model.gc[group.repositoryPath]
        HStack(spacing: 10) {
            switch state {
            case .running(let started):
                ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 14, height: 14)
                Text("Running git gc").foregroundStyle(AppAppearance.text)
                Text("· started \(WorktreeBoardFormat.ago(started, now: model.now, calendar: model.calendar)) · chats can keep working")
                    .foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                Spacer(minLength: 8)
            case .finished(let before, let after):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(AppAppearance.green).accessibilityHidden(true)
                Text("git gc finished").foregroundStyle(AppAppearance.text)
                Text(Self.change(before, after)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                Spacer(minLength: 8)
                dismiss
            case .failed(let message):
                Image(systemName: "exclamationmark.circle").foregroundStyle(AppAppearance.amber).accessibilityHidden(true)
                Text("git gc stopped").foregroundStyle(AppAppearance.text)
                Text(message).foregroundStyle(AppAppearance.tertiary).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 8)
                dismiss
            case nil:
                Circle().fill(AppAppearance.amber).frame(width: 8, height: 8).accessibilityHidden(true)
                Text("Repository health").foregroundStyle(AppAppearance.secondary)
                Text(stats?.summary ?? "").foregroundStyle(AppAppearance.text)
                if !compact {
                    Text("· status and diff are slow in every worktree").foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { actions.askGC(group) } label: { Label("Run git gc", systemImage: "terminal") }
                    .disabled(model.gcUnavailable)
                    .help(model.gcUnavailable ? "Wait for the running cleanup or git gc to finish" : "Repack this repository's objects (asks first)")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(AppAppearance.background.opacity(0.55))
        .overlay(alignment: .top) { divider }
        .accessibilityElement(children: .contain)
    }
    private var dismiss: some View {
        Button { actions.dismissGC(group.repositoryPath) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
            .buttonStyle(.plain).foregroundStyle(AppAppearance.tertiary)
            .help("Dismiss").accessibilityLabel("Dismiss git gc result")
    }
    static func change(_ before: RepositoryObjectStats?, _ after: RepositoryObjectStats?) -> String {
        guard let after else { return "" }
        guard let before else { return "· now " + after.summary }
        return "· \(before.packs) → \(after.packs) packs, \(WorktreeBoardFormat.compact(before.loose)) → \(WorktreeBoardFormat.compact(after.loose)) loose objects"
    }
}

struct WorktreeRowView: View {
    var row: WorktreeBoardRow
    var selected: Bool
    var inspected: Bool
    var now: Date
    var calendar: Calendar
    var compact: Bool
    var cleaning: Bool
    var actions: WorktreeBoardActions
    @State private var hovering = false
    private var tree: Worktree { row.tree }
    var body: some View {
        WorktreeColumnsLayout(compact: compact) {
            checkbox
            branch
            if !compact { chat }
            WorktreeStateChip(row: row)
            if !compact { changes }
            Text(WorktreeBoardFormat.ago(row.lastActivity, now: now, calendar: calendar))
                .font(.system(size: 13)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(WorktreeBoardFormat.bytes(row.size)).font(.system(size: 13)).monospacedDigit()
                .foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(row.size == nil ? "Not measured yet" : "Disk space this folder takes")
        }
        .padding(.horizontal, 16).padding(.vertical, compact ? 8 : 9)
        .background(selected || inspected ? AppAppearance.hover : (hovering ? AppAppearance.hover.opacity(0.6) : .clear))
        .overlay(alignment: .top) { Rectangle().fill(AppAppearance.separator).frame(height: 1) }
        .overlay(alignment: .leading) { if inspected { Rectangle().fill(AppAppearance.text.opacity(0.5)).frame(width: 2) } }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
    }
    private var checkbox: some View {
        Toggle("", isOn: Binding(get: { selected }, set: { _ in actions.toggle(row.id) }))
            .toggleStyle(.checkbox).labelsHidden()
            .tint(AppAppearance.amber)
            .disabled(!row.selectable || cleaning)
            .help(row.selectionBlocker ?? (row.eligibility.allowed ? "Select for Move to Trash" : "Select to review its blockers; it will not be moved"))
            .accessibilityLabel("Select worktree \(tree.branch) in \(tree.repository)")
    }
    private var branch: some View {
        Button { actions.inspect(tree) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if tree.isPrimary { Image(systemName: "house").font(.system(size: 10)).foregroundStyle(AppAppearance.tertiary) }
                    Text(tree.branch).font(.system(size: 12, design: .monospaced)).foregroundStyle(AppAppearance.text)
                        .lineLimit(1).truncationMode(.middle)
                    if tree.protectedByUser { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(AppAppearance.tertiary) }
                }
                if compact {
                    let changes = row.changes
                    Text([row.linkedChat?.title, changes.text].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(changes.attention ? AppAppearance.amber : AppAppearance.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tree.path)
        .accessibilityLabel("\(tree.branch), \(row.stateTitle)")
        .accessibilityHint("Shows this worktree's details")
    }
    @ViewBuilder private var chat: some View {
        if let session = row.linkedChat {
            Button { actions.openChat(session) } label: {
                Text(session.title.isEmpty ? "Untitled chat" : session.title).font(.system(size: 13))
                    .foregroundStyle(session.state.keepsWorktree ? AppAppearance.text : AppAppearance.secondary)
                    .underline(hovering).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Open this chat in Burro")
        } else {
            Text("No chat seen").font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var changes: some View {
        let changes = row.changes
        return Text(changes.text).font(.system(size: 13))
            .foregroundStyle(changes.attention ? AppAppearance.amber : AppAppearance.secondary)
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(tree.facts.integrationSummary)
    }
    @ViewBuilder private var menu: some View {
        Button("Show details") { actions.inspect(tree) }
        Button("Reveal in Finder") { actions.reveal(tree) }.disabled(tree.isMissing)
        Button("Open in Terminal") { actions.terminal(tree) }.disabled(tree.isMissing)
        Button("Copy Path") { actions.copyPath(tree) }
        Divider()
        Button(tree.protectedByUser ? "Remove Protection" : "Protect Worktree") { actions.protect(tree) }.disabled(cleaning)
        Button(row.eligibility.allowed ? "Move to Trash…" : "Show blockers…") { actions.review(tree) }.disabled(cleaning)
    }
}

struct WorktreeStateChip: View {
    var row: WorktreeBoardRow
    var body: some View {
        let (fore, back) = colors
        Text(row.stateTitle).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            .foregroundStyle(fore)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(back, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                if row.kind == .blocked { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(AppAppearance.hairline) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(row.eligibility.reasons.joined(separator: "\n"))
            .accessibilityLabel("State: \(row.stateTitle)")
    }
    private var colors: (Color, Color) {
        switch row.kind {
        case .inUse: (AppAppearance.green, AppAppearance.green.opacity(0.14))
        case .safe: (AppAppearance.secondary, AppAppearance.raised)
        case .uncommitted: (AppAppearance.amber, AppAppearance.amber.opacity(0.14))
        case .blocked: (AppAppearance.secondary, .clear)
        }
    }
}

// MARK: Bulk bar

/// Shown while rows are ticked. "Move to Trash…" hands only the bulk set (safe rows) to the
/// existing confirmation sheet, which checks each again.
struct WorktreeBulkBar: View {
    var model: WorktreeBoardModel
    var actions: WorktreeBoardActions
    var body: some View {
        let bulk = model.bulk, selected = model.selectedRows
        let blocked = selected.count - bulk.count
        let allSafeTicked = !model.safeIDs.isEmpty && model.safeIDs.isSubset(of: model.selection)
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { allSafeTicked }, set: { $0 ? actions.selectAllSafe() : actions.clearSelection() }))
                .toggleStyle(.checkbox).labelsHidden().tint(AppAppearance.amber)
                .disabled(model.cleaning)
                .help(allSafeTicked ? "Clear the selection" : "Select every safe worktree shown")
                .accessibilityLabel("Select all safe to clean")
            Text("\(selected.count) selected").font(.system(size: 13, weight: .semibold))
            Text(detail(bulk: bulk, blocked: blocked)).font(.system(size: 13))
                .foregroundStyle(blocked > 0 ? AppAppearance.amber : AppAppearance.secondary).lineLimit(1).truncationMode(.tail)
            Button("Clear") { actions.clearSelection() }.buttonStyle(.link).font(.system(size: 13)).foregroundStyle(AppAppearance.secondary)
            Spacer(minLength: 8)
            Button("Review each") { actions.reviewEach() }
                .help("Step through the selected worktrees' details")
            Button { actions.moveToTrash() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash").font(.system(size: 12, weight: .semibold))
                    Text(bulk.count == selected.count ? "Move to Trash…" : "Move \(bulk.count) to Trash…")
                    Text("⌘⌫").font(.system(size: 11, design: .monospaced)).opacity(0.7)
                }
            }
            .buttonStyle(WorktreePrimaryButtonStyle())
            .disabled(bulk.isEmpty || model.cleaning)
            .help(bulk.isEmpty ? "None of the selected worktrees is safe to clean"
                  : "Review and confirm moving \(bulk.count) folder\(bulk.count == 1 ? "" : "s") to Trash (⌘⌫ when you aren't typing in a field)")
            // Not a window-wide key equivalent: ⌘⌫ while editing text stays the field's own.
            .background(WorktreeTrashKey(enabled: !bulk.isEmpty && !model.cleaning, action: actions.moveToTrash))
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppAppearance.raised))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppAppearance.hairline))
        .accessibilityElement(children: .contain)
    }
    private func detail(bulk: [Worktree], blocked: Int) -> String {
        var parts: [String] = []
        let sizes = model.rows.filter { row in bulk.contains { $0.path == row.id } }
        if !bulk.isEmpty, let bytes = WorktreeBoard.total(sizes) { parts.append(WorktreeBoardFormat.bytes(bytes)) }
        if !bulk.isEmpty { parts.append("branches kept, folders go to Trash") }
        if blocked > 0 { parts.append("\(blocked) not safe to clean, will stay") }
        return parts.joined(separator: " · ")
    }
}

/// The page's one amber action.
struct WorktreePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.black.opacity(enabled ? 0.85 : 0.45))
            .padding(.horizontal, 12).frame(height: 28)
            .background(AppAppearance.amber.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
