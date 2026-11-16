// Every chat across your machines in one place, with the conversation readable inside Burro. Three
// panes: the list (a "Filter chats" field, / to focus it, matching titles, places, "claude",
// "codex" and model names; chats you just started; your pinned idle
// chats; Needs you, Working, Ready to read and Earlier), the open chat (header with its state, turn
// clock, Stop ⌘. and ⋯; the conversation, ending in a hand-off card while it waits on you; the
// Orchestrator's draft line; the composer) and the details panel when the window is wide enough.
// A chat opened by id that isn't in the list (one that closed, opened from the Brief or a
// notification) gets an explanation instead of a blank pane, with "Open in Claude" when the Claude
// app still has it.
import AppKit
import SwiftUI
import BurroCore

struct ChatsView: View {
    @Bindable var store: AppStore
    @State private var query = ""
    @FocusState private var filterFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                ChatsFilterField(query: $query, focused: $filterFocused)
                    .padding(.horizontal, 10).padding(.top, 12)
                ScrollView {
                    ChatsListRows(store: store, query: query)
                        .padding(.horizontal, 10).padding(.bottom, 16)
                }
            }
            .frame(width: ChatsModel.listWidth)
            Rectangle().fill(AppAppearance.separator).frame(width: 1)
            Group {
                if let session = store.notchChatSessions.first(where: { $0.id == store.remoteSelection }) {
                    ChatDetail(store: store, session: session).id(session.id)
                } else if let launch = store.pendingLaunches.launch(rowID: store.remoteSelection) {
                    PendingLaunchDetail(store: store, launch: launch)
                } else if let id = store.remoteSelection, id != Orchestrator.chatID, store.didCheckAgents {
                    // A chat opened by id (the Brief, a notification) that Burro's list doesn't hold.
                    ChatNotListedState(store: store, id: id)
                } else {
                    AppEmptyState("Pick a chat", symbol: "bubble.left.and.bubble.right",
                                  detail: "Read any Codex or Claude conversation from this Mac or your other machines.")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppAppearance.background)
        .onAppear {
            if store.remoteSelection == nil || store.remoteSelection == Orchestrator.chatID {
                let sessions = ChatLocalStore.shared.manage.arrange(ChatsModel.sessions(store: store, query: ""))
                store.remoteSelection = ChatsModel.sections(sessions).first?.sessions.first?.id
            }
        }
    }
}

/// The detail pane for a selected chat id Burro's list doesn't hold: why, and "Open in Claude" when
/// the Claude app still has the chat (looked up off the main thread by ClosedChatLinks).
private struct ChatNotListedState: View {
    @Bindable var store: AppStore
    var id: String

    private var detail: String {
        id.lowercased().hasPrefix("remote:")
            ? "Chats on your other machines appear here while Burro can reach them and they are open. Burro can't see this one right now."
            : "Chats on this Mac appear here while they are open in Claude or Codex. This one has closed, so Burro can't show it."
    }

    var body: some View {
        let link = ClosedChatLinks.shared.link(for: id)
        AppEmptyState(title: "This chat isn't in Burro's list", symbol: "bubble.left.and.exclamationmark.bubble.right",
                      detail: detail) {
            if let link {
                Button("Open in Claude") { NSWorkspace.shared.open(link) }
                    .buttonStyle(.borderedProminent).padding(.top, 4)
                    .help("Open this chat in the Claude app")
            }
        }
        .task(id: id) { await ClosedChatLinks.shared.refresh([id]) }
    }
}

