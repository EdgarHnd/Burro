// User-facing grouping and stable list membership never alter the underlying safety inventory.
import Foundation

public struct NotchGroup: Identifiable, Sendable {
    public var id: String
    public var root: AgentSession?
    public var workers: [AgentSession]
    public var unavailableIDs: Set<String> = []
    public var members: [AgentSession] { (root.map { [$0] } ?? []) + workers }
    public var title: String { root?.title ?? "Background workers" }
    public var priority: Int { members.map(Self.priority).min() ?? 6 }
    public var newest: Date { members.map(\.updatedAt).max() ?? .distantPast }
    public static func priority(_ session: AgentSession) -> Int {
        if session.remote?.stale == true { return 3 }
        if session.state == .waiting { return 0 }
        if session.showsCompletion { return 1 }
        switch session.state {
        case .working: return 2
        case .unknown: return 3
        case .scheduled: return 4
        case .recent: return 5
        default: return 6
        }
    }
}

public struct NotchFeed: Sendable {
    public var groups: [NotchGroup]
    public var inventory: [String: AgentSession]
    public init(sessions: [AgentSession], includeIdle: Bool, codeOnly: Bool = false) {
        var inventory: [String: AgentSession] = [:]
        for session in sessions where inventory[session.id] == nil { inventory[session.id] = session }
        self.inventory = inventory
        func visible(_ session: AgentSession) -> Bool {
            // A bounded/missing transcript is unknown, not proof of a conversation-only chat.
            // Keep live work visible while preserving the filter for confirmed non-edit chats.
            let active = session.state == .working || session.state == .waiting || session.state == .scheduled
            let incompleteActive = active && session.edits?.exact != true
            return (!codeOnly || session.edits?.hasEdits == true || incompleteActive)
                && (session.showsCompletion || (session.state != .inactive && (includeIdle || session.state != .idle)))
        }
        // Follow only explicit, same-provider/same-host links. Never infer ownership from cwd/title.
        func root(for worker: AgentSession) -> AgentSession? {
            var cursor = worker, seen: Set<String> = [worker.id]
            while let parentID = cursor.parentSessionID, let parent = inventory[parentID] {
                guard seen.insert(parentID).inserted, parent.provider == worker.provider,
                      parent.remote?.hostID == worker.remote?.hostID else { return nil }
                if parent.isSubagent != true { return parent }
                cursor = parent
            }
            return nil
        }
        var grouped: [String: NotchGroup] = [:]
        for session in inventory.values where session.isSubagent != true && visible(session) {
            grouped[session.id] = NotchGroup(id: session.id, root: session, workers: [])
        }
        for worker in inventory.values where worker.isSubagent == true && visible(worker) {
            if let parent = root(for: worker) {
                if grouped[parent.id] == nil { grouped[parent.id] = NotchGroup(id: parent.id, root: parent, workers: []) }
                grouped[parent.id]?.workers.append(worker)
            } else {
                let id = "workers:" + (worker.remote?.hostID.uuidString ?? "local")
                if grouped[id] == nil { grouped[id] = NotchGroup(id: id, root: nil, workers: []) }
                grouped[id]?.workers.append(worker)
            }
        }
        groups = grouped.values.map { group in
            var group = group
            group.workers.sort { a, b in
                if NotchGroup.priority(a) != NotchGroup.priority(b) { return NotchGroup.priority(a) < NotchGroup.priority(b) }
                return a.id < b.id
            }
            return group
        }.sorted { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            if (a.root == nil) != (b.root == nil) { return a.root != nil }
            if a.newest != b.newest { return a.newest > b.newest }
            return a.id < b.id
        }
    }
}

public struct NotchListState: Sendable {
    public private(set) var groups: [NotchGroup] = []
    public private(set) var pendingChanges = 0
    private var initialized = false
    public init() {}
    public mutating func reconcile(_ feed: NotchFeed, holding: Bool) {
        guard initialized && holding else {
            groups = feed.groups; pendingChanges = 0; initialized = true; return
        }
        func membership(_ groups: [NotchGroup]) -> Set<String> {
            Set(groups.flatMap { group in group.members.map { group.id + "/" + $0.id } })
        }
        pendingChanges = membership(groups).symmetricDifference(membership(feed.groups)).count
        // Preserve positions and hit targets, but keep labels and status live. Missing rows
        // become disabled instead of leaving a different chat underneath the pointer.
        groups = groups.map { old in
            var group = old
            group.unavailableIDs = Set(old.members.filter { feed.inventory[$0.id] == nil }.map(\.id))
            group.root = old.root.map { feed.inventory[$0.id] ?? $0 }
            group.workers = old.workers.map { feed.inventory[$0.id] ?? $0 }
            return group
        }
    }
}
