// Nonmodal progress keeps browsing usable; detailed receipts are opened only on demand.
import AppKit
import SwiftUI
import BurroCore

struct CleanupStatusView: View {
    var store: AppStore
    var body: some View {
        let batch = store.cleanupBatch
        HStack(spacing: 10) {
            if batch.isRunning { ProgressView().controlSize(.small) }
            else { Image(systemName: batch.failedCount > 0 ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(batch.failedCount > 0 ? AppAppearance.amber : AppAppearance.green) }
            VStack(alignment: .leading, spacing: 3) {
                Text(batch.summary).font(.callout.weight(.medium))
                if let current = batch.current {
                    Text(URL(fileURLWithPath: current.tree.path).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if store.cleaningWorktree {
                    Text("Updating the list…").font(.caption).foregroundStyle(.secondary)
                } else if batch.movedCount > 0 {
                    Text("Branches kept · folders recoverable from Trash").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if batch.isRunning && batch.queuedCount > 0 {
                Button("Stop remaining") { batch.stopRemaining() }.controlSize(.small)
            }
            Button("Details") { store.cleanupDetailsPresented = true }.controlSize(.small)
            if !store.cleaningWorktree {
                Button { batch.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).accessibilityLabel("Dismiss cleanup result")
            }
        }.padding(Layout.gap).modifier(AppCardSurface())
            .padding(.horizontal, Layout.gap).padding(.bottom, Layout.gap)
            .accessibilityElement(children: .contain)
    }
}
struct CleanupResultsView: View {
    var batch: CleanupBatchStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cleanup results").font(AppAppearance.pageTitle)
            Text(batch.summary).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(batch.items) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(URL(fileURLWithPath: item.tree.path).lastPathComponent).font(.headline)
                            Text(item.tree.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            switch item.state {
                            case .queued: Text("Queued").foregroundStyle(.secondary)
                            case .moving: Text("Rechecking and moving…").foregroundStyle(.secondary)
                            case .skipped: Text("Skipped · folder left in place").foregroundStyle(.secondary)
                            case .failed(let reason): Text(reason).foregroundStyle(AppAppearance.amber).textSelection(.enabled)
                            case .moved(let destination):
                                Text("Moved to Trash · branch kept").foregroundStyle(AppAppearance.green)
                                Text("Branch: " + (item.tree.facts.retainedBranchName ?? item.tree.branch)).font(.caption).textSelection(.enabled)
                                Text("Commit: " + item.tree.head).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                Text(destination.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                Button("Show in Finder", systemImage: "folder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                                }.controlSize(.small)
                            }
                        }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.frame(maxHeight: 360)
            Text("To restore, create a worktree on the kept branch and copy needed local files from Trash. Emptying Trash is permanent.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 520).modifier(AppTheme())
    }
}
struct WorktreeSelectionView: View {
    var store: AppStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.inset) {
                Label("\(store.selectedWorktrees.count) worktrees selected", systemImage: "square.stack.3d.up")
                    .font(AppAppearance.sectionTitle)
                Text("\(store.selectedReadyCount) ready to remove").foregroundStyle(AppAppearance.green)
                Text("Unavailable worktrees stay in place. Branches and commits are kept.").font(.callout).foregroundStyle(.secondary)
                Button("Move \(store.selectedReadyCount) to Trash…", systemImage: "trash") {
                    store.reviewCleanup(store.selectedWorktrees)
                }.disabled(store.selectedReadyCount == 0 || store.cleaningWorktree)
                Divider()
                ForEach(store.selectedWorktrees) { tree in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(URL(fileURLWithPath: tree.path).lastPathComponent).font(.callout.weight(.medium))
                        CleanupBadge(status: store.cleanupEligibility(tree).status)
                        if !store.cleanupEligibility(tree).allowed {
                            Text(store.cleanupEligibility(tree).summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(Layout.inset)
        }.background(AppAppearance.surface).frame(minWidth: 280, idealWidth: Layout.inspector)
    }
}
