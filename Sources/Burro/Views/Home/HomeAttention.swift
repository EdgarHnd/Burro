// Home's chat data and the Needs-you card. HomeBoard (BurroCore) decides what goes where, so
// nothing is listed twice; Home's queue panel (HomeQueuePanel.swift) shows it in three tabs and
// Today's queue shows the Needs-you cards:
// - Needs you (amber): per chat: title, machine · folder and agent · model tags, how long it has
//   waited, the question triage found or "Waiting for your approval", then either the drafted reply
//   inline (triage's, or a reply the Orchestrator proposed) with Send / Edit / Open and a Discard
//   button on the draft, or Open plus the one hand-off that works (Open in Codex / Open in Claude).
//   Send uses the proposal card's own path (`sendOrchestratorAction`: an idle Claude background
//   session is stopped and continued with the reply, as its help says); Edit opens that proposal
//   card in place. A draft whose Send Burro couldn't confirm offers no Send: it says it may have
//   reached the chat, and Edit opens the card with Send again… (behind a confirmation). Waiting
//   sub-agents never get a card. Right-click a triaged card to Dismiss the Brief item. A Brief item
//   whose chat has left Burro's list (a chat on this Mac that closed) is tagged "Closed" (another
//   machine's: "Not listed"): its one button is "Open in Claude" when the Claude app still has the
//   chat (ClosedChatLinks looks it up), else there is no open button, a line says Burro can't open
//   it, and Dismiss is a visible button. Open goes through `AppStore.openChat(id:)`. Burro can't
//   answer an approval itself, so it never draws Approve / Deny.
// - Working: title, state line (working in which folder, or the Brief's Stuck line), machine, how
//   long the turn has run when Burro saw it begin (TurnClock) or when it last wrote, and what
//   `HomeBoard.stopOffer` allows (Stop, Open in Claude, "Stop it in its terminal").
// - Ready to read: the one-line outcome (the Brief's Finished headline, else the preview an earlier
//   scan already has) and the time.
// The values are plain so the views can be rendered offscreen; HomeView's `HomeLivePage` maps the store onto them.
import AppKit
import SwiftUI
import BurroCore

// MARK: Plain values

struct HomeDraftData: Equatable {
    var text: String
    var label: String
    var sending = false
    /// The send's confirmation once it went.
    var sent: String?
    /// Why it can't be sent right now.
    var blocked: String?
    var error: String?
    var sendHelp: String
}

struct HomeNeedsCardData: Identifiable, Equatable {
    var id: String
    var title: String
    var tags: [String]
    var when: String
    var message: String
    var draft: HomeDraftData?
    /// "Open in Codex" / "Open in Claude" when the provider has a link for this chat.
    var handOff: String?
    var dismissable: Bool
    /// Set when the chat isn't in Burro's list (a Brief item for a chat that has closed).
    var closed: ClosedChatState? = nil
}

struct HomeWorkingCardData: Identifiable, Equatable {
    var id: String
    var title: String
    var state: String
    var machine: String
    var time: String
    var stop: HomeBoard.StopOffer
    var handOff: String?
    var stopping = false
    var note: String?
    /// The Brief found it stuck: a grey dot, its line as the state.
    var stuck = false
}

struct HomeReadRowData: Identifiable, Equatable {
    var id: String
    var title: String
    var outcome: String?
    var time: String
}

struct HomeBoardData: Equatable {
    var needsYou: [HomeNeedsCardData] = []
    var needsTotal = 0
    var working: [HomeWorkingCardData] = []
    var workingTotal = 0
    var toRead: [HomeReadRowData] = []
    var toReadTotal = 0
    /// Before the first agent check.
    var checking = false
}

struct HomeBoardActions {
    var open: (String) -> Void = { _ in }
    var handOff: (String) -> Void = { _ in }
    var send: (String) -> Void = { _ in }
    var edit: (String) -> Void = { _ in }
    var discard: (String) -> Void = { _ in }
    var dismiss: (String) -> Void = { _ in }
    var stop: (String) -> Void = { _ in }
    var markAllRead: () -> Void = {}
    var showAll: () -> Void = {}
}

// MARK: Cards

