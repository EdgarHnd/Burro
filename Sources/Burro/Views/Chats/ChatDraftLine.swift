// One quiet line above a chat's composer when the Orchestrator has a reply drafted for that chat
// (triage's draft, or a reply it proposed when you asked): "✦ Draft from the Orchestrator: “<first
// line>”   Use · Discard". Use puts the whole draft into the composer for you to edit and send the
// usual way (it never sends) and takes the proposal off the Brief, so it can't also be sent from
// there; Discard removes the proposal. Hidden when there is no draft. `ComposerInserts` carries
// the text to the composer (it reads `latest`, see `ComposerInsertion.merged`).
import SwiftUI
import BurroCore

/// The hand-off from "Use" to the chat's composer: the latest request, for one chat.
@MainActor @Observable final class ComposerInserts {
    static let shared = ComposerInserts()
    private(set) var latest: ComposerInsertion?
    func put(_ text: String, chatID: String) { latest = ComposerInsertion(chatID: chatID, text: text) }
}

struct ChatDraftLine: View {
    var store: AppStore
    var session: AgentSession

    var body: some View {
        if let draft = store.brief.draft(chatID: session.id, actions: store.orchestrator.actions) {
            ChatDraftLineContent(text: draft.text, sending: store.orchestrator.sendingActions.contains(draft.id), use: {
                ComposerInserts.shared.put(draft.text, chatID: session.id)
                store.orchestrator.discard(draft)
            }, discard: { store.orchestrator.discard(draft) })
        }
    }
}

/// The line itself, layout only.
struct ChatDraftLineContent: View {
    var text: String
    var sending = false
    var use: () -> Void
    var discard: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle").font(.system(size: 10.5)).foregroundStyle(AppAppearance.tertiary).accessibilityHidden(true)
            Text("Draft from the Orchestrator: “\(BriefDrafts.firstLine(text))”")
                .foregroundStyle(AppAppearance.tertiary).lineLimit(1).truncationMode(.tail).help(text)
            Spacer(minLength: 6)
            Button("Use", action: use)
                .foregroundStyle(AppAppearance.secondary).help("Put this draft in the reply box to edit and send yourself")
            Text("·").foregroundStyle(AppAppearance.tertiary)
            Button("Discard", action: discard).foregroundStyle(AppAppearance.secondary).help("Remove this draft")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .disabled(sending)
        .frame(maxWidth: ChatColumn.width - 8).frame(maxWidth: .infinity)
        .padding(.horizontal, ChatColumn.inset + 4).padding(.top, 6)
    }
}

/// The centre column's measures, shared by the conversation, the draft line and the composer.
enum ChatColumn {
    static let width: CGFloat = 820
    static let inset: CGFloat = 20
}
