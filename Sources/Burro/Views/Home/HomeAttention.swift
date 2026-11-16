// Home's three chat sections under the greeting (they replace the old attention strip, the
// Brief card's Needs you / Finished / Stuck lists and the floating dock's avatars; HomeBoard in
// BurroCore decides what goes where, so nothing is listed twice):
// - Needs you (amber): one card per chat: title, machine · folder and agent · model tags, how long
//   it has waited, the question triage found or "Waiting for your approval", then either the
//   drafted reply inline (triage's, or a reply the Orchestrator proposed) with Send / Edit / Open
//   and a Discard button on the draft, or Open plus the one hand-off that works (Open in Codex /
//   Open in Claude). Send uses the proposal card's own path (`sendOrchestratorAction`: an idle
//   Claude background session is stopped and continued with the reply, as its help says); Edit
//   opens that proposal card in place. A draft whose Send Burro couldn't confirm offers no Send:
//   it says it may have reached the chat, and Edit opens the card with Send again… (behind a
//   confirmation). Waiting sub-agents never get a card. Right-click a triaged card to Dismiss the Brief item.
//   A Brief item whose chat has left Burro's list (a chat on this Mac that closed) is tagged
//   "Closed" (another machine's: "Not listed"): its one button is "Open in Claude" when the Claude
//   app still has the chat (ClosedChatLinks looks it up), else there is no open button, a line says
//   Burro can't open it, and Dismiss is a visible button. Open goes through `AppStore.openChat(id:)`.
//   Burro can't answer an approval itself, so it never draws Approve / Deny.
// - Working (green): a grid of compact cards: title, a state line (working in which folder, or
//   the Brief's Stuck line), the machine tag, how long the turn has run when Burro saw it begin
//   (TurnClock) or when it last wrote, and Stop where Burro can stop it (Codex turns, Claude
//   background sessions), decided as the Chats header decides it (HomeBoard.stopOffer over the
//   Claude open-session check NotchReplyChecks caches): a chat the Claude app owns gets "Open in
//   Claude" instead, one running in a terminal says "Stop it in its terminal", and a Claude chat
//   shows no Stop until its check has answered. Stop runs ChatReply.stop off the main thread on
//   that click only; its result line goes when the chat's turn changes.
// - Ready to read (blue): one card of rows with the one-line outcome (the Brief's Finished
//   headline, else the preview an earlier scan already has) and the time; Mark all read marks
//   them seen in Burro only (provider unread markers are never written).
// Each section shows a capped number, then "Show all N in Chats". The content view takes plain
// values so it can be rendered offscreen; `HomeChatSections` maps the store onto it.
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

// MARK: Content

struct HomeBoardContent: View {
    var data: HomeBoardData
    var actions: HomeBoardActions
    /// The needs-you card being edited, and the editor shown in its place.
    var editingID: String?
    var editor: (String) -> AnyView = { _ in AnyView(EmptyView()) }
    /// Working cards per row: three on a wide page, two or one when narrow.
    var columns = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if data.needsYou.isEmpty && data.working.isEmpty && data.toRead.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    Text(data.checking ? "Checking on your agents…" : "Nothing needs you and no agents are working.")
                }
                .font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary)
                .accessibilityElement(children: .combine)
            }
            if !data.needsYou.isEmpty { needsSection }
            if !data.working.isEmpty { workingSection }
            if !data.toRead.isEmpty { readSection }
        }
    }

    private var needsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionLabel(title: "Needs you", count: data.needsTotal, dot: AppAppearance.amber, tint: AppAppearance.amber)
            ForEach(data.needsYou) { card in
                HomeNeedsCard(card: card, actions: actions, editing: editingID == card.id, editor: editor)
            }
            more(data.needsTotal - data.needsYou.count)
        }
    }

    private var workingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionLabel(title: "Working", count: data.workingTotal, dot: AppAppearance.green)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: max(1, columns)),
                      alignment: .leading, spacing: 12) {
                ForEach(data.working) { card in HomeWorkingCard(card: card, actions: actions) }
            }
            more(data.workingTotal - data.working.count)
        }
    }

    private var readSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionLabel(title: "Ready to read", count: data.toReadTotal, dot: AppAppearance.blue) {
                Button("Mark all read", action: actions.markAllRead)
                    .buttonStyle(HomeButtonStyle(weight: .ghost, compact: true))
                    .help("Mark these results read in Burro (the providers' own unread markers are left alone)")
            }
            VStack(spacing: 0) {
                ForEach(Array(data.toRead.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Rectangle().fill(AppAppearance.separator).frame(height: 1).padding(.horizontal, 16) }
                    HomeReadRow(row: row) { actions.open(row.id) }
                }
            }
            .padding(.vertical, 4)
            .modifier(HomeCardSurface())
            more(data.toReadTotal - data.toRead.count)
        }
    }

    @ViewBuilder private func more(_ hidden: Int) -> some View {
        if hidden > 0 {
            Button("Show all \(hidden) more in Chats", action: actions.showAll)
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                .padding(.horizontal, 2).help("Open Chats")
        }
    }
}

