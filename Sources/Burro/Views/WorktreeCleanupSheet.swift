// One concise review covers the eligible selection; blocked rows stay in the list.
import SwiftUI
import BurroCore

struct WorktreeCleanupSheet: View {
    var store: AppStore
    let request: CleanupRequest
    private var ready: [Worktree] { request.trees.filter { store.cleanupBlocker($0) == nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(ready.isEmpty ? "These worktrees need attention" : "Move \(ready.count == 1 ? "worktree" : "\(ready.count) worktrees") to Trash?",
                  systemImage: ready.isEmpty ? "exclamationmark.circle" : "trash").font(AppAppearance.pageTitle)
            Text("Branches and commits stay. The entire folder, including ignored files, moves to Trash.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(request.trees) { tree in
                        let blocker = store.cleanupBlocker(tree)
                        let current = store.availableWorktrees.first { $0.id == tree.id } ?? tree
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: blocker == nil ? "checkmark.circle.fill" : "exclamationmark.circle")
                                .foregroundStyle(blocker == nil ? AppAppearance.green : AppAppearance.amber)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(URL(fileURLWithPath: tree.path).lastPathComponent).font(.headline)
                                Text(tree.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if let blocker {
                                    Text(blocker).font(.callout).foregroundStyle(AppAppearance.amber)
                                    ForEach((current.facts.changedPaths ?? []) + (current.facts.untrackedPaths ?? []), id: \.self) {
                                        Text($0).font(.caption.monospaced()).textSelection(.enabled)
                                    }
                                } else {
                                    Text("Kept branch: " + (current.facts.retainedBranchName ?? current.branch))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.vertical, 4)
            }.frame(maxHeight: 260)
            if request.trees.count > ready.count && !ready.isEmpty {
                Text("\(request.trees.count - ready.count) unavailable worktree(s) will be skipped.").font(.callout).foregroundStyle(AppAppearance.amber)
            }
            Text("Burro rechecks each checkout in the background. Anything that fails stays visible with its reason.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(ready.isEmpty ? "Close" : "Cancel") { store.cleanupTarget = nil }.keyboardShortcut(.cancelAction)
                if !ready.isEmpty {
                    Button(ready.count == 1 ? "Move to Trash" : "Move \(ready.count) to Trash", role: .destructive) {
                        store.confirmCleanup(request)
                    }.keyboardShortcut(.defaultAction).disabled(store.cleaningWorktree)
                }
            }
        }.padding(24).frame(width: 510).modifier(AppTheme())
    }
}