/// The list under the filter: chats starting, then the sections. Sections and rows are worked out
/// together once a minute (and on every change), so row times, remote machines whose last check
/// has expired, and the section each row sits in always agree. Each row is identified by its
/// section as well as its chat, so a chat that moves section is drawn afresh, never a stale copy.
private struct ChatsListRows: View {
    @Bindable var store: AppStore
    var query: String
    @State private var showAllEarlier = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let sessions = ChatLocalStore.shared.manage.arrange(ChatsModel.sessions(store: store, query: query))
            let sections = ChatsModel.sections(sessions)
            let previews = ChatsModel.previews(store: store)
            LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                PendingLaunchRows(store: store)
                ForEach(sections, id: \.kind) { section in
                    let shown = shownCount(section)
                    Section {
                        ForEach(section.sessions.prefix(shown)) { session in
                            row(session, in: section.kind, previews: previews, now: timeline.date)
                                .id("\(section.kind.rawValue)|\(session.id)")
                        }
                        if shown < section.sessions.count {
                            ChatsShowAllRow(total: section.sessions.count) { showAllEarlier = true }
                        }
                    } header: {
                        if let title = section.title {
                            ChatsSectionHeader(title: title, count: section.sessions.count, color: ChatsModel.color(section.kind),
                                               emphasised: section.kind == .needsYou)
                        }
                    }
                }
                if sessions.isEmpty && store.pendingLaunches.isEmpty {
                    Text(query.isEmpty ? "No chats yet." : "No chats match.").font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
        }
    }

    /// Earlier shows its most recent chats until you ask for all (`ChatListEarlier`).
    private func shownCount(_ section: ChatListSection) -> Int {
        guard section.kind == .earlier else { return section.sessions.count }
        return ChatListEarlier.shown(total: section.sessions.count, filtering: !query.isEmpty, expanded: showAllEarlier,
                                     selectedIndex: section.sessions.firstIndex { $0.id == store.remoteSelection })
    }

    private func row(_ session: AgentSession, in kind: ChatListSection.Kind, previews: [String: String], now: Date) -> some View {
        let model = ChatListRow.make(session, in: kind, pinned: ChatLocalStore.shared.manage.isPinned(session.id),
                                     folder: ChatsModel.folder(session, store: store), preview: previews[session.id],
                                     now: now, calendar: .current)
        return ChatListRowView(row: model, selected: store.remoteSelection == session.id) { store.remoteSelection = session.id }
            .chatRowMenu(session, store: store)
    }
}

enum ChatsModel {
    /// The list's width: room for a title of about 40 characters beside the agent's avatar.
    static let listWidth: CGFloat = 340

