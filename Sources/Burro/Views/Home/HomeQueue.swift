// The attention queue, shared by Home and Today, and the one place Needs-you cards are built.
// - `HomeNeedsBuilder` maps Home's board (HomeBoard, BurroCore) onto `HomeNeedsCardData`: the title,
//   "machine · folder" and "agent · model" tags, how long it has waited, the question triage found
//   (else "Waiting for your approval"), the draft (triage's, or a reply the Orchestrator proposed)
//   and the one hand-off. Its `actions` hold the only Send a Needs-you card has: the proposal path,
//   `AppStore.sendOrchestratorAction`, unchanged; Edit opens the proposal card in place, Discard
//   drops the draft, Dismiss removes the Brief item. Home's sections and Today's queue both use it.
// - `AttentionQueue`: tabs with counts ("Waiting on you 2 | While you were away 3"), one shown at a time.
// - `NeedsQueueList`: the first card expanded as the decision card (HomeNeedsCard's flat style),
//   then compact rows (title, "agent · time"), then "N more waiting — View all ›" (opens Chats).
// Burro can't answer an approval, so there is no Approve / Deny and no single-key Send; nothing
// here sends without the Send button.
import AppKit
import SwiftUI
import BurroCore

// MARK: Building cards

@MainActor struct HomeNeedsBuilder {
    var store: AppStore

    func card(_ entry: HomeBoard.NeedsYou, now: Date) -> HomeNeedsCardData {
        var tags: [String] = []
        if let session = entry.session {
            tags.append(place(session))
            tags.append(agent(session))
        } else if let machine = entry.item?.machine {
            tags.append(machine)
        }
        let closed = entry.session == nil ? store.closedState(chatID: entry.item?.chatID) : nil
        if let closed { tags.append(closed.tag) }
        let message = entry.item.map { $0.question ?? $0.headline } ?? "Waiting for your approval"
        return HomeNeedsCardData(id: entry.id, title: entry.title, tags: tags,
                                 when: HomeBoard.waitText(entry.since, waiting: entry.waiting, now: now), message: message,
                                 draft: draftAction(entry).map(draftData), handOff: entry.session.flatMap(handOffTitle),
                                 dismissable: entry.item != nil, closed: closed)
    }

    /// The proposal card shown in place while a draft is being edited.
    func editor(_ entry: HomeBoard.NeedsYou?) -> AnyView {
        guard let action = draftAction(entry) else { return AnyView(EmptyView()) }
        return AnyView(OrchestratorActionCard(store: store, action: action))
    }

    /// Open, hand off, Send, Edit (through `toggleEdit`), Discard, Dismiss and Show all for the board's
    /// cards. Send is the proposal path and nothing else.
    func actions(_ board: HomeBoard, toggleEdit: @escaping (String) -> Void) -> HomeBoardActions {
        let store = self.store, builder = self
        func needs(_ id: String) -> HomeBoard.NeedsYou? { board.needsYou.first { $0.id == id } }
        func session(_ id: String) -> AgentSession? {
            needs(id)?.session ?? board.working.first { $0.id == id }?.session ?? board.toRead.first { $0.id == id }?.session
        }
        return HomeBoardActions(
            open: { id in
                if let session = session(id) { store.showChat(session); return }
                if let chat = needs(id)?.item?.chatID { Task { await store.openChat(id: chat) } }
            },
            handOff: { id in if let url = session(id)?.chatURL { NSWorkspace.shared.open(url) } },
            send: { id in
                guard let action = builder.draftAction(needs(id)) else { return }
                let text = action.text
                Task { await store.sendOrchestratorAction(action, text: text) }
            },
            edit: toggleEdit,
            discard: { id in if let action = builder.draftAction(needs(id)) { store.orchestrator.discard(action) } },
            dismiss: { id in if let item = needs(id)?.item { store.brief.dismiss(item) } },
            showAll: { store.search = ""; store.page = .remote })
    }

    /// Triage's own draft for the item (also once sent), else a reply the Orchestrator proposed for this chat.
    func draftAction(_ entry: HomeBoard.NeedsYou?) -> OrchestratorAction? {
        guard let entry else { return nil }
        let actions = store.orchestrator.actions
        let chatID = entry.item?.chatID ?? entry.session?.id
        guard let action = entry.item?.proposalID.flatMap({ id in actions.first { $0.id == id } })
                ?? chatID.flatMap({ store.brief.draft(chatID: $0, actions: actions) }) else { return nil }
        return action.status == .sent || action.isUnconfirmed || action.isWaiting() ? action : nil
    }

    func draftData(_ action: OrchestratorAction) -> HomeDraftData {
        let sending = store.orchestrator.sendingActions.contains(action.id)
        // Unconfirmed: no one-click Send; Edit opens the card with Send again… behind a confirmation.
        let blocked: String? = action.isUnconfirmed ? action.unconfirmedNote
            : store.orchestratorTarget(action).map { ChatReply.unavailable($0.session, host: $0.host) }
            ?? "Burro can't see this chat right now."
        return HomeDraftData(text: action.text,
                             label: action.conversation == BriefDrafts.triageConversation ? "Draft" : "Proposed",
                             sending: sending, sent: action.status == .sent ? (action.result ?? "Sent") : nil,
                             blocked: blocked, error: action.isUnconfirmed ? nil : action.error,
                             sendHelp: ChatReply.cardSendHelp(provider: store.orchestratorTarget(action)?.session.provider))
    }

