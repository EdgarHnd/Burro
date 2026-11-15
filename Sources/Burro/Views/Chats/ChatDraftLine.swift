// One quiet line above a chat's composer when the Orchestrator has a reply drafted for that chat
// (triage's draft, or a reply it proposed when you asked): "Draft from the Orchestrator: <first
// line> · Use · Discard". Use puts the whole draft into the composer for you to edit and send the
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
            let sending = store.orchestrator.sendingActions.contains(draft.id)
            HStack(spacing: 6) {
                Image(systemName: "text.bubble").font(.system(size: 10.5)).foregroundStyle(AppAppearance.tertiary)
                Text("Draft from the Orchestrator:").foregroundStyle(AppAppearance.tertiary).layoutPriority(1)
                Text(BriefDrafts.firstLine(draft.text)).foregroundStyle(AppAppearance.secondary).lineLimit(1).help(draft.text)
                Text("·").foregroundStyle(AppAppearance.tertiary)
                Button("Use") {
                    ComposerInserts.shared.put(draft.text, chatID: session.id)
                    store.orchestrator.discard(draft)
                }
                .help("Put this draft in the reply box to edit and send yourself")
                Text("·").foregroundStyle(AppAppearance.tertiary)
                Button("Discard") { store.orchestrator.discard(draft) }.help("Remove this draft")
                Spacer(minLength: 0)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .disabled(sending)
            .frame(maxWidth: 840 - 32).frame(maxWidth: .infinity)
            .padding(.horizontal, 36 + 16).padding(.top, 6)
        }
    }
}
