import SwiftUI
import BurroCore

// Provider identity is independent of the session's green/amber activity indicator.
struct AgentAvatar: View {
    let session: AgentSession
    var active = true
    var working: Bool? = nil
    var size: CGFloat = 28

    private var phase: Double {
        // Stable offsets keep a list of agents from moving in unison, across refreshes.
        let hash = session.id.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return Double(hash % 1000) / 1000
    }
    var body: some View {
        BurroMark(active: active && session.remote?.stale != true,
                  working: working ?? (session.state == .working),
                  tint: session.provider == .claude ? AppAppearance.claude : AppAppearance.blue,
                  phase: phase)
            .frame(width: size, height: size)
    }
}
