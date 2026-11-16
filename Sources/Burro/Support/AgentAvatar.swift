// An agent's avatar: the Burro mascot tinted by provider (orange Claude, blue Codex), with a
// stable per-chat timing offset so a list of them never moves in unison. Provider identity is
// independent of the session's state colours. `ProviderAvatar` draws the same mark from just a
// provider and an id, for rows that have no session yet (the Chats list's rows, chats starting).
import SwiftUI
import BurroCore

struct AgentAvatar: View {
    let session: AgentSession
    var active = true
    var working: Bool? = nil
    var size: CGFloat = 28

    var body: some View {
        ProviderAvatar(provider: session.provider, id: session.id, active: active && session.remote?.stale != true,
                       working: working ?? (session.state == .working), size: size)
    }
}

struct ProviderAvatar: View {
    var provider: AgentProvider
    var id: String
    var active = true
    var working = false
    var size: CGFloat = 28

    static func tint(_ provider: AgentProvider) -> Color { provider == .claude ? AppAppearance.claude : AppAppearance.blue }

    private var phase: Double {
        // Stable offsets keep a list of agents from moving in unison, across refreshes.
        let hash = id.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return Double(hash % 1000) / 1000
    }
    var body: some View {
        BurroMark(active: active, working: working, tint: Self.tint(provider), phase: phase)
            .frame(width: size, height: size)
    }
}
