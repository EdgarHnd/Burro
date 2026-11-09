// The chat page's side panel, like the Claude app's: where the chat works, which model and effort,
// how full its context is, what it has changed, and subagents still running. Changes come from a
// read-only `git diff --shortstat` against where the branch left its base, on this Mac only.
import SwiftUI
import BurroCore

struct ChatInspector: View {
    var store: AppStore
    var session: AgentSession
    var transcript: ChatTranscript?
    @State private var diff: DiffStat?
    @State private var diffChecked = false

    struct DiffStat: Equatable, Sendable {
        var files = 0, added = 0, removed = 0
    }

    var body: some View {
        let tree = worktree
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                row("Folder") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(URL(fileURLWithPath: transcript?.folder ?? session.cwd).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        if let tree, !tree.branch.isEmpty { Text(tree.branch).font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).lineLimit(1) }
                    }
                    .help(transcript?.folder ?? session.cwd)
                }
                row("Machine") { Text(session.remote?.hostName ?? "This Mac").lineLimit(1) }
                row("Model") {
                    Text([AquariumFish.modelName(session.model) ?? (session.provider == .codex ? "Codex" : "Claude Code"),
                          session.effort.map(Self.effortTitle)].compactMap { $0 }.joined(separator: " · ")).lineLimit(1)
                }
                if let tokens = transcript?.contextTokens, tokens > 0 { contextRow(tokens: tokens, window: transcript?.contextWindow) }
                changesRow(tree)
                if let started = session.startedAt { row("Started") { Text(started, style: .relative) + Text(" ago") } }
                let tasks = runningTasks
                if !tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Background tasks").font(.system(size: 12.5, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                        ForEach(tasks) { task in
                            HStack(spacing: 8) {
                                Image(systemName: "person.2").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
                                Text(task.note ?? task.text).font(.system(size: 12.5)).lineLimit(2)
                                Spacer(minLength: 4)
                                if let at = task.at {
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        Text(Self.duration(context.date.timeIntervalSince(at))).font(.system(size: 11.5)).monospacedDigit()
                                            .foregroundStyle(AppAppearance.tertiary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                }
            }
        }
        .frame(width: 270)
        .background(AppAppearance.surface.opacity(0.35))
        .overlay(alignment: .leading) { Rectangle().fill(AppAppearance.separator).frame(width: 1) }
        // Again as the chat writes, at most once a minute.
        .task(id: "\(session.cwd)|\(Int((transcript?.modified?.timeIntervalSince1970 ?? 0) / 60))") { await loadDiff(tree) }
        .onChange(of: session.id) { _, _ in diff = nil; diffChecked = false }
    }

    /// The scanned worktree holding this chat's folder (the deepest match), on this Mac.
    private var worktree: Worktree? {
        guard session.remote == nil else { return nil }
        let folder = transcript?.folder ?? session.cwd
        return store.availableWorktrees.filter { folder == $0.path || folder.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
    }

    /// Subagents it started that haven't reported back, while it works.
    private var runningTasks: [ChatMessage] {
        guard session.state == .working || session.state == .waiting, let messages = transcript?.messages else { return [] }
        return messages.filter { $0.kind == .tool && StepKind($0) == .delegated && $0.output == nil }.suffix(6)
    }

    private func row<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                Spacer(minLength: 8)
                value().font(.system(size: 12.5)).foregroundStyle(AppAppearance.text).multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
            Rectangle().fill(AppAppearance.separator).frame(height: 1).padding(.horizontal, 18)
        }
    }

    private func contextRow(tokens: Int, window: Int?) -> some View {
        row("Context") {
            HStack(spacing: 8) {
                if let window, window > 0 {
                    let share = min(1, Double(tokens) / Double(window))
                    Text("\(Int((share * 100).rounded()))%").monospacedDigit()
                    Capsule().fill(AppAppearance.raised).frame(width: 46, height: 5)
                        .overlay(alignment: .leading) {
                            Capsule().fill(share > 0.8 ? AppAppearance.amber : AppAppearance.blue).frame(width: max(4, 46 * share), height: 5)
                        }
                        .help("\(HomeFormat.tokens(Double(tokens))) of \(HomeFormat.tokens(Double(window))) tokens")
                } else {
                    Text("\(HomeFormat.tokens(Double(tokens))) tokens").monospacedDigit()
                }
            }
        }
    }

    private func changesRow(_ tree: Worktree?) -> some View {
        row("Changes") {
            VStack(alignment: .trailing, spacing: 3) {
                if let diff, diff.files > 0 {
                    HStack(spacing: 6) {
                        Text("+\(diff.added.formatted())").foregroundStyle(AppAppearance.green)
                        Text("−\(diff.removed.formatted())").foregroundStyle(Color(red: 0.92, green: 0.36, blue: 0.36))
                    }
                    .monospacedDigit()
                    Text("\(diff.files) file\(diff.files == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
                } else if session.remote != nil {
                    Text("On \(session.remote?.hostName ?? "another machine")").foregroundStyle(AppAppearance.tertiary)
                } else {
                    Text(diff == nil && !diffChecked ? "…" : (diff == nil ? "Not a Git folder" : "None")).foregroundStyle(AppAppearance.tertiary)
                }
                if let facts = tree?.facts {
                    let pending = [facts.changed + facts.untracked > 0 ? "\(facts.changed + facts.untracked) uncommitted" : nil,
                                   (facts.unpushed ?? 0) > 0 ? "\(facts.unpushed ?? 0) unpushed" : nil].compactMap { $0 }
                    if !pending.isEmpty {
                        Text(pending.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
                    }
                }
            }
        }
    }

    private func loadDiff(_ tree: Worktree?) async {
        // A scanned worktree, or any local folder (a main checkout isn't always in the scan).
        guard session.remote == nil else { diff = nil; diffChecked = true; return }
        let path = tree?.path ?? transcript?.folder ?? session.cwd, base = tree?.facts.base
        diff = await Task.detached(priority: .utility) { Self.diffStat(path: path, base: base) }.value
        diffChecked = true
    }

    /// Lines changed since the branch left its base (committed or not), read-only. The base is the
    /// scan's, or found the way the scan finds it (origin's HEAD, then origin/main, master, staging).
    nonisolated static func diffStat(path: String, base: String?) -> DiffStat? {
        let git = CommandRunner()
        guard git.git(path, ["rev-parse", "--is-inside-work-tree"], timeout: 3).succeeded else { return nil }
        let base = (base?.isEmpty == false ? base : nil) ?? GitReader().comparisonBase(path, override: nil)
        var against = "HEAD"
        if let base, !base.isEmpty, !base.hasPrefix("-") {
            let merge = git.git(path, ["merge-base", base, "HEAD"], timeout: 5)
            let commit = merge.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if merge.succeeded, commit.allSatisfy(\.isHexDigit), commit.count >= 7 { against = commit }
        }
        let result = git.git(path, ["diff", "--shortstat", against], timeout: 8)
        guard result.succeeded else { return nil }
        return parseShortstat(result.output)
    }

    /// " 12 files changed, 420 insertions(+), 33 deletions(-)"
    nonisolated static func parseShortstat(_ text: String) -> DiffStat {
        var stat = DiffStat()
        for part in text.split(separator: ",") {
            let words = part.split(separator: " ")
            guard let number = words.first.flatMap({ Int($0) }) else { continue }
            if part.contains("file") { stat.files = number } else if part.contains("insertion") { stat.added = number } else if part.contains("deletion") { stat.removed = number }
        }
        return stat
    }

    static func effortTitle(_ value: String) -> String {
        switch value {
        case "xhigh": "Extra High"
        case "max": "Max"
        default: value.prefix(1).uppercased() + value.dropFirst()
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }
}
