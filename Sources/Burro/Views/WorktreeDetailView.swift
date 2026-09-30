// Explain each assessment and expose the exact agents, Git evidence, and local processes.
import SwiftUI
import BurroCore

struct WorktreeDetailView: View {
    var store: AppStore
    var tree: Worktree
    @State private var showHistory = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: Layout.gap) {
                    HStack {
                        Image(systemName: "arrow.triangle.branch").font(.title2).foregroundStyle(.secondary)
                        Spacer()
                        Button { store.protect(tree) } label: {
                            Image(systemName: tree.protectedByUser ? "lock.fill" : "lock.open")
                        }.buttonStyle(.borderless).help(tree.protectedByUser ? "Remove your protection" : "Protect this worktree")
                            .accessibilityLabel(tree.protectedByUser ? "Remove protection" : "Protect worktree")
                    }
                    Text(tree.branch).font(.title3.weight(.semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(tree.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Finder", systemImage: "folder") { store.reveal(tree) }
                        Button("Terminal", systemImage: "terminal") { store.openTerminal(tree) }
                        Button { store.copyPath(tree) } label: { Image(systemName: "doc.on.doc") }.help("Copy path")
                    }.controlSize(.small).disabled(tree.isMissing)
                }
                Divider()
                VStack(alignment: .leading, spacing: Layout.gap) {
                    HStack { sectionLabel("CLEANUP"); Spacer(); SafetyBadge(level: tree.assessment.level) }
                    ForEach(Array(tree.assessment.reasons.enumerated()), id: \.offset) { _, reason in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: tree.assessment.level == .candidate ? "checkmark" : "minus").font(.caption).foregroundStyle(tree.assessment.level.color).frame(width: 12)
                            Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if tree.assessment.level != .candidate {
                        Text("Inactive does not mean disposable.").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Divider()
                agents
                Divider()
                VStack(alignment: .leading, spacing: Layout.gap) {
                    sectionLabel("GIT STATUS")
                    fact("Tracked changes", "\(tree.facts.changed)")
                    fact("Untracked", "\(tree.facts.untracked)")
                    fact("Ignored", "\(tree.facts.ignoredCount)")
                    fact("Unpushed", tree.facts.unpushed.map(String.init) ?? "Unknown")
                    fact("Compared with", tree.facts.base ?? "Unavailable")
                    fact("HEAD", String(tree.head.prefix(9)))
                    if let commit = tree.facts.lastCommit { HStack { Text("Last commit"); Spacer(); Text(commit, style: .relative) }.font(.caption).foregroundStyle(.secondary) }
                    if !tree.facts.ignored.isEmpty {
                        DisclosureGroup("Ignored data") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(tree.facts.ignored, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                                if tree.facts.ignoredCount > tree.facts.ignored.count { Text("More entries not shown").font(.caption).foregroundStyle(.tertiary) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !tree.processes.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: Layout.gap) {
                        sectionLabel("LOCAL PROCESSES")
                        ForEach(tree.processes, id: \.pid) { process in fact(process.name, "PID \(process.pid)") }
                    }
                }
                Text("A local snapshot, not a deletion guarantee. The notch can remove local merged worktrees after confirmation and a fresh safety check. Origin refs refresh periodically; agent settings remain unchanged.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }.padding(Layout.inset)
        }.frame(minWidth: 280, idealWidth: Layout.inspector)
        .onChange(of: tree.id) { _, _ in showHistory = false }
    }
    private var agents: some View {
        let live = tree.agents.filter { $0.state.keepsWorktree }
        let historical = tree.agents.filter { !$0.state.keepsWorktree }
        return VStack(alignment: .leading, spacing: Layout.gap) {
            HStack { sectionLabel("AGENTS"); Spacer(); Text("\(live.count) open").font(.caption).foregroundStyle(.secondary) }
            if live.isEmpty { Text("No live agent sessions detected").font(.callout).foregroundStyle(.secondary) }
            ForEach(live) { session in AgentRow(session: session) }
            if !historical.isEmpty {
                DisclosureGroup("Recent history (\(historical.count))", isExpanded: $showHistory) {
                    VStack(alignment: .leading, spacing: Layout.gap) {
                        ForEach(historical.prefix(10)) { session in AgentRow(session: session) }
                        if historical.count > 10 { Text("Showing 10 most recent chats").font(.caption2).foregroundStyle(.tertiary) }
                    }.padding(.top, Layout.gap)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func sectionLabel(_ label: String) -> some View { Text(label).font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(.secondary) }
    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).textSelection(.enabled).multilineTextAlignment(.trailing) }.font(.caption)
    }
}
struct AgentRow: View {
    let session: AgentSession
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(session.provider.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.primary)
                if session.pinned { Image(systemName: "pin.fill").font(.caption2) }
                Spacer()
                Text(session.state.rawValue).font(.caption2).foregroundStyle(session.state.color)
            }
            Text(session.title).font(.callout).lineLimit(2).foregroundStyle(.primary).help(session.title)
            HStack {
                Text(session.updatedAt, style: .relative)
                if let pid = session.pid { Text("· PID \(pid)") }
            }.font(.caption2).foregroundStyle(.tertiary)
        }.help(session.evidence)
    }
}
