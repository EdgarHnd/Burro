// A reply or new chat the orchestrator proposed, shown under the turn that proposed it: what will
// happen in one line, the full text to edit in place, and Send / Discard. Nothing goes out until
// Send is clicked; the card then shows Burro's confirmation or the error. A waiting proposal is
// outlined in amber (it needs you); one older than a day shows as expired and can only be
// discarded. A reply to a chat that is no longer waiting says so above the buttons.
import SwiftUI
import BurroCore

struct OrchestratorActionCard: View {
    @Bindable var store: AppStore
    var action: OrchestratorAction
    @State private var text: String

    init(store: AppStore, action: OrchestratorAction) {
        self.store = store
        self.action = action
        _text = State(initialValue: action.text)
    }

    var body: some View {
        let expired = action.isExpired()
        let sent = action.status == .sent
        let sending = store.orchestrator.sendingActions.contains(action.id)
        let check = self.check
        let waiting = !sent && !expired
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: action.kind == .reply ? "arrowshape.turn.up.left" : "plus.bubble")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(AppAppearance.secondary).frame(width: 16)
                Text(action.headline).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppAppearance.text).lineLimit(1)
                Spacer(minLength: 6)
                status(sent: sent, expired: expired, sending: sending)
            }
            if let meta { Text(meta).font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary).lineLimit(1).padding(.leading, 24) }
            if waiting {
                TextEditor(text: $text)
                    .font(.system(size: 13)).scrollContentBackground(.hidden)
                    .frame(minHeight: 60, maxHeight: 220).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6).padding(.vertical, 6)
                    .background(AppAppearance.raised.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .disabled(sending)
            } else {
                Text(action.text).font(.system(size: 12.5)).foregroundStyle(AppAppearance.secondary).lineLimit(sent ? 4 : 8)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            if waiting, let notice = check.notice {
                Label(notice, systemImage: check.blocked ? "exclamationmark.triangle" : "info.circle")
                    .font(.system(size: 12)).foregroundStyle(check.blocked ? AppAppearance.amber : AppAppearance.secondary)
            }
            if sent, let result = action.result {
                Label(result, systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
            } else if let error = action.error, !sending {
                Label(error, systemImage: "exclamationmark.bubble").font(.system(size: 12)).foregroundStyle(AppAppearance.amber).lineLimit(4)
            }
            if expired {
                HStack {
                    Text("Proposed \(action.createdAt.formatted(date: .abbreviated, time: .shortened)). Proposals expire after a day.")
                        .font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary)
                    Spacer()
                    discardButton
                }
            } else if waiting {
                HStack(spacing: 10) {
                    Text("Not sent. Edit it if you like, then send.").font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary)
                    Spacer()
                    discardButton.disabled(sending)
                    Button {
                        let edited = text
                        Task { await store.sendOrchestratorAction(action, text: edited) }
                    } label: {
                        HStack(spacing: 5) {
                            if sending { ProgressView().controlSize(.mini) }
                            Text(sending ? "Sending…" : (check.stale ? "Send anyway" : "Send")).font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(OrchestratorStyle.onGold)
                        .padding(.horizontal, 14).frame(height: 28)
                        .background(Capsule().fill(AppAppearance.amber))
                        .opacity(canSend(check: check, sending: sending) ? 1 : 0.4)
                    }
                    .buttonStyle(.plain).disabled(!canSend(check: check, sending: sending))
                    .help(action.kind == .reply ? "Send this reply to the chat" : "Start this chat on this Mac")
                }
            }
        }
        .padding(14)
        .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(waiting ? AppAppearance.amber.opacity(0.55) : AppAppearance.separator))
        .onChange(of: action.text) { _, new in if !sending { text = new } }
    }

    private var discardButton: some View {
        Button("Discard") { store.orchestrator.discard(action) }
            .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(AppAppearance.secondary)
            .help("Remove this proposal without sending it")
    }

    @ViewBuilder private func status(sent: Bool, expired: Bool, sending: Bool) -> some View {
        let (title, color): (String, Color) = sent ? ("Sent", AppAppearance.tertiary)
            : expired ? ("Expired", AppAppearance.tertiary)
            : sending ? ("Sending", AppAppearance.secondary)
            : ("Needs your OK", AppAppearance.amber)
        Text(title.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(0.7).foregroundStyle(color)
    }

    private var meta: String? {
        guard action.kind == .start else { return nil }
        var parts: [String] = []
        if let model = action.model { parts.append(Orchestrator.modelTitle(model)) }
        if let effort = action.effort { parts.append(Orchestrator.effortTitle(effort) + " effort") }
        parts.append(action.launchAccess.title)
        if let folder = action.folder { parts.append((folder as NSString).abbreviatingWithTildeInPath) }
        return parts.joined(separator: " · ")
    }

    private func canSend(check: Check, sending: Bool) -> Bool {
        !sending && !check.blocked && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private struct Check { var notice: String?; var blocked = false; var stale = false }

    /// What Burro knows right now about where this would go.
    private var check: Check {
        switch action.kind {
        case .start:
            var isDirectory: ObjCBool = false
            guard let folder = action.folder, FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
                return Check(notice: "That folder no longer exists.", blocked: true)
            }
            return Check()
        case .reply:
            guard let (session, host) = store.orchestratorTarget(action) else {
                return Check(notice: "Burro can't see this chat right now, so it can't send the reply.", blocked: true)
            }
            if let reason = ChatReply.unavailable(session, host: host) { return Check(notice: reason, blocked: true) }
            if session.state == .waiting { return Check() }
            let now = session.state == .working ? "working" : session.isDone ? "done, with a result to read" : "idle"
            return Check(notice: "This chat is no longer waiting for you: it's \(now).", stale: true)
        }
    }
}
