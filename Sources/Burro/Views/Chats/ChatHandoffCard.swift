// The card at the end of a waiting chat's conversation: "● Waiting for you · 4 min", what Burro
// can and can't do about it (it can't answer an approval: neither provider offers a way), and the
// one action that reaches the place that can: Open in Codex / Open in Claude / Attach in Terminal /
// Attach on <machine>, from `ChatHandoff` and the composer's plan. Layout only.
import SwiftUI
import BurroCore

struct ChatHandoffCard: View {
    var card: ChatHandoff
    /// When the chat started waiting (its last activity).
    var since: Date?
    var agent: String
    var machine: String?
    var perform: (ComposerPlan.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(AppAppearance.amber).frame(width: 8, height: 8)
                Text(card.title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if let since {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text("waiting \(ChatTurnClock.short(context.date.timeIntervalSince(since)))")
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                    }
                }
            }
            Text(card.detail).font(.system(size: 12.5)).foregroundStyle(AppAppearance.secondary).fixedSize(horizontal: false, vertical: true)
            if let action = card.action {
                Button { perform(action) } label: {
                    ChatButtonLabel(title: ComposerActionTitle.of(action, agent: agent, machine: machine), symbol: "arrow.up.right", primary: true)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: AppAppearance.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AppAppearance.cardRadius, style: .continuous).strokeBorder(AppAppearance.amber.opacity(0.35)))
        .accessibilityElement(children: .contain)
    }
}

enum ComposerActionTitle {
    static func of(_ action: ComposerPlan.Action, agent: String, machine: String?) -> String {
        switch action {
        case .openInProvider: "Open in \(agent)"
        case .attachInTerminal: "Attach in Terminal"
        case .attachOnMachine: "Attach on \(machine ?? "that machine")"
        case .queue: "Queue for when it's done"
        }
    }
}
