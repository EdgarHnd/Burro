// Stable, fixed-height chat targets retain direct navigation and disclose lost session evidence.
import SwiftUI
import BurroCore

struct NotchAgentRow: View {
    let session: AgentSession
    let workspace: String
    var available: Bool
    var workerState: AgentState? = nil
    var select: () -> Void
    var inspect: () -> Void
    @State private var hovering = false
    private var workerLabel: String? {
        guard available else { return nil }
        if workerState == .waiting { return "Worker needs you" }
        if workerState == .working && !session.showsCompletion && ![AgentState.working, .waiting].contains(session.state) { return "Worker running" }
        return nil
    }
    private var color: Color {
        if workerLabel != nil { return workerState == .waiting ? NotchStyle.attention : AgentState.working.color }
        return !available || session.remote?.stale == true ? .secondary : session.statusColor
    }
    private var label: String {
        if !available { return "Unavailable" }
        if let workerLabel { return workerLabel }
        if session.remote?.stale == true { return "Last seen" }
        if session.showsCompletion { return session.statusLabel }
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
                Image(nsImage: ProviderIcons.image(for: session.provider))
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(1).foregroundStyle(.white.opacity(0.92))
                    Text("\(session.provider == .codex ? "Codex" : "Claude") · \(workspace)")
                        .font(.system(size: 10)).lineLimit(1).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if let edits = session.edits, edits.hasEdits, edits.added + edits.removed > 0 || edits.exact {
                    HStack(spacing: 3) {
                        if edits.added + edits.removed > 0 || edits.exact {
                            Text("+\(edits.added)").foregroundStyle(.green)
                            Text("−\(edits.removed)").foregroundStyle(.red)
                            if !edits.exact { Text("+").foregroundStyle(.secondary) }
                        }
                    }.font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .help("Recorded edits in this chat, summed across edit operations; not the shared checkout diff. A trailing + means some changes have no recorded diff.")
                }
                VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 4) {
                    if session.showsCompletion && available && workerLabel == nil { Image(systemName: "checkmark.circle.fill").font(.system(size: 9)) }
                    else if session.state == .scheduled && available && session.remote?.stale != true && workerLabel == nil { Image(systemName: "clock").font(.system(size: 10)) }
                    else { Circle().fill(color).frame(width: 4, height: 4) }
                    Text(label)
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(color)
                if session.showsCompletion && available && workerLabel == nil {
                    Text(session.chatDeliveryLabel).font(.system(size: 9)).foregroundStyle(.secondary)
                        .help(session.edits?.commit.map { "The chat cited \($0.sha). Verified against this checkout and cached remote refs; this does not attribute every edit to this chat." } ?? "No specific chat commit has been verified. Worktree Git status is shown only on the worktree row.")
                }
                }
            }.padding(.horizontal, 10).frame(height: 56)
                .background(hovering ? .white.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 11))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }.disabled(!available)
            .help(available ? (session.chatURL == nil ? "Show details in Burro" : "Open chat in \(session.provider == .codex ? "Codex" : "Claude")") + "\n" + session.title : "No longer present in the latest scan. Update the list to remove this row.")
            .accessibilityHint(session.chatURL == nil ? "Shows session details in Burro" : "Opens this chat in \(session.provider == .codex ? "Codex" : "Claude")")
            .contextMenu { Button("Show in Burro", action: inspect).disabled(!available) }
    }
}

// Chat activity never inherits the shared checkout’s Git warning color.
extension AgentSession {
    var statusColor: Color {
        guard showsCompletion else { return state.color }
        return .blue
    }
}

@MainActor private enum ProviderIcons {
    static let codex = load("codex")
    static let claude = load("claude")
    static func load(_ name: String) -> NSImage {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return NSImage() }
        return image
    }
    static func image(for provider: AgentProvider) -> NSImage { provider == .codex ? codex : claude }
}
