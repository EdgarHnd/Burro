// The reply composer's box, layout only. When nothing can be typed (`!plan.canType`) it is one
// compact bar: the reason, and on the right its single action (Open in Claude, Attach in
// Terminal, Attach on <Machine>) unless the hand-off card above already offers it; no field, no
// pickers, no empty box (and nothing at all without a reason). Otherwise: a reason line when
// there is one, files waiting to go, the message field, then one row: the paperclip and the
// access, model and effort menus on the left; on the right Send (↩) as the one amber action, or,
// while the chat works, "Steer now" (Codex) and "Queue for when it's done" (↩). Stop lives in the
// header. While a Claude chat's first open-session check runs (`checking`) it is an empty bar of
// the unavailable bar's height, so neither a field nor a reason flashes up and then changes.
// `ChatComposer` owns the state and decisions (`ComposerPlan`); this draws what it's given.
import SwiftUI
import BurroCore

struct ChatComposerBox<Options: View>: View {
    var plan: ComposerPlan
    /// The action the conversation's hand-off card already offers; the reason line leaves it out.
    var handoffAction: ComposerPlan.Action? = nil
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var placeholder: String
    var sending: Bool
    var dropTargeted = false
    var attachments: [String]
    var removeAttachment: (String) -> Void = { _ in }
    var agent: String
    var machine: String?
    var perform: (ComposerPlan.Action) -> Void = { _ in }
    var submit: () -> Void = {}
    var send: () -> Void = {}
    var steer: () -> Void = {}
    var enqueue: () -> Void = {}
    /// The chat's first check hasn't answered yet: hold a quiet bar where the composer goes.
    var checking = false
    @ViewBuilder var options: Options

    var body: some View {
        if checking {
            ComposerCheckingBar()
        } else if plan.canType {
            box
        } else if let reason = plan.reason {
            ComposerUnavailableBar(reason: reason, action: plan.action == handoffAction ? nil : plan.action,
                                   agent: agent, machine: machine, perform: perform)
        }
    }

    @ViewBuilder private var box: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let busy = !plan.canSend && (plan.canQueue || plan.canSteer || plan.stop != nil)
        VStack(alignment: .leading, spacing: 10) {
            if let reason = plan.reason {
                ComposerReasonLine(reason: reason, action: plan.action == handoffAction ? nil : plan.action, agent: agent, machine: machine, perform: perform)
            }
            if !attachments.isEmpty { AttachmentChips(paths: attachments, remove: removeAttachment) }
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13.5)).lineLimit(2...8)
                .focused(focused).onSubmit(submit).disabled(sending)
                .accessibilityLabel(placeholder)
            HStack(spacing: 6) {
                options
                Spacer(minLength: 8)
                if busy {
                    if plan.canSteer {
                        Button(action: steer) { ChatButtonLabel(title: "Steer now", enabled: !empty && !sending) }
                            .buttonStyle(.plain).disabled(empty || sending).help("Add this to the turn Codex is on now")
                    }
                    if plan.canQueue {
                        Button(action: enqueue) { ChatButtonLabel(title: "Queue for when it's done", key: "↩", primary: true, enabled: !empty && !sending) }
                            .buttonStyle(.plain).disabled(empty || sending).help("Burro sends it when the chat finishes (Return)")
                    }
                } else {
                    Button(action: send) {
                        HStack(spacing: 0) {
                            if sending { ProgressView().controlSize(.mini).padding(.trailing, 6) }
                            ChatButtonLabel(title: sending ? "Sending…" : "Send", key: sending ? nil : "↩", primary: true,
                                            enabled: !empty && plan.canSend && !sending)
                        }
                    }
                    .buttonStyle(.plain).disabled(empty || !plan.canSend || sending)
                    .help(ChatReply.sendHelp(plan))
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 10)
        .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: AppAppearance.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AppAppearance.cardRadius, style: .continuous)
            .strokeBorder(dropTargeted ? AppAppearance.blue.opacity(0.6) : (focused.wrappedValue ? AppAppearance.secondary.opacity(0.35) : AppAppearance.hairline)))
    }
}

/// Where the composer would be when a reply can't be typed: why, and the one thing to do.
struct ComposerUnavailableBar: View {
    var reason: String
    var action: ComposerPlan.Action?
    var agent: String
    var machine: String?
    var perform: (ComposerPlan.Action) -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                .accessibilityHidden(true)
            Text(reason).font(.system(size: 12.5)).foregroundStyle(AppAppearance.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 8)
            if let action {
                Button { perform(action) } label: { ChatButtonLabel(title: ComposerReasonLine.title(action, agent: agent, machine: machine)) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(minHeight: 44)
        .background(AppAppearance.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: AppAppearance.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AppAppearance.cardRadius, style: .continuous).strokeBorder(AppAppearance.hairline))
        .accessibilityElement(children: .contain)
    }
}

/// Where the composer goes while a Claude chat's first check runs: the unavailable bar's empty
/// frame, the same height, so neither a reply field nor the reason flashes up before the check
/// says which one this chat gets.
struct ComposerCheckingBar: View {
    var body: some View {
        RoundedRectangle(cornerRadius: AppAppearance.cardRadius, style: .continuous)
            .fill(AppAppearance.surface.opacity(0.35))
            .overlay(RoundedRectangle(cornerRadius: AppAppearance.cardRadius, style: .continuous).strokeBorder(AppAppearance.hairline))
            .frame(height: 44)
            .accessibilityElement()
            .accessibilityLabel("Checking whether this chat can take a reply")
    }
}

/// A composer menu's face: "Ask me ▾", "Opus 5.5 ▾", "High ▾".
struct ComposerOptionLabel: View {
    var symbol: String?
    var title: String
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).opacity(0.6)
        }
        .foregroundStyle(AppAppearance.secondary)
        .padding(.horizontal, 8).frame(height: 24)
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(AppAppearance.hairline))
        .contentShape(Rectangle())
    }
}

/// The paperclip's face.
struct ComposerAttachLabel: View {
    var body: some View {
        Image(systemName: "paperclip").font(.system(size: 12, weight: .semibold)).foregroundStyle(AppAppearance.secondary)
            .frame(width: 26, height: 24).contentShape(Rectangle())
    }
}
