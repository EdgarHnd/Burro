// Confirmation separates preserving commits from integration into another branch.
import SwiftUI
import BurroCore

struct WorktreeCleanupSheet: View {
    var store: AppStore
    let tree: Worktree
    private var current: Worktree { store.snapshot.worktrees.first { $0.id == tree.id } ?? tree }
    private var eligibility: CleanupEligibility { store.cleanupEligibility(current) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(eligibility.allowed ? "Move worktree to Trash?" : eligibility.status.rawValue,
                  systemImage: eligibility.allowed ? "trash" : eligibility.status.icon).font(.title2.weight(.semibold))
            Text(URL(fileURLWithPath: tree.path).lastPathComponent).font(.headline)
            Text(tree.path).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            LabeledContent("Branch", value: current.branch)
            if let branch = current.facts.retainedBranchName { LabeledContent("Commits stay on", value: branch) }
            Text(current.facts.integrationSummary).font(.callout).foregroundStyle(.secondary)
            if current.branch == "Detached HEAD" {
                Text("Commit: " + current.head).font(.caption.monospaced()).textSelection(.enabled)
            }
            Divider()
            if eligibility.allowed {
                Text("The whole folder will move to Trash and its worktree registration will be removed. No branches or commits will be deleted.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("The branch can still contain unmerged or unpushed work. To continue later, create a new worktree on the retained branch.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("All folder contents, including \(current.facts.ignoredCount) ignored files or folders, stay recoverable until you empty Trash. Copy any needed local files into the new worktree when restoring.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Burro rechecks Git status, commit preservation, chats, processes and protection before moving anything.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(eligibility.reasons, id: \.self) { Text($0).frame(maxWidth: .infinity, alignment: .leading) }
                        ForEach((current.facts.changedPaths ?? []) + (current.facts.untrackedPaths ?? []), id: \.self) {
                            Text($0).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if eligibility.managedByCodex {
                            Text("Archive this checkout from its chat in Codex to preserve its snapshot and attachments.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxHeight: 180)
            }
            HStack {
                if store.cleaningWorktree { ProgressView().controlSize(.small); Text("Rechecking and moving…").font(.caption) }
                Spacer()
                Button(eligibility.allowed ? "Cancel" : "Close") { store.cleanupTarget = nil }
                    .keyboardShortcut(.cancelAction).disabled(store.cleaningWorktree)
                if eligibility.allowed {
                    Button("Move to Trash", role: .destructive) { Task { await store.removeWorktree(tree) } }
                        .disabled(store.cleaningWorktree || store.scanning)
                }
            }
        }.padding(24).frame(width: 500).interactiveDismissDisabled(store.cleaningWorktree)
    }
}