/// A Needs-you card. On Home it is a card of its own; as the queue's decision card (`decision`,
/// HomeQueue.swift) it sits flat inside a panel: "agent · place" with a plain "Needs you" tag and the
/// wait on one grey line, then the bold title and one line of context, then the same draft, Send /
/// Edit / Discard and Open / hand-off controls as on Home.
struct HomeNeedsCard: View {
    var card: HomeNeedsCardData
    var actions: HomeBoardActions
    var editing: Bool
    var editor: (String) -> AnyView
    var decision = false

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            if decision {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(card.tags.reversed().joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text("Needs you").font(.system(size: 11, weight: .medium)).foregroundStyle(AppAppearance.amber).fixedSize()
                        when
                    }
                    Text(card.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppAppearance.text).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // Title row: wraps its tags under the title when the card is narrow.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { title; tags; Spacer(minLength: 8); when }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) { title; Spacer(minLength: 8); when }
                        HStack(spacing: 6) { tags }
                    }
                }
            }
            Text(card.message).font(.system(size: 13)).foregroundStyle(AppAppearance.secondary)
                .lineLimit(decision ? 2 : 3).fixedSize(horizontal: false, vertical: true)
                .help(card.message)
            if let draft = card.draft, draft.sent == nil {
                if editing {
                    editor(card.id)
                    Button("Done editing") { actions.edit(card.id) }
                        .buttonStyle(HomeButtonStyle(weight: .ghost, compact: true))
                } else {
                    draftRow(draft)
                }
            } else {
                if let sent = card.draft?.sent {
                    Label(sent, systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                }
                if let line = card.closed?.line {
                    Text(line).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if let closed = card.closed {
                        if closed.canOpen {
                            Button(closed.openTitle) { actions.open(card.id) }.buttonStyle(HomeButtonStyle(weight: .primary))
                                .help("This chat has left Burro's list; the Claude app still has it")
                        }
                        if card.dismissable {
                            Button("Dismiss") { actions.dismiss(card.id) }.buttonStyle(HomeButtonStyle(weight: closed.canOpen ? .ghost : .secondary))
                                .help("Remove this from the Brief")
                        }
                    } else if let handOff = card.handOff {
                        Button(handOff) { actions.handOff(card.id) }.buttonStyle(HomeButtonStyle(weight: .primary))
                            .help("Answer it there: Burro can't answer an approval itself")
                        Button("Open") { actions.open(card.id) }.buttonStyle(HomeButtonStyle(weight: .secondary)).help("Open this chat in Burro")
                    } else {
                        Button("Open") { actions.open(card.id) }.buttonStyle(HomeButtonStyle(weight: .primary)).help("Open this chat in Burro")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        Group {
            if decision {
                content.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                content.padding(.horizontal, 16).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(HomeCardSurface(attention: true))
            }
        }
        .contextMenu {
            if card.closed?.canOpen ?? true { Button(card.closed?.openTitle ?? "Open") { actions.open(card.id) } }
            if card.dismissable { Button("Dismiss") { actions.dismiss(card.id) } }
        }
    }

    private var title: some View {
        Text(card.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppAppearance.text).lineLimit(1)
            .layoutPriority(1)
    }
    private var tags: some View { ForEach(card.tags, id: \.self) { AppTag(text: $0) } }
    private var when: some View {
        Text(card.when).font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.tertiary).lineLimit(1).fixedSize()
    }

    private func draftRow(_ draft: HomeDraftData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) { field(draft).frame(minWidth: 300); buttons(draft) }
                VStack(alignment: .leading, spacing: 8) { field(draft); HStack(spacing: 8) { buttons(draft) } }
            }
            if let error = draft.error, !draft.sending {
                Label(error, systemImage: "exclamationmark.bubble").font(.system(size: 11.5)).foregroundStyle(AppAppearance.amber).lineLimit(2)
            } else if let blocked = draft.blocked {
                Text(blocked).font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary).lineLimit(2)
            }
        }
    }

    private func field(_ draft: HomeDraftData) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            (Text(draft.label + " · ").foregroundStyle(AppAppearance.tertiary) + Text(draft.text).foregroundStyle(AppAppearance.text))
                .font(.system(size: 13)).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { actions.discard(card.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(AppAppearance.tertiary).disabled(draft.sending)
            .help("Discard this draft without sending it").accessibilityLabel("Discard draft")
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 7)
        .background(AppAppearance.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AppAppearance.separator))
        .help(draft.text)
    }

    @ViewBuilder private func buttons(_ draft: HomeDraftData) -> some View {
        Button { actions.send(card.id) } label: {
            HStack(spacing: 5) {
                if draft.sending { ProgressView().controlSize(.mini) }
                Text(draft.sending ? "Sending…" : "Send")
            }
        }
        .buttonStyle(HomeButtonStyle(weight: .primary))
        .disabled(draft.sending || draft.blocked != nil)
        .help(draft.sendHelp)
        Button("Edit") { actions.edit(card.id) }.buttonStyle(HomeButtonStyle(weight: .secondary))
            .disabled(draft.sending).help("Edit the reply before sending")
        if card.closed?.canOpen ?? true {
            Button(card.closed?.openTitle ?? "Open") { actions.open(card.id) }.buttonStyle(HomeButtonStyle(weight: .ghost))
                .help(card.closed == nil ? "Open this chat in Burro" : "Open this chat in the Claude app")
        }
    }
}

// MARK: Store mapping

/// Home's board from the store: in-memory, from the feed, the Brief and today's scan. The queue's caps.
@MainActor enum HomeChatSections {
    static let needsCap = 5, workingCap = 6, readCap = 6

    static func board(store: AppStore, summary: HomeSummary) -> HomeBoard {
        HomeBoard.build(waiting: summary.needsYou, running: summary.running, unread: summary.unread,
                        briefNeeds: store.brief.needsYou, briefFinished: store.brief.finished, briefStuck: store.brief.stuck,
                        all: store.notchChatSessions, previews: previews(store))
    }

    /// Today's previews from the activity scan Burro already ran (the Chats list uses the same).
    private static func previews(_ store: AppStore) -> [String: String] {
        guard let activity = store.today.todayActivity ?? store.today.activity, Calendar.current.isDateInToday(activity.day) else { return [:] }
        var result: [String: String] = [:]
        for chat in activity.chats { if let text = ChatListPresentation.preview(chat.preview) { result[chat.id] = text } }
        return result
    }
}