    @MainActor static func sessions(store: AppStore, query: String) -> [AgentSession] {
        var seen = Set<String>()
        let all = store.notchChatSessions.filter { $0.isSubagent != true && seen.insert($0.id).inserted }
        let filtered = query.isEmpty ? all : all.filter { session in
            ChatListRow.matches(query, title: session.title, place: place(session, store: store), provider: session.provider, model: session.model)
        }
        return filtered.sorted { a, b in
            let (pa, pb) = (NotchGroup.priority(a), NotchGroup.priority(b))
            return pa != pb ? pa < pb : a.updatedAt > b.updatedAt
        }
    }
    /// Pinned idle chats, Needs you, Working, Ready to read, Earlier (`ChatListSection`).
    @MainActor static func sections(_ sessions: [AgentSession]) -> [ChatListSection] {
        let manage = ChatLocalStore.shared.manage
        return ChatListSection.sections(sessions, pinned: { manage.isPinned($0) })
    }
    static func color(_ kind: ChatListSection.Kind) -> Color {
        switch kind {
        case .needsYou: AppAppearance.amber
        case .working: AppAppearance.green
        case .readyToRead: AppAppearance.blue
        case .pinned, .earlier: AppAppearance.tertiary
        }
    }
    /// Today's already-scanned replies, cleaned, by chat id (chats on this Mac only: the scan reads
    /// this Mac's logs).
    @MainActor static func previews(store: AppStore) -> [String: String] {
        guard let activity = store.today.activity, Calendar.current.isDateInToday(activity.day) else { return [:] }
        var result: [String: String] = [:]
        for chat in activity.chats { if let text = ChatListPresentation.preview(chat.preview) { result[chat.id] = text } }
        return result
    }
    /// The chat's folder name.
    @MainActor static func folder(_ session: AgentSession, store: AppStore) -> String {
        URL(fileURLWithPath: session.remote == nil ? store.workspacePath(for: session) : session.cwd).lastPathComponent
    }
    /// The full place, "This Mac · focustown" or "Studio · focustown", for the header and the filter.
    @MainActor static func place(_ session: AgentSession, store: AppStore) -> String {
        let folder = folder(session, store: store)
        return [session.remote?.hostName ?? "This Mac", folder.isEmpty ? nil : folder].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct ChatDetail: View {
    var store: AppStore
    var session: AgentSession
    @State private var loader = TranscriptLoader()
    @State private var control = ChatControl()
    @State private var onScreen = false
    /// After you send a reply, keep refreshing for a while even before monitoring notices.
    @State private var followUntil: Date?
    @AppStorage("chats.inspector") private var showInspector = true

    private var host: RemoteHost? { store.remoteHosts.first { $0.id == session.remote?.hostID } }
    private var media: ChatMediaSource? { session.remote == nil ? .local : host.map { .remote($0) } }
    private var agent: String { session.provider == .codex ? "Codex" : "Claude" }

    var body: some View {
        let plan = control.plan(session, host: host, queued: ReplyQueueModel.shared.item(for: session.id) != nil)
        let checking = control.awaitingCheck(session, plan: plan)
        let status = ChatPageStatus.of(session)
        VStack(spacing: 0) {
            ChatHeaderBar(title: ChatLocalStore.shared.manage.title(for: session.id) ?? loader.transcript?.title ?? session.title,
                          status: status, agent: agentLine, place: ChatsModel.place(session, store: store),
                          turnStart: ChatTurnClock.start(loader.transcript?.messages ?? [], working: session.state == .working),
                          loading: loader.loading, stop: plan.stop, stopping: control.stopping, canOpen: session.chatURL != nil,
                          onStop: { if let stop = plan.stop { control.halt(stop, session: session, host: host, onStopped: afterSend) } },
                          showsInspector: showInspector,
                          toggleInspector: { withAnimation(.easeOut(duration: 0.18)) { showInspector.toggle() } }) {
                offlineLine
            } menu: {
                ChatHeaderMenu(store: store, session: session, refresh: { Task { await reload() } })
            }
            .marksChatSeen(session, store: store)
            Rectangle().fill(AppAppearance.separator).frame(height: 1)
            GeometryReader { geometry in
            HStack(spacing: 0) {
            VStack(spacing: 0) {
            Group {
                if let transcript = loader.transcript {
                    if transcript.messages.isEmpty {
                        AppEmptyState("No messages yet", symbol: "bubble.left", detail: "This chat hasn't said anything Burro can show.")
                    } else {
                        ChatTranscriptView(transcript: transcript, provider: session.provider, working: session.state == .working,
                                           showEarlier: loader.canShowEarlier ? { Task { await loader.loadEarlier(session, host: host, profiles: store.usage.preferences.profiles) } } : nil,
                                           loadingEarlier: loader.loadingEarlier,
                                           trailing: status == .needsYou && !checking ? AnyView(handoff(plan)) : nil)
                            .environment(\.chatMediaSource, media)
                    }
                } else if let error = loader.error {
                    AppEmptyState("Can't show this chat", symbol: "exclamationmark.bubble", detail: error)
                } else {
                    ProgressView("Reading the conversation…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            ChatDraftLine(store: store, session: session)
            ChatComposer(store: store, session: session, host: host, control: control,
                         handoffAction: status == .needsYou && loader.transcript?.messages.isEmpty == false
                            ? ChatHandoff.card(plan: plan, hasURL: session.chatURL != nil).action : nil,
                         onSent: afterSend, echo: { loader.echo($0) })
            }
            // The details panel, when there's room for it beside the conversation.
            if showInspector && geometry.size.width > 900 {
                ChatInspector(store: store, session: session, transcript: loader.transcript)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            }
            }
        }
        .background(WindowOcclusionReader { onScreen = $0 })
        .task { await reload() }
        // Live chats refresh while they're on screen: every 2 s on this Mac (an unchanged chat costs
        // the worker almost nothing), every second while a reply you sent hasn't been logged, and
        // every 4 s for another machine (only what was added travels; nothing when the file didn't
        // grow). A remote chat shown from Burro's copy because its machine was unreachable is caught
        // up as soon as monitoring reaches the machine again, and not asked before. One the machine
        // says it no longer has is asked again only on Refresh or when its row changes. The loop
        // restarts when the chat starts or stops working or its machine comes back or goes away.
        .task(id: TranscriptFollowKey(onScreen: onScreen, live: session.state == .working || session.state == .waiting, reachable: reachable)) {
            let live = session.state == .working || session.state == .waiting
            if session.remote != nil && reachable && loader.offline != nil { await reload() }
            while onScreen && !Task.isCancelled {
                let interval: Double = session.remote != nil ? 4 : (loader.awaitingEcho ? 1 : 2)
                try? await Task.sleep(for: .seconds(interval))
                if session.remote != nil, let offline = loader.offline {
                    if reachable && offline.retriesOnTimer { await reload() }
                    continue
                }
                if live || loader.awaitingEcho || (followUntil.map { $0 > Date() } ?? false) { await reload() }
            }
        }
        .onChange(of: session.updatedAt) { if loader.offline == .missing { Task { await reload() } } }
        .environment(\.chatWaiting, session.state == .waiting)
    }

    /// "Claude · Opus 5.5 · High effort".
    private var agentLine: String {
        [agent, AquariumFish.modelName(session.model), session.effort.map { "\(ChatInspector.effortTitle($0)) effort" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// A remote chat shown from Burro's copy while its machine can't be reached.
    @ViewBuilder private var offlineLine: some View {
        if let offline = loader.offline, let syncedAt = loader.syncedAt, let host {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(RemoteTranscriptMirror.asOfLine(syncedAt: syncedAt, machine: host.name, offline: offline,
                                                     poll: store.remotePollStatus(host.id), now: context.date))
                    .font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
            }
            .help(offline == .missing ? "\(host.name) no longer has this chat's transcript." : {
                if case .unreachable(let reason) = offline { return reason }; return ""
            }())
        }
    }

    private func handoff(_ plan: ComposerPlan) -> some View {
        ChatHandoffCard(card: ChatHandoff.card(plan: plan, hasURL: session.chatURL != nil), since: session.updatedAt,
                        agent: agent, machine: session.remote?.hostName) { perform($0) }
    }

    private func perform(_ action: ComposerPlan.Action) {
        switch action {
        case .openInProvider: if let url = session.chatURL { NSWorkspace.shared.open(url) }
        case .attachInTerminal(let handle):
            store.open(LaunchResult(provider: .claude, sessionID: session.id, handle: handle, folder: session.cwd))
        case .attachOnMachine(let handle):
            guard let host else { return }
            control.error = RemoteAttachOpener.open(host: host, handle: handle)
        case .queue: break
        }
    }

    /// After a send or stop: re-read soon, and keep following for a while.
    private func afterSend() {
        followUntil = Date().addingTimeInterval(120)
        Task {
            try? await Task.sleep(for: .seconds(2))
            await reload()
            if session.remote == nil { await store.refreshAgents() } else { await store.refreshRemotes() }
        }
    }

    private func reload() async {
        await loader.load(session, host: host, profiles: store.usage.preferences.profiles)
    }
    /// The chat's machine answered monitoring's last check (always true on this Mac).
    private var reachable: Bool { host.map { store.connection(for: $0).state == .online } ?? (session.remote == nil) }
}

/// Reply to the chat from Burro, with the choices its own app offers: access, model and effort.
/// A Claude chat's field appears once its open-session check has answered (a quiet bar holds the
/// place until then, and the hand-off card waits too), so it never flashes and turns into a reason.
/// Each defaults to "keep what this chat uses". While the chat works the composer stays open:
/// queue the message for when it's done or steer a Codex turn now (Stop, ⌘., is in the header,
/// from the same plan). When nothing can be typed, a compact bar says why with the single right
/// action, and there is no field. An idle Claude background session takes a reply: Send stops it and
/// continues it (its help says so). Files can be dropped, pasted or chosen for chats on this Mac.
/// Decisions: `ComposerPlan`; shared state with the header: `ChatControl`; layout: `ChatComposerBox`.
private struct ChatComposer: View {
    @Bindable var store: AppStore
    var session: AgentSession
    var host: RemoteHost?
    var control: ChatControl
    /// What the hand-off card above already offers (not repeated on the reason line).
    var handoffAction: ComposerPlan.Action?
    var onSent: () -> Void
    /// Called with the message text after a successful send or steer, for the transcript's
    /// optimistic "sending…" echo. The detail pane sets it (`TranscriptLoader.echo`).
    var echo: (String) -> Void = { _ in }
    @State private var text = ""
    @State private var access: ReplyAccess = .keep
    @State private var model = ""
    @State private var effort = ""
    @State private var sending = false
    @State private var attachments: [String] = []
    @State private var dropTargeted = false
    /// The text of a reply whose outcome couldn't be confirmed: taken out of the field so a second
    /// Send isn't one click away, but kept so "Put my text back" can return it.
    @State private var held: (text: String, attachments: [String])?
    @FocusState private var focused: Bool
    private let inserts = ComposerInserts.shared
    private var queue: ReplyQueueModel { .shared }

    private var agent: String { session.provider == .codex ? "Codex" : "Claude" }
    private var models: [LaunchModel] {
        session.provider == .claude ? LaunchModel.claude : (session.remote == nil ? store.codexModels : (control.remoteModels ?? []))
    }
    private var efforts: [String] {
        guard session.provider == .codex else { return LaunchModel.claudeEfforts }
        let chosen = models.first { $0.id == model } ?? models.first(where: \.isDefault) ?? models.first
        return chosen?.efforts.isEmpty == false ? chosen!.efforts : ["low", "medium", "high", "xhigh"]
    }
    private var plan: ComposerPlan { control.plan(session, host: host, queued: queue.item(for: session.id) != nil) }

    var body: some View {
        let plan = plan
        let checking = control.awaitingCheck(session, plan: plan)
        VStack(alignment: .leading, spacing: 8) {
            if let notice = control.notice {
                Label(notice, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(AppAppearance.green)
            }
            if let error = control.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(AppAppearance.amber).lineLimit(3)
            }
            // Offered for as long as the text is held, whatever happens to the message above it
            // (attaching or pasting clears that), so the reply is never lost.
            if let kept = held {
                Button("Put my text back") { text = kept.text; attachments = kept.attachments; held = nil }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                    .help("Returns the reply to the field. Check the chat first: it may already have arrived.")
            }
            if let item = queue.item(for: session.id) {
                QueuedReplyChip(item: item, sending: queue.sending.contains(session.id), edit: { editQueued() }, cancel: { queue.cancel(session.id) })
            } else if let last = queue.notice(for: session.id) {
                QueueNoticeLine(notice: last, edit: { text = last.text; queue.dismissNotice(session.id) }, dismiss: { queue.dismissNotice(session.id) })
            }
            ChatComposerBox(plan: plan, handoffAction: handoffAction, text: $text, focused: $focused, placeholder: placeholder(plan), sending: sending, dropTargeted: dropTargeted,
                            attachments: attachments, removeAttachment: { path in attachments.removeAll { $0 == path } },
                            agent: agent, machine: session.remote?.hostName, perform: perform,
                            submit: { submit(plan) }, send: send, steer: steer, enqueue: enqueue, checking: checking) {
                if plan.attachments && plan.canType { attachMenu }
                if plan.showPickers {
                    option(symbol: access.symbol, title: access == .keep ? "Access" : access.title) {
                        Picker("Access", selection: $access) {
                            ForEach(ReplyAccess.options(for: session.provider)) { option in
                                Text(option == .keep ? "Keep current access" : option.title).tag(option)
                            }
                        }.pickerStyle(.inline).labelsHidden()
                    }
                    option(symbol: nil, title: modelTitle) {
                        Picker("Model", selection: $model) {
                            Text("Keep current model").tag("")
                            ForEach(models) { Text($0.title).tag($0.id) }
                        }.pickerStyle(.inline).labelsHidden()
                    }
                    option(symbol: nil, title: effort.isEmpty ? "Effort" : "\(Self.effortTitle(effort)) effort") {
                        Picker("Effort", selection: $effort) {
                            Text("Keep current effort").tag("")
                            ForEach(efforts, id: \.self) { Text(Self.effortTitle($0)).tag($0) }
                        }.pickerStyle(.inline).labelsHidden()
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard plan.attachments && plan.canType else { return false }
                return ComposerFiles.dropped(providers) { add($0) }
            }
        }
        .frame(maxWidth: ChatColumn.width).frame(maxWidth: .infinity)
        .padding(.horizontal, ChatColumn.inset).padding(.top, 8).padding(.bottom, 16)
        .task(id: session.id) { await loadModels() }
        .task(id: "\(session.id)|\(session.state.rawValue)") { await control.recheckClaude(session, host: host) }
        .onChange(of: text) { _, _ in if !text.isEmpty { control.notice = nil } }
        // Text put in while the check ran (the draft line's Use) is waiting in the field when it appears.
        .onChange(of: checking) { _, now in if !now && !text.isEmpty && plan.canType { focused = true } }
        .onChange(of: inserts.latest) { _, insert in if let merged = insert?.merged(into: text, chatID: session.id) { text = merged; focused = true } }
    }

    private func placeholder(_ plan: ComposerPlan) -> String {
        if plan.canSend { return "Reply to \(agent)…" }
        return plan.canSteer ? "Steer \(agent) or queue a message…" : "Queue a message for when \(agent) is done…"
    }

    private var attachMenu: some View {
        Menu {
            Button("Choose Files…") { add(ComposerFiles.choose()) }
            Button("Paste File or Image") {
                do { add(try ComposerFiles.paste()) } catch { control.error = (error as? LocalizedError)?.errorDescription }
            }
        } label: { ComposerAttachLabel() }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Attach files or images (or drop them here)")
        .accessibilityLabel("Attach a file")
    }

    private func add(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let result = ChatAttachments.adding(paths, to: attachments)
        attachments = result.paths
        control.error = result.problem
    }

    private var modelTitle: String {
        guard !model.isEmpty else { return "Model" }
        return models.first { $0.id == model }?.title ?? model
    }
    static func effortTitle(_ value: String) -> String {
        switch value {
        case "xhigh": "Extra High"
        case "max": "Max"
        default: value.prefix(1).uppercased() + value.dropFirst()
        }
    }

    private func option<Content: View>(symbol: String?, title: String, @ViewBuilder content: () -> Content) -> some View {
        Menu { content() } label: { ComposerOptionLabel(symbol: symbol, title: title) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private func loadModels() async {
        guard session.provider == .codex else { return }
        if session.remote == nil { store.loadCodexModels(); return }
        guard control.remoteModels == nil, let host else { return }
        let result = await Task.detached(priority: .utility) { () -> Result<[LaunchModel], Error> in
            Result { try ChatReply.codexModels(host: host) }
        }.value
        switch result {
        case .success(let models): control.remoteModels = models; control.setupProblem = nil
        case .failure(let failure):
            control.remoteModels = []
            control.setupProblem = (failure as? LocalizedError)?.errorDescription
        }
    }

    private var request: ReplyRequest {
        ReplyRequest(text: text.trimmingCharacters(in: .whitespacesAndNewlines), model: model.isEmpty ? nil : model,
                     effort: effort.isEmpty ? nil : effort, access: access, attachments: attachments)
    }

    private func submit(_ plan: ComposerPlan) {
        if plan.canSend { send() } else if plan.canQueue { enqueue() }
    }

    private func send() {
        guard !request.text.isEmpty, !sending, plan.canSend else { return }
        // Stops this chat's idle Claude background session first only when the plan said so.
        let stops = plan.sendStopsFirst
        deliver { try ChatReply.send($0, to: $1, host: $2, stopIdleBackground: stops) }
    }

    private func steer() {
        guard !request.text.isEmpty, !sending, plan.canSteer else { return }
        deliver { try ChatReply.steer($0, to: $1, host: $2) }
    }

    private func deliver(_ call: @escaping @Sendable (ReplyRequest, AgentSession, RemoteHost?) throws -> String) {
        sending = true; control.error = nil; control.notice = nil; held = nil
        let request = request, session = session, host = host
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                Result { try call(request, session, host) }
            }.value
            sending = false
            switch result {
            case .success(let confirmation):
                control.notice = confirmation; text = ""; attachments = []
                echo(request.text)
                onSent()
                Task { await control.recheckClaude(session, host: host) }
            case .failure(let failure):
                control.error = (failure as? LocalizedError)?.errorDescription ?? "Couldn't send."
                // It may have reached the chat: the text isn't left ready for a one-click resend.
                if SendOutcome.isUnconfirmed(failure) { held = (text, attachments); text = ""; attachments = [] }
            }
        }
    }

    /// Queues the message (your explicit action for it); it goes when the chat is done.
    private func enqueue() {
        guard !request.text.isEmpty, plan.canQueue else { return }
        do {
            try queue.enqueue(request, for: session.id)
            text = ""; attachments = []; control.error = nil
            control.notice = "Queued. Burro sends it when \(agent) is done."
        } catch { control.error = (error as? LocalizedError)?.errorDescription }
    }

    private func editQueued() {
        guard let item = queue.cancel(session.id) else { return }
        text = item.text; attachments = item.attachments
        focused = true
    }

    private func perform(_ action: ComposerPlan.Action) {
        switch action {
        case .openInProvider: if let url = session.chatURL { NSWorkspace.shared.open(url) }
        case .attachInTerminal(let handle):
            store.open(LaunchResult(provider: .claude, sessionID: session.id, handle: handle, folder: session.cwd))
        case .attachOnMachine(let handle):
            guard let host else { return }
            control.error = RemoteAttachOpener.open(host: host, handle: handle)
        case .queue: enqueue()
        }
    }
}
