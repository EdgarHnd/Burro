// Checkout grouping adapted from DantesHub's MIT-licensed Burro PR #1.
// Display grouping never filters agents or changes unread and parent/worker semantics.
import Foundation

public struct NotchWorkspace: Identifiable, Sendable {
    public var id: String
    public var path: String
    public var groups: [NotchGroup]
    public var sessions: [AgentSession] { groups.flatMap(\.members) }
    /// Apply before reconciling the held list so live metadata cannot move a pointer target.
    public static func prioritized(_ groups: [NotchGroup], interactions: [String: Date] = [:],
                                   path: (AgentSession) -> String) -> [Self] {
        func running(_ group: NotchGroup) -> Bool {
            group.members.contains {
                $0.state == .working && $0.remote?.stale != true && !group.unavailableIDs.contains($0.id)
            }
        }
        func latest(_ group: NotchGroup) -> Date {
            max(group.newest, group.members.compactMap { interactions[$0.id] }.max() ?? .distantPast)
        }
        return grouped(groups, path: path).map { workspace in
            var workspace = workspace
            workspace.groups.sort { a, b in
                if running(a) != running(b) { return running(a) }
                if latest(a) != latest(b) { return latest(a) > latest(b) }
                return a.id < b.id
            }
            return workspace
        }.sorted { a, b in
            let aRunning = a.groups.contains(where: running), bRunning = b.groups.contains(where: running)
            if aRunning != bRunning { return aRunning }
            let aLatest = a.groups.map(latest).max() ?? .distantPast
            let bLatest = b.groups.map(latest).max() ?? .distantPast
            if aLatest != bLatest { return aLatest > bLatest }
            return a.id < b.id
        }
    }
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