// MARK: Cards

private struct HomeNeedsCard: View {
    var card: HomeNeedsCardData
    var actions: HomeBoardActions
    var editing: Bool
    var editor: (String) -> AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title row: wraps its tags under the title when the card is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { title; tags; Spacer(minLength: 8); when }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) { title; Spacer(minLength: 8); when }
                    HStack(spacing: 6) { tags }
                }
            }
            Text(card.message).font(.system(size: 13)).foregroundStyle(AppAppearance.secondary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
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
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(HomeCardSurface(attention: true))
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

private struct HomeWorkingCard: View {
    var card: HomeWorkingCardData
    var actions: HomeBoardActions
    @State private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { actions.open(card.id) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppAppearance.text).lineLimit(1)
                    Text(card.state).font(.system(size: 12.5)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Open this chat")
            HStack(spacing: 6) {
                AppTag(text: card.machine).fixedSize()
                // "active just now" / "turn 18 min"; where the action leaves too little room, the
                // same without its first word ("just now", "18 min"), then its shortest form
                // ("now", "18m", "4m ago"), so it is never cut mid-word. The full text is in the help.
                ViewThatFits(in: .horizontal) {
                    Text(card.time).fixedSize()
                    Text(card.time.split(separator: " ", maxSplits: 1).last.map(String.init) ?? card.time).fixedSize()
                    Text(HomeBoard.compactTime(card.time)).lineLimit(1)
                }
                .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                .help(card.time)
                Spacer(minLength: 4)
                control.fixedSize()
            }
            if let note = card.note {
                Text(note).font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? AppAppearance.hover : .clear, in: RoundedRectangle(cornerRadius: AppAppearance.cardRadius, style: .continuous))
        .modifier(HomeCardSurface())
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var control: some View {
        switch card.stop {
        case .stop:
            Button { actions.stop(card.id) } label: {
                HStack(spacing: 4) {
                    if card.stopping { ProgressView().controlSize(.mini) }
                    Text(card.stopping ? "Stopping…" : "Stop")
                }
            }
            .buttonStyle(HomeButtonStyle(weight: .ghost, compact: true)).disabled(card.stopping)
            .help("Stop this turn. The conversation is kept.").accessibilityLabel("Stop \(card.title)")
        case .openInProvider:
            if let handOff = card.handOff {
                Button(handOff) { actions.handOff(card.id) }.buttonStyle(HomeButtonStyle(weight: .ghost, compact: true))
                    .help("This chat runs in the Claude app or a terminal; only it can stop the chat")
            }
        case .elsewhere:
            Text("Stop it in its terminal").font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                .help("This chat runs interactively in a terminal; only it can stop the chat")
        case .none:
            EmptyView()
        }
    }
}

private struct HomeReadRow: View {
    var row: HomeReadRowData
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(row.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppAppearance.text).lineLimit(1)
                    .frame(maxWidth: 260, alignment: .leading)
                Text(row.outcome ?? "Finished").font(.system(size: 13))
                    .foregroundStyle(row.outcome == nil ? AppAppearance.tertiary : AppAppearance.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(row.time).font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.tertiary).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(hovering ? AppAppearance.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .help(row.outcome.map { "\(row.title)\n\($0)" } ?? "Open this chat")
        .accessibilityLabel("\(row.title), ready to read. \(row.outcome ?? "")")
    }
}

// MARK: Store mapping

/// Maps the live feed, the Brief and the Orchestrator's proposals onto `HomeBoardContent`, and runs
/// its actions. Every action is the owner's click; nothing here starts, messages or stops a chat
/// by itself.
struct HomeChatSections: View {
    @Bindable var store: AppStore
    var summary: HomeSummary
    var board: HomeBoard
    var columns = 3
    @State private var editing: String?
    @State private var stopping: Set<String> = []
    /// Stop's result line per chat, kept only while that chat's turn (HomeBoard.turnKey) is the same.
    @State private var notes: [String: (text: String, turn: String)] = [:]

    static let needsCap = 5, workingCap = 6, readCap = 6

    var body: some View {
        let now = Date()
        let claude = board.working.prefix(Self.workingCap).map(\.session).filter { $0.provider == .claude }
        let unlisted = store.unlistedChatIDs(board.needsYou.prefix(Self.needsCap).filter { $0.session == nil }.compactMap { $0.item?.chatID })
        HomeBoardContent(data: data(board, now: now), actions: actions(board), editingID: editing,
                         editor: { id in
                             guard let action = draftAction(board.needsYou.first { $0.id == id }) else { return AnyView(EmptyView()) }
                             return AnyView(OrchestratorActionCard(store: store, action: action))
                         }, columns: columns)
            // The Claude open-session checks Stop is decided by, shared with the notch and cached
            // for a minute per chat and state; run only for the working cards shown.
            .task(id: claude.map { "\($0.id)|\($0.state.rawValue)" }) {
                for session in claude { await NotchReplyChecks.shared.refresh(session, host: host(session)) }
            }
            // Claude app links for Brief items whose chat has left Burro's list (closed chats).
            .task(id: unlisted) { await ClosedChatLinks.shared.refresh(unlisted) }
    }

    private func host(_ session: AgentSession) -> RemoteHost? { store.remoteHosts.first { $0.id == session.remote?.hostID } }
    private func turnKey(_ session: AgentSession) -> String {
        HomeBoard.turnKey(session, turnStart: store.turnClock.starts[session.id])
    }

    /// The sections' contents: in-memory, from the feed, the Brief and today's scan.
    static func board(store: AppStore, summary: HomeSummary) -> HomeBoard {
        HomeBoard.build(waiting: summary.needsYou, running: summary.running, unread: summary.unread,
                        briefNeeds: store.brief.needsYou, briefFinished: store.brief.finished, briefStuck: store.brief.stuck,
                        all: store.notchChatSessions, previews: previews(store))
    }

    /// Today's previews from the activity scan Burro already ran (the Chats list uses the same).
    private static func previews(_ store: AppStore) -> [String: String] {
        guard let activity = store.today.activity, Calendar.current.isDateInToday(activity.day) else { return [:] }
        var result: [String: String] = [:]
        for chat in activity.chats { if let text = ChatListPresentation.preview(chat.preview) { result[chat.id] = text } }
        return result
    }

    private func data(_ board: HomeBoard, now: Date) -> HomeBoardData {
        HomeBoardData(
            needsYou: board.needsYou.prefix(Self.needsCap).map { needsCard($0, now: now) }, needsTotal: board.needsYou.count,
            working: board.working.prefix(Self.workingCap).map { workingCard($0, now: now) }, workingTotal: board.working.count,
            toRead: board.toRead.prefix(Self.readCap).map {
                HomeReadRowData(id: $0.id, title: $0.session.title, outcome: $0.outcome, time: HomeTime.clock($0.session.updatedAt, now: now))
            },
            toReadTotal: board.toRead.count, checking: !store.didCheckAgents)
    }

    private func needsCard(_ entry: HomeBoard.NeedsYou, now: Date) -> HomeNeedsCardData {
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

    private func workingCard(_ entry: HomeBoard.Working, now: Date) -> HomeWorkingCardData {
        let session = entry.session
        let folder = URL(fileURLWithPath: session.remote == nil ? store.workspacePath(for: session) : session.cwd).lastPathComponent
        let state = entry.stuck?.headline ?? (folder.isEmpty ? "Working" : "Working in \(folder)")
        let time = store.turnClock.turn(session.id, now: now).map(HomeBoard.turnText) ?? HomeBoard.activeText(session.updatedAt, now: now)
        let note = notes[session.id].flatMap { $0.turn == turnKey(session) ? $0.text : nil }
        return HomeWorkingCardData(id: session.id, title: session.title, state: state, machine: machine(session), time: time,
                                   stop: HomeBoard.stopOffer(session, host: host(session), check: NotchReplyChecks.shared.check(for: session)),
                                   handOff: handOffTitle(session), stopping: stopping.contains(session.id), note: note)
    }

    // MARK: Actions

    private func actions(_ board: HomeBoard) -> HomeBoardActions {
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
                guard let action = draftAction(needs(id)) else { return }
                let text = action.text
                Task { await store.sendOrchestratorAction(action, text: text) }
            },
            edit: { id in editing = editing == id ? nil : id },
            discard: { id in if let action = draftAction(needs(id)) { store.orchestrator.discard(action) } },
            dismiss: { id in if let item = needs(id)?.item { store.brief.dismiss(item) } },
            stop: { id in if let session = session(id) { stop(session) } },
            markAllRead: {
                // Burro's own "seen"; the providers' unread markers are never written.
                var changed = false
                for entry in board.toRead { changed = ChatLocalStore.shared.markSeen(entry.session) || changed }
                if changed { store.rebuildAgentActivity() }
            },
            showAll: { store.search = ""; store.page = .remote })
    }

    private func stop(_ session: AgentSession) {
        guard !stopping.contains(session.id) else { return }
        stopping.insert(session.id); notes[session.id] = nil
        let host = host(session), turn = turnKey(session)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                Result { try ChatReply.stop(session, host: host) }
            }.value
            stopping.remove(session.id)
            switch result {
            case .success(let confirmation): notes[session.id] = (confirmation, turn); await store.refreshAgents()
            case .failure(let failure): notes[session.id] = ((failure as? LocalizedError)?.errorDescription ?? "Couldn't stop it.", turn)
            }
            NotchReplyChecks.shared.invalidate(session.id)
        }
    }

    // MARK: Helpers

    /// Triage's own draft for the item (also once sent), else a reply the Orchestrator proposed for this chat.
    private func draftAction(_ entry: HomeBoard.NeedsYou?) -> OrchestratorAction? {
        guard let entry else { return nil }
        let actions = store.orchestrator.actions
        let chatID = entry.item?.chatID ?? entry.session?.id
        guard let action = entry.item?.proposalID.flatMap({ id in actions.first { $0.id == id } })
                ?? chatID.flatMap({ store.brief.draft(chatID: $0, actions: actions) }) else { return nil }
        return action.status == .sent || action.isUnconfirmed || action.isWaiting() ? action : nil
    }

    private func draftData(_ action: OrchestratorAction) -> HomeDraftData {
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

    private func handOffTitle(_ session: AgentSession) -> String? {
        guard session.chatURL != nil else { return nil }
        return session.provider == .codex ? "Open in Codex" : "Open in Claude"
    }

    private func machine(_ session: AgentSession) -> String {
        session.remote?.hostName ?? summary.machines.first { $0.connection == .local }?.name ?? "This Mac"
    }

    /// "machine · folder".
    private func place(_ session: AgentSession) -> String {
        let folder = URL(fileURLWithPath: session.remote == nil ? store.workspacePath(for: session) : session.cwd).lastPathComponent
        return [machine(session), folder.isEmpty ? nil : folder].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Claude · Opus 5.5", "Codex · gpt-5.5", or just the agent when the model isn't recorded.
    private func agent(_ session: AgentSession) -> String {
        let name = session.provider == .codex ? "Codex" : "Claude"
        return AquariumFish.modelName(session.model).map { "\(name) · \($0)" } ?? name
    }
}
