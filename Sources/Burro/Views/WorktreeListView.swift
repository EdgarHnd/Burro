// Keep the overview scannable; detailed evidence belongs in the inspector.
import SwiftUI
import BurroCore

struct WorktreeListView: View {
    @Bindable var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Layout.inset) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.title2.weight(.semibold))
                    Spacer()
                    Text("\(store.visibleWorktrees.count) worktrees").font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 28) {
                    metric("Working", value: metricWorktrees.filter(\.isWorking).count, color: .green)
                    metric("In use", value: metricWorktrees.filter(\.isInUse).count, color: .primary)
                    metric("Inactive", value: metricWorktrees.filter { !$0.isInUse }.count, color: .secondary)
                    metric("Ready to remove", value: metricWorktrees.filter { store.cleanupEligibility($0).allowed }.count, color: .green)
                }
            }.padding(Layout.inset)
            if store.filter == .cleanup || store.filter == .candidates {
                Text("Remove unused folders while keeping their branches. Local changes and active chats need attention first.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Layout.inset).padding(.bottom, Layout.gap)
            }
            Divider()
            if !store.didScan {
                skeleton
            } else if store.visibleWorktrees.isEmpty {
                ContentUnavailableView {
                    Label(store.snapshot.worktrees.isEmpty ? "Add your first repository" : "No matching worktrees", systemImage: "arrow.triangle.branch")
                } description: {
                    Text(store.snapshot.worktrees.isEmpty ? "Burro discovers local Codex and Claude workspaces. You can also choose a repository." : "Try another filter or search.")
                } actions: {
                    if store.snapshot.worktrees.isEmpty { Button("Add repository…") { store.addRepository() } }
                }
            } else {
                Table(store.visibleWorktrees, selection: $store.selection) {
                    TableColumn("Worktree") { tree in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Image(systemName: tree.isPrimary ? "house" : "arrow.triangle.branch").foregroundStyle(.secondary)
                                Text(URL(fileURLWithPath: tree.path).lastPathComponent).font(.body.weight(.medium)).lineLimit(1)
                                if tree.protectedByUser { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                            }
                            Text("Branch: " + tree.branch)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }.padding(.vertical, 7).help(tree.path)
                    }.width(min: 180, ideal: 280)
                    TableColumn("Activity") { tree in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Circle().fill(tree.isWorking ? Color.green : (tree.isInUse ? Color.blue : Color.secondary.opacity(0.4))).frame(width: 5, height: 5)
                                Text(tree.activity).font(.caption.weight(.medium))
                            }
                            let providers = Set(tree.agents.filter { $0.state.keepsWorktree }.map { $0.provider == .codex ? "Codex" : "Claude" }).sorted()
                            Text(providers.isEmpty ? (tree.processes.isEmpty ? "No live sessions" : "Local processes") : providers.joined(separator: " + "))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.width(min: 100, ideal: 115, max: 150)
                    TableColumn("Cleanup") { tree in
                        VStack(alignment: .leading, spacing: 4) {
                            CleanupBadge(status: store.cleanupEligibility(tree).status)
                            Text(store.cleanupEligibility(tree).allowed ? tree.facts.integrationSummary : store.cleanupEligibility(tree).summary)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }.help(store.cleanupEligibility(tree).reasons.joined(separator: "\n") + "\n" + tree.facts.integrationSummary)
                    }.width(min: 155, ideal: 190, max: 240)
                }
                .contextMenu(forSelectionType: String.self) { paths in
                    if let path = paths.first, let tree = store.snapshot.worktrees.first(where: { $0.id == path }) {
                        Button("Reveal in Finder") { store.reveal(tree) }
                        Button("Open in Terminal") { store.openTerminal(tree) }
                        Button("Copy Path") { store.copyPath(tree) }
                        Divider()
                        Button(tree.protectedByUser ? "Remove Protection" : "Protect Worktree") { store.protect(tree) }.disabled(store.cleaningWorktree)
                        Button(store.cleanupEligibility(tree).allowed ? "Move to Trash…" : "Show blockers…") { store.selection = tree.id; store.cleanupTarget = tree }
                            .disabled(store.cleaningWorktree)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                if !store.snapshot.warnings.isEmpty {
                    DisclosureGroup("\(store.snapshot.warnings.count) monitoring notice(s)") {
                        ForEach(store.snapshot.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    }.font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Image(systemName: "eye").foregroundStyle(.secondary)
                    Text("Monitoring is read-only · cleanup requires confirmation").foregroundStyle(.secondary)
                    Spacer()
                    if store.didScan { Text(store.snapshot.scannedAt, style: .time).foregroundStyle(.tertiary) }
                }.font(.caption)
            }.padding(.horizontal, Layout.inset).padding(.vertical, Layout.gap)
        }
    }
    private var metricWorktrees: [Worktree] { store.visibleWorktrees }
    private var title: String {
        if case .repository(let path) = store.filter { return URL(fileURLWithPath: path).lastPathComponent }
        return store.filter.title
    }
    private func metric(_ label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)").font(.title2.monospacedDigit().weight(.medium)).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var skeleton: some View {
        VStack(spacing: Layout.inset) {
            ForEach(0..<7) { _ in
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 210, height: 12)
                        RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 145, height: 9)
                    }
                    Spacer()
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 80, height: 12)
                }
            }
            Spacer()
            Text("Reading worktrees and agent sessions…").font(.caption).foregroundStyle(.secondary)
        }.padding(Layout.inset).accessibilityElement(children: .ignore).accessibilityLabel("Loading worktrees and agent sessions")
    }
}
