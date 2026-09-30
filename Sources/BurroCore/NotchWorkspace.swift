// Checkout grouping adapted from DantesHub's MIT-licensed Burro PR #1.
// Display grouping never filters agents or changes unread and parent/worker semantics.
import Foundation

public struct NotchWorkspace: Identifiable, Sendable {
    public var id: String
    public var path: String
    public var groups: [NotchGroup]
    public var sessions: [AgentSession] { groups.flatMap(\.members) }
    public static func grouped(_ groups: [NotchGroup], path: (AgentSession) -> String) -> [Self] {
        var result: [Self] = []
        var indices: [String: Int] = [:]
        for group in groups {
            guard let session = group.root ?? group.workers.first else { continue }
            let location = path(session)
            // Unattached worker buckets can span checkouts; never label them as one worktree.
            let key = (session.remote?.hostID.uuidString ?? "local") + ":"
                + (group.root == nil || location.isEmpty ? "group:" + group.id : location)
            if let index = indices[key] { result[index].groups.append(group) }
            else {
                indices[key] = result.count
                result.append(Self(id: key, path: group.root == nil ? "" : location, groups: [group]))
            }
        }
        return result
    }
}
