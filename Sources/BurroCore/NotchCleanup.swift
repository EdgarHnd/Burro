import Foundation

/// Merged linked checkouts still on disk. This is a review queue, not deletion authorization.
public struct NotchCleanup: Identifiable, Sendable {
    public var id: String
    public var path: String
    public var title: String
    public var machine: String
    public var canDelete: Bool = false
    public var blockers: [String] = []

    public static func inventory(worktrees: [Worktree], sessions: [AgentSession]) -> [Self] {
        func active(_ sessions: [AgentSession]) -> Bool {
            sessions.contains { [.working, .waiting, .scheduled, .unknown, .recent].contains($0.state) }
        }
        var result: [Self] = worktrees.compactMap { tree in
            guard !tree.isPrimary, !tree.isMissing, !tree.isLocked, !tree.protectedByUser,
                  tree.facts.merged == true, DeliveryStatus.evaluate(tree.facts) == .merged,
                  tree.processes.isEmpty, !active(tree.agents + sessions.filter { $0.remote == nil && ($0.cwd == tree.path || $0.checkoutPath == tree.path || $0.attachedPaths.contains(tree.path)) }), !tree.agents.contains(where: \.pinned) else { return nil }
            return Self(id: "local:" + tree.path, path: tree.path, title: tree.branch, machine: "This Mac", canDelete: WorktreeRemoval.assessment(tree).level == .candidate,
                blockers: WorktreeRemoval.assessment(tree).level == .candidate ? [] : WorktreeRemoval.assessment(tree).reasons)
        }
        let remote = Dictionary(grouping: sessions.filter { $0.remote != nil && $0.checkoutPath != nil }) {
            $0.remote!.hostID.uuidString + ":" + $0.checkoutPath!
        }
        for (id, chats) in remote {
            guard !active(chats), !chats.contains(where: \.pinned),
                  chats.allSatisfy({ $0.remote?.stale == false && $0.checkoutIsLinked == true && $0.deliveryStatus == .merged }),
                  let chat = chats.first, let path = chat.checkoutPath else { continue }
            result.append(Self(id: id, path: path, title: chat.checkoutBranch ?? URL(fileURLWithPath: path).lastPathComponent,
                               machine: chat.remote!.hostName, blockers: ["Remote deletion is not supported yet"]))
        }
        return result.sorted { $0.id < $1.id }
    }
}
