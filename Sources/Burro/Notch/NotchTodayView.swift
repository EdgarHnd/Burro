// A flat chronological view keeps chats from different projects in last-active order.
import SwiftUI
import BurroCore

struct NotchTodayView: View {
    var groups: [NotchGroup]
    var active: Bool
    var select: (AgentSession) -> Void
    var inspect: (AgentSession) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(groups) { group in
                    if let session = group.root {
                        NotchAgentRow(session: session,
                            workspace: "\(session.remote?.hostName ?? "This Mac") · \(URL(fileURLWithPath: session.cwd).lastPathComponent)",
                            available: !group.unavailableIDs.contains(session.id), lastActive: session.updatedAt,
                            animate: active, select: { select(session) }, inspect: { inspect(session) })
                    }
                }
            }.padding(.horizontal, 12).padding(.vertical, 4)
        }.scrollIndicators(.automatic).accessibilityLabel("Today's chats, most recently active first")
    }
}