    func handOffTitle(_ session: AgentSession) -> String? {
        guard session.chatURL != nil else { return nil }
        return session.provider == .codex ? "Open in Codex" : "Open in Claude"
    }

    /// The machine's name; this Mac is "This Mac", as on Home's machines card.
    func machine(_ session: AgentSession) -> String { session.remote?.hostName ?? "This Mac" }

    /// "machine · folder".
    func place(_ session: AgentSession) -> String {
        let folder = URL(fileURLWithPath: session.remote == nil ? store.workspacePath(for: session) : session.cwd).lastPathComponent
        return [machine(session), folder.isEmpty ? nil : folder].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Claude · Opus 5.5", "Codex · gpt-5.5", or just the agent when the model isn't recorded.
    func agent(_ session: AgentSession) -> String {
        let name = session.provider == .codex ? "Codex" : "Claude"
        return AquariumFish.modelName(session.model).map { "\(name) · \($0)" } ?? name
    }
}

// MARK: Queue

struct AttentionQueueTab: Identifiable, Equatable {
    var id: String
    var title: String
    /// Used when the full titles don't fit on one line.
    var short: String? = nil
    var count: Int?
    /// Its count is amber while above zero.
    var needsYou = false
}

struct AttentionQueue<Content: View>: View {
    typealias Tab = AttentionQueueTab
    var tabs: [Tab]
    @Binding var selection: String
    @ViewBuilder var content: (String) -> Content

    var body: some View {
        let shown = tabs.contains { $0.id == selection } ? selection : (tabs.first?.id ?? "")
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                tabRow(shown, short: false)
                tabRow(shown, short: true)
            }
            content(shown)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func tabRow(_ shown: String, short: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0 { Rectangle().fill(AppAppearance.separator).frame(width: 1, height: 14).padding(.horizontal, 12) }
                tabButton(tab, selected: tab.id == shown, short: short)
            }
            Spacer(minLength: 0)
        }
    }

    private func tabButton(_ tab: Tab, selected: Bool, short: Bool) -> some View {
        Button { selection = tab.id } label: {
            HStack(spacing: 6) {
                Text(short ? tab.short ?? tab.title : tab.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                    .foregroundStyle(selected ? AppAppearance.text : AppAppearance.tertiary)
                if let count = tab.count {
                    Text("\(count)").font(.system(size: 13, weight: .medium)).monospacedDigit()
                        .foregroundStyle(tab.needsYou && count > 0 ? AppAppearance.amber : AppAppearance.tertiary).fixedSize()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(tabs.count < 2)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The Waiting on you tab: the first card as the decision card, compact rows after it, a footer.
struct NeedsQueueList: View {
    var cards: [HomeNeedsCardData]
    var total: Int
    var actions: HomeBoardActions
    var editingID: String?
    var editor: (String) -> AnyView = { _ in AnyView(EmptyView()) }
    var rows = 4
    /// Before the first agent check.
    var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let first = cards.first {
                HomeNeedsCard(card: first, actions: actions, editing: editingID == first.id, editor: editor, decision: true)
                    .padding(.bottom, 12)
                ForEach(cards.dropFirst().prefix(rows)) { card in
                    Rectangle().fill(AppAppearance.separator).frame(height: 1)
                    QueueRow(card: card, actions: actions)
                }
                let hidden = total - 1 - min(rows, cards.count - 1)
                if hidden > 0 {
                    Rectangle().fill(AppAppearance.separator).frame(height: 1)
                    Button { actions.showAll() } label: {
                        HStack(spacing: 4) {
                            Text("\(hidden) more waiting — View all")
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary).padding(.top, 10)
                    }
                    .buttonStyle(.plain).help("Open Chats")
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    Text(checking ? "Checking on your agents…" : "Nothing waits on you.")
                }
                .font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary).padding(.vertical, 4)
            }
        }
    }
}

/// A compact queue row: an amber dot, the title, "agent · time"; a click opens the chat, and the
/// card's other actions (hand-off, Dismiss) are in its context menu.
private struct QueueRow: View {
    var card: HomeNeedsCardData
    var actions: HomeBoardActions
    @State private var hovering = false
    var body: some View {
        Button { actions.open(card.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(AppAppearance.amber).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).font(.system(size: 13)).foregroundStyle(AppAppearance.text).lineLimit(1)
                    Text(([card.tags.last].compactMap { $0 } + [card.when]).joined(separator: " · "))
                        .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 9).padding(.horizontal, 6).contentShape(Rectangle())
            .background(hovering ? AppAppearance.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, -6)
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .help("\(card.title)\n\(card.message)\nClick to open the chat")
        .contextMenu {
            if card.closed?.canOpen ?? true { Button(card.closed?.openTitle ?? "Open") { actions.open(card.id) } }
            if let handOff = card.handOff, card.closed == nil { Button(handOff) { actions.handOff(card.id) } }
            if card.dismissable { Button("Dismiss") { actions.dismiss(card.id) } }
        }
    }
}
