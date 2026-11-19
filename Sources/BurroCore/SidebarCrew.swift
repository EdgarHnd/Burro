// "The crew" in the window's sidebar: the chats that are agents at work right now, in the Chats
// page's own order and sections (ChatListSection): Needs you, then Working, then Ready to read,
// each newest first. Idle chats and sub-agents are left out (a sub-agent is answered through its
// parent). At most `cap` show; the rest are counted for "Show all N in Chats".
import Foundation

public struct SidebarCrew: Equatable, Sendable {
    public struct Member: Equatable, Sendable, Identifiable {
        public var session: AgentSession
        public var status: ChatPageStatus
        public var id: String { session.id }
    }
    public var members: [Member]
    /// Every chat that qualifies, shown or not.
    public var total: Int
    /// Chats left out by the cap.
    public var overflow: Int { total - members.count }

    public static let empty = SidebarCrew(members: [], total: 0)

    public static func make(_ sessions: [AgentSession], cap: Int) -> SidebarCrew {
        var seen = Set<String>()
        let chats = sessions.filter { $0.isSubagent != true && seen.insert($0.id).inserted }.sorted { a, b in
            let (pa, pb) = (NotchGroup.priority(a), NotchGroup.priority(b))
            return pa != pb ? pa < pb : (a.updatedAt != b.updatedAt ? a.updatedAt > b.updatedAt : a.id < b.id)
        }
        let order: [ChatListSection.Kind] = [.needsYou, .working, .readyToRead]
        let sections = ChatListSection.sections(chats, pinned: { _ in false })
        let all = order.flatMap { kind in
            (sections.first { $0.kind == kind }?.sessions ?? []).map { Member(session: $0, status: ChatListRow.status(of: kind)) }
        }
        return SidebarCrew(members: Array(all.prefix(max(0, cap))), total: all.count)
    }
}
