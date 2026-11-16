// The Orchestrator page's left column, the Brief queue, from what triage keeps in `store.brief`.
// Needs you (amber): one card per chat with its title, machine and age, the question it ends on and,
// when the chat has a draft (triage's, or a reply the Orchestrator proposed), the draft inline with
// Send / Edit / Discard. Send goes through the proposal card's own path (`sendOrchestratorAction`);
// Edit swaps in the full proposal card to edit in place; Discard drops the draft. A chat without a
// draft offers Open. A draft whose Send Burro couldn't confirm shows the proposal card's "May
// have gone" state (check the chat; Send again only after a confirmation). Finished: one row per chat with its one-line outcome; each row opens the chat,
// and Mark read marks those results read in Burro only (provider unread markers are never written)
// and clears them from the Brief. Stuck: the chat, how long it has been quiet and where, with Open
// (no nudge: nothing here messages an agent). Right-click any item to ask the Orchestrator about its
// chat (only prefills the question; the owner clicks Ask) or to dismiss it. An item whose chat has
// left Burro's list (a chat on this Mac that closed) is tagged "Closed" ("Not listed" for another
// machine's): Open reads "Open in Claude" when the Claude app still has it, else there is no Open
// and a line says Burro can't open it. Every Open goes through `AppStore.openChat(id:)`. Also the small
// controls the page shares: its buttons, tags and section labels.
import SwiftUI
import BurroCore

struct OrchestratorBriefQueue: View {
    @Bindable var store: AppStore
    var now: Date
    @State private var editing: String?

