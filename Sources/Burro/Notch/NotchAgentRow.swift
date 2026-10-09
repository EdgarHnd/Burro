// Stable, fixed-height chat targets retain direct navigation and disclose lost session evidence.
import SwiftUI
import BurroCore

struct NotchAgentRow: View {
    let session: AgentSession
    let workspace: String
    var available: Bool
    var workerState: AgentState? = nil
    var lastActive: Date? = nil
    var animate = false
    var select: () -> Void
    var inspect: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var workerLabel: String? {
        guard available else { return nil }
        if workerState == .waiting { return "Worker needs you" }
        if workerState == .working && !session.isDone && ![AgentState.working, .waiting].contains(session.state) { return "Worker running" }
        return nil
    }
    private var color: Color {
        if workerLabel != nil { return workerState == .waiting ? NotchStyle.attention : AgentState.working.color }
        return !available || session.remote?.stale == true ? .secondary : (session.isDone ? .blue : session.state.color)
    }
    private var label: String {
        if !available { return "Unavailable" }
        if let workerLabel { return workerLabel }
        if session.remote?.stale == true { return "Last seen" }
        if session.isDone { return "Done" }
        switch session.state {
        case .working: return "Running"
        case .waiting: return "Needs you"
        case .idle, .inactive: return "Idle"
        default: return session.state.rawValue
        }
    }
    var body: some View {
        Button(action: select) {
            HStack(spacing: 11) {
                AgentAvatar(session: session, active: animate && available,
                            working: session.state == .working || workerState == .working)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).foregroundStyle(AppAppearance.text)
                    Text("\(session.provider == .codex ? "Codex" : "Claude") · \(workspace)")
                        .font(.system(size: 10)).lineLimit(1).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) {
                        if session.isDone && available && workerLabel == nil { Image(systemName: "checkmark.circle.fill").font(.system(size: 9)) }
                        else if session.state == .scheduled && available && session.remote?.stale != true && workerLabel == nil { Image(systemName: "clock").font(.system(size: 10)) }
                        else { Circle().fill(color).frame(width: 4, height: 4) }
                        Text(label)
                    }.font(.system(size: 10, weight: .medium)).foregroundStyle(color)
                    if let lastActive {
                        Text(lastActive, style: .time).font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                            .help("Last active: \(lastActive.formatted())")
                    }
                }.fixedSize()
            }.padding(.horizontal, 10).frame(height: 56)
                .background((hovering ? AppAppearance.raised : AppAppearance.surface).opacity(reduceTransparency ? 1 : 0.45),
                    in: RoundedRectangle(cornerRadius: AppAppearance.cardRadius))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }.disabled(!available)
            .help(available ? (session.chatURL == nil ? "Show details in Burro" : "Open chat in \(session.provider == .codex ? "Codex" : "Claude")") + "\n" + session.title : "No longer present in the latest scan. Update the list to remove this row.")
            .accessibilityHint(session.chatURL == nil ? "Shows session details in Burro" : "Opens this chat in \(session.provider == .codex ? "Codex" : "Claude")")
            .contextMenu { Button("Show in Burro", action: inspect).disabled(!available) }
    }
}
