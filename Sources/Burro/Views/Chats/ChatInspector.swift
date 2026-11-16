// The chat page's side panel: where the chat works (the worktree's branch with its uncommitted and
// unpushed counts, Open worktree for Burro's Worktrees page on it and Review cleanup… for the usual
// confirmation sheet), what it has changed file by file, how full its context is, what it has cost
// so far at API list prices, when it started, and subagents still running. Changes come from a
// read-only `git diff --numstat` against where the branch left its base (`ChatChanges`) and cost
// from the chat's transcript (`ChatCost`), both on this Mac only and off the main thread. Both are
// cached per folder / chat in `ChatDetailsCache`, so reopening a chat shows them at once, and read
// again when the panel appears and as the chat writes (at most once a minute) — the panel only
// exists while the Chats page shows this chat. Layout: `ChatInspectorPanel`.
import SwiftUI
import BurroCore

struct ChatInspector: View {
    var store: AppStore
    var session: AgentSession
    var transcript: ChatTranscript?
    private var cache: ChatDetailsCache { .shared }

    struct DiffStat: Equatable, Sendable {
        var files = 0, added = 0, removed = 0
    }

    var body: some View {
        let tree = worktree
        let folderPath = tree?.path ?? transcript?.folder ?? session.cwd
        ChatInspectorPanel(values: values(tree: tree, folderPath: folderPath), cleaning: store.cleaningWorktree,
                           openWorktree: { if let tree { openWorktree(tree) } },
                           reviewCleanup: { if let tree { store.reviewCleanup([tree]) } })
            // Again as the chat writes, at most once a minute.
            .task(id: "\(session.id)|\(folderPath)|\(Int((transcript?.modified?.timeIntervalSince1970 ?? 0) / 60))") {
                guard session.remote == nil else { return }
                await cache.refreshChanges(path: folderPath, base: tree?.facts.base)
                await cache.refreshCost(session, profiles: store.usage.preferences.profiles)
            }
    }

    private func values(tree: Worktree?, folderPath: String) -> ChatInspectorValues {
        let folder = transcript?.folder ?? session.cwd
        let changes: ChatInspectorValues.Changes
        if let host = session.remote?.hostName {
            changes = .remote(host)
        } else if let known = cache.changes[folderPath] {
            changes = known.map { .files($0) } ?? .notGit
        } else {
            changes = .loading
        }
        let cost = cache.cost[session.id]
        return ChatInspectorValues(
            folder: .init(name: URL(fileURLWithPath: folder).lastPathComponent, path: folder,
                          branch: tree.flatMap { $0.branch.isEmpty ? nil : $0.branch }, pending: tree.flatMap { Self.pending($0.facts) },
                          worktree: tree != nil, primary: tree?.isPrimary ?? true),
            changes: changes, contextTokens: transcript?.contextTokens, contextWindow: transcript?.contextWindow,
            cost: cost ?? nil, costKnown: session.remote != nil || cost != nil, started: session.startedAt, tasks: runningTasks)
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
        return Array(messages.filter { $0.kind == .tool && StepKind($0) == .delegated && $0.output == nil }.suffix(6))
    }

    /// "3 uncommitted · 2 unpushed", or nil when both are zero.
    static func pending(_ facts: GitFacts) -> String? {
        let parts = [facts.changed + facts.untracked > 0 ? "\(facts.changed + facts.untracked) uncommitted" : nil,
                     (facts.unpushed ?? 0) > 0 ? "\(facts.unpushed ?? 0) unpushed" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Burro's Worktrees page with this worktree selected.
    private func openWorktree(_ tree: Worktree) {
        store.search = ""
        store.filter = .all
        store.page = .worktrees
        store.selection = tree.path
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

/// The details panel's slow facts, kept per folder (changes) and per chat (cost) for this run of
/// Burro, at most 64 of each. One read per key at a time.
@MainActor @Observable final class ChatDetailsCache {
    static let shared = ChatDetailsCache()
    /// nil value: not a Git folder (or git failed).
    private(set) var changes: [String: ChatChangeList?] = [:]
    /// nil value: can't be priced.
    private(set) var cost: [String: Double?] = [:]
    @ObservationIgnored private var reading: Set<String> = []

    func refreshChanges(path: String, base: String?) async {
        let key = "changes:" + path
        guard reading.insert(key).inserted else { return }
        defer { reading.remove(key) }
        let list = await Task.detached(priority: .utility) { ChatChanges.read(path: path, base: base) }.value
        if changes.count > 64 && changes[path] == nil { changes = [:] }
        if changes[path] != .some(list) { changes[path] = .some(list) }
    }

    func refreshCost(_ session: AgentSession, profiles: [UsageProvider: String]) async {
        guard session.remote == nil, let (provider, id) = ChatTranscripts.identity(of: session) else { return }
        let key = "cost:" + session.id
        guard reading.insert(key).inserted else { return }
        defer { reading.remove(key) }
        let kind: AgentProvider = provider == "codex" ? .codex : .claude
        let profile = profiles[kind == .codex ? .codex : .claude]
        let root = profile.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(kind == .codex ? ".codex" : ".claude")
        let started = session.startedAt ?? session.updatedAt
        let dollars = await Task.detached(priority: .utility) {
            ChatCost.Reader.shared.dollars(provider: kind, id: id, root: root, startedAt: started)
        }.value
        if cost.count > 64 && cost[session.id] == nil { cost = [:] }
        if cost[session.id] != .some(dollars) { cost[session.id] = .some(dollars) }
    }
}