    var body: some View {
        let brief = store.brief
        let needs = brief.needsYou, finished = brief.finished, stuck = brief.stuck
        VStack(alignment: .leading, spacing: 18) {
            if needs.isEmpty && finished.isEmpty && stuck.isEmpty {
                emptyCard(brief)
            }
            if !needs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    OrchSectionLabel(title: "Needs you · \(needs.count)", dot: AppAppearance.amber, tint: AppAppearance.amber)
                    ForEach(needs) { item in needsCard(item) }
                }
            }
            if !finished.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        OrchSectionLabel(title: "Finished · \(finished.count)", dot: AppAppearance.blue)
                        Spacer(minLength: 6)
                        Button("Mark read") { markRead(finished) }
                            .buttonStyle(OrchButtonStyle(kind: .ghost))
                            .help("Mark these results read in Burro and clear them from the Brief. Codex and Claude keep their own unread marks.")
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(finished.prefix(8).enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Rectangle().fill(AppAppearance.separator).frame(height: 1) }
                            finishedRow(item)
                        }
                        if finished.count > 8 {
                            Rectangle().fill(AppAppearance.separator).frame(height: 1)
                            Text("and \(finished.count - 8) more").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 2)
                    .modifier(OrchCard())
                }
            }
            if !stuck.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    OrchSectionLabel(title: "Stuck · \(stuck.count)", dot: AppAppearance.tertiary)
                    ForEach(stuck) { item in stuckCard(item) }
                }
            }
        }
        // Claude app links for items whose chat has left Burro's list (closed chats).
        .task(id: unlisted(brief)) { await ClosedChatLinks.shared.refresh(unlisted(brief)) }
    }

    // MARK: Needs you

    private func needsCard(_ item: BriefItem) -> some View {
        let actions = store.orchestrator.actions
        // Triage's own draft (also once sent), else a reply the Orchestrator proposed for this chat.
        let action = item.proposalID.flatMap { id in actions.first { $0.id == id } }
            ?? item.chatID.flatMap { store.brief.draft(chatID: $0, actions: actions, now: now) }
        let closed = closed(item)
        return VStack(alignment: .leading, spacing: 8) {
            Button { open(item) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(item.chatTitle ?? "A chat").font(.system(size: 13, weight: .semibold)).foregroundStyle(AppAppearance.text).lineLimit(1)
                        if let machine = item.machine { AppTag(text: machine) }
                        if let closed { AppTag(text: closed.tag) }
                        Spacer(minLength: 6)
                        Text(Self.age(item.updatedAt, now: now)).font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                    }
                    Text(item.question ?? item.headline).font(.system(size: 13)).foregroundStyle(AppAppearance.secondary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(item.question.map { "\(item.headline)\n\($0)" } ?? item.headline)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!(closed?.canOpen ?? true)).help(openHelp(closed))
            if let line = closed?.line {
                Text(line).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(2)
            }
            if let action, action.status == .sent {
                Label(action.result ?? "Sent", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
            } else if let action, action.isUnconfirmed {
                // May have gone: the full card says so, with Open Chats and Send again… behind a confirmation.
                OrchestratorActionCard(store: store, action: action)
            } else if let action, action.isWaiting(now: now) {
                if editing == action.id {
                    OrchestratorActionCard(store: store, action: action)
                    Button("Done editing") { editing = nil }.buttonStyle(OrchButtonStyle(kind: .ghost))
                } else {
                    draft(action)
                }
            } else {
                HStack(spacing: 8) {
                    Text(item.detail ?? "No draft: worth a look").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                    Spacer(minLength: 6)
                    openButton(item, closed: closed, kind: .bordered)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .modifier(OrchCard(stroke: AppAppearance.amber.opacity(0.4)))
        .contextMenu { rowMenu(item) }
    }

    /// The drafted reply, inline, with Send / Edit / Discard.
    private func draft(_ action: OrchestratorAction) -> some View {
        let sending = store.orchestrator.sendingActions.contains(action.id)
        let blocked = blockedReason(action)
        return VStack(alignment: .leading, spacing: 8) {
            (Text(action.conversation == BriefDrafts.triageConversation ? "Draft · " : "Proposed · ").foregroundStyle(AppAppearance.tertiary)
             + Text(action.text).foregroundStyle(AppAppearance.text))
                .font(.system(size: 12)).lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(OrchField())
                .help(action.text)
            if let error = action.error, !sending {
                Label(error, systemImage: "exclamationmark.bubble").font(.system(size: 12)).foregroundStyle(AppAppearance.amber).lineLimit(2)
            } else if let blocked {
                Text(blocked).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(2)
            }
            HStack(spacing: 6) {
                Button {
                    let text = action.text
                    Task { await store.sendOrchestratorAction(action, text: text) }
                } label: {
                    HStack(spacing: 5) {
                        if sending { ProgressView().controlSize(.mini) }
                        Text(sending ? "Sending…" : "Send")
                    }
                }
                .buttonStyle(OrchButtonStyle(kind: .primary))
                .disabled(sending || blocked != nil)
                .help(ChatReply.cardSendHelp(provider: store.orchestratorTarget(action)?.session.provider))
                Button("Edit") { editing = action.id }.buttonStyle(OrchButtonStyle(kind: .bordered)).disabled(sending)
                    .help("Edit the reply before sending")
                Button("Discard") { store.orchestrator.discard(action) }.buttonStyle(OrchButtonStyle(kind: .ghost)).disabled(sending)
                    .help("Remove this draft without sending it")
            }
        }
    }

    /// Every Brief row's menu: ask about the chat (a prefill only, never sent), then Dismiss.
    @ViewBuilder private func rowMenu(_ item: BriefItem) -> some View {
        if item.chatID != nil {
            Button("Ask the Orchestrator about this chat") {
                store.prefillOrchestratorQuestion(chatTitle: item.chatTitle ?? "", machine: item.machine)
            }
            Divider()
        }
        Button("Dismiss") { store.brief.dismiss(item) }
    }

    // MARK: Finished and stuck

    private func finishedRow(_ item: BriefItem) -> some View {
        Button { open(item) } label: {
            (Text(item.chatTitle ?? "A chat").font(.system(size: 13, weight: .semibold)).foregroundStyle(AppAppearance.text)
             + Text(" · " + item.headline).font(.system(size: 13)).foregroundStyle(AppAppearance.secondary))
                .lineLimit(2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 9).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!(closed(item)?.canOpen ?? true)).help(openHelp(closed(item)))
        .contextMenu { rowMenu(item) }
    }

    private func stuckCard(_ item: BriefItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.chatTitle ?? "A chat").font(.system(size: 13, weight: .semibold)).foregroundStyle(AppAppearance.text).lineLimit(1)
                Text([item.headline, item.machine].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(AppAppearance.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            openButton(item, closed: closed(item), kind: .ghost)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .modifier(OrchCard())
        .contextMenu { rowMenu(item) }
    }

    private func emptyCard(_ brief: OrchestratorBriefStore) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            OrchSectionLabel(title: "Brief", dot: nil)
            Text(brief.autoTriage ? "Nothing needs you. Triage reads each chat when it stops and lists what it finds here."
                                  : "Automatic triage is off, so nothing new is read. Turn it on in Budget to keep this current.")
                .font(.system(size: 13)).foregroundStyle(AppAppearance.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .modifier(OrchCard())
    }

    // MARK: Helpers

    private func open(_ item: BriefItem) {
        guard let id = item.chatID else { return }
        Task { await store.openChat(id: id) }
    }

    /// How an item whose chat isn't in Burro's list is drawn (nil: Open shows it in Burro).
    private func closed(_ item: BriefItem) -> ClosedChatState? {
        item.chatID == nil ? nil : store.closedState(chatID: item.chatID)
    }

    private func openHelp(_ closed: ClosedChatState?) -> String {
        guard let closed else { return "Open this chat" }
        return closed.canOpen ? "Open this chat in the Claude app; it has left Burro's list" : (closed.line ?? "")
    }

    /// Open, "Open in Claude" for a closed chat the Claude app still has, nothing when Burro can't open it.
    @ViewBuilder private func openButton(_ item: BriefItem, closed: ClosedChatState?, kind: OrchButtonStyle.Kind) -> some View {
        if closed?.canOpen ?? true {
            Button(closed?.openTitle ?? "Open") { open(item) }.buttonStyle(OrchButtonStyle(kind: kind)).help(openHelp(closed))
        }
    }

    /// Of the Brief's chats, the ones Burro's list doesn't hold, to look up Claude app links for.
    private func unlisted(_ brief: OrchestratorBriefStore) -> [String] {
        store.unlistedChatIDs((brief.needsYou + brief.finished.prefix(8) + brief.stuck).compactMap(\.chatID))
    }

    /// Marks each finished chat read in Burro (its own "seen" mark) and resolves its item.
    private func markRead(_ items: [BriefItem]) {
        let sessions = store.notchChatSessions
        var changed = false
        for item in items {
            if let id = item.chatID, let session = sessions.first(where: { $0.id == id }) {
                changed = ChatLocalStore.shared.markSeen(session) || changed
            }
            store.brief.dismiss(item)
        }
        if changed { Task { await store.refreshAgents() } }
    }

    private func blockedReason(_ action: OrchestratorAction) -> String? {
        guard let (session, host) = store.orchestratorTarget(action) else { return "Burro can't see this chat right now." }
        return ChatReply.unavailable(session, host: host)
    }

    /// "now", "4 min", "2 h", "3 d".
    nonisolated static func age(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h" }
        return "\(Int(seconds / 86_400)) d"
    }
}

// MARK: Small shared pieces of this page

/// "NEEDS YOU · 2" with its status dot.
struct OrchSectionLabel: View {
    var title: String
    var dot: Color?
    var tint: Color = AppAppearance.tertiary
    var body: some View {
        HStack(spacing: 8) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8).accessibilityHidden(true) }
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(tint)
        }
    }
}

/// The page's flat cards: surface fill and a hairline, no shadow.
struct OrchCard: ViewModifier {
    var stroke: Color = AppAppearance.separator
    var fill: Color = AppAppearance.surface
    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(stroke))
    }
}

/// A sunken text area inside a card (drafts, the composer, the note field).
struct OrchField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(AppAppearance.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AppAppearance.separator))
    }
}

/// Small buttons: amber for the one action that sends, bordered, or ghost.
struct OrchButtonStyle: ButtonStyle {
    enum Kind { case primary, bordered, ghost }
    var kind: Kind
    var large = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 13 : 12, weight: .semibold))
            .foregroundStyle(kind == .primary ? OrchestratorStyle.onGold : AppAppearance.text)
            .padding(.horizontal, large ? 12 : 9).frame(height: large ? 28 : 24)
            .background {
                let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                switch kind {
                case .primary: shape.fill(AppAppearance.amber)
                case .bordered: shape.fill(AppAppearance.raised)
                case .ghost: shape.fill(configuration.isPressed ? AppAppearance.hover : .clear)
                }
            }
            .overlay {
                if kind != .primary { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AppAppearance.hairline) }
            }
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}
