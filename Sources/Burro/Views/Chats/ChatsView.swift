// Every chat across your machines in one place, with the conversation readable inside Burro.
import SwiftUI
import BurroCore

struct ChatsView: View {
    @Bindable var store: AppStore
    @State private var query = ""

    var body: some View {
        let sessions = ChatLocalStore.shared.manage.arrange(ChatsModel.sessions(store: store, query: query))
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PageHeader(title: "Chats", subtitle: "\(sessions.count) chat\(sessions.count == 1 ? "" : "s")", inset: 20) { EmptyView() }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                        TextField("Search chats, projects, machines", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                    }
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(AppAppearance.surface, in: Capsule()).overlay(Capsule().strokeBorder(AppAppearance.separator))
                }.padding(.horizontal, 20).padding(.bottom, 12)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        PendingLaunchRows(store: store)
                        ForEach(ChatsModel.groups(sessions), id: \.title) { group in
                            Section {
                                ForEach(group.sessions) { session in
                                    ChatListRow(session: session, place: ChatsModel.place(session, store: store),
                                                selected: store.remoteSelection == session.id) { store.remoteSelection = session.id }
                                    .chatRowMenu(session, store: store)
                                }
                            } header: {
                                HStack(spacing: 6) {
                                    Circle().fill(group.color).frame(width: 6, height: 6)
                                    Text(group.title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.7)
                                    Text("\(group.sessions.count)").font(.system(size: 11)).monospacedDigit().opacity(0.6)
                                    Spacer()
                                }
                                .foregroundStyle(AppAppearance.tertiary).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
                                .background(AppAppearance.background)
                            }
                        }
                        if sessions.isEmpty && store.pendingLaunches.isEmpty {
                            Text(query.isEmpty ? "No chats yet." : "No chats match.").font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary)
                                .frame(maxWidth: .infinity).padding(.top, 40)
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 16)
                    .environment(\.chatListContext, ChatsModel.listContext(sessions, store: store))
                }
            }
            .frame(width: 380)
            Rectangle().fill(AppAppearance.separator).frame(width: 1)
            Group {
                if let session = store.notchChatSessions.first(where: { $0.id == store.remoteSelection }) {
                    ChatDetail(store: store, session: session).id(session.id)
                } else if let launch = store.pendingLaunches.launch(rowID: store.remoteSelection) {
                    PendingLaunchDetail(store: store, launch: launch)
                } else {
                    AppEmptyState("Pick a chat", symbol: "bubble.left.and.bubble.right",
                                  detail: "Read any Codex or Claude conversation from this Mac or your other machines.")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppAppearance.background)
        .onAppear {
            if store.remoteSelection == nil || store.remoteSelection == Orchestrator.chatID { store.remoteSelection = sessions.first?.id }
        }
    }
}

enum ChatsModel {
    @MainActor static func sessions(store: AppStore, query: String) -> [AgentSession] {
        var seen = Set<String>()
        let all = store.notchChatSessions.filter { $0.isSubagent != true && seen.insert($0.id).inserted }
        let filtered = query.isEmpty ? all : all.filter { session in
            [session.title, place(session, store: store)].contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return filtered.sorted { a, b in
            let (pa, pb) = (NotchGroup.priority(a), NotchGroup.priority(b))
            return pa != pb ? pa < pb : a.updatedAt > b.updatedAt
        }
    }
    @MainActor static func groups(_ sessions: [AgentSession]) -> [(title: String, color: Color, sessions: [AgentSession])] {
        let needs = sessions.filter { $0.state == .waiting && $0.remote?.stale != true }
        let working = sessions.filter { $0.state == .working || $0.state == .scheduled }
        let unread = sessions.filter(\.isDone)
        let taken = Set((needs + working + unread).map(\.id))
        // Newest first, with the chats you pinned kept on top.
        let recent = ChatLocalStore.shared.manage.arrange(sessions.filter { !taken.contains($0.id) }.sorted { $0.updatedAt > $1.updatedAt })
        return [("Needs you", AppAppearance.amber, needs), ("Working", AppAppearance.green, working),
                ("Ready to read", AppAppearance.blue, unread), ("Recent", AppAppearance.tertiary, recent)].filter { !$0.2.isEmpty }
    }
    /// Place tags shown only where they change within a section, and today's already-scanned previews.
    @MainActor static func listContext(_ sessions: [AgentSession], store: AppStore) -> ChatListContext {
        var context = ChatListContext()
        for group in groups(sessions) {
            let shows = ChatListPresentation.showsPlace(group.sessions.map { place($0, store: store) })
            for (session, show) in zip(group.sessions, shows) where !show { context.hiddenPlaces.insert(session.id) }
        }
        if let activity = store.today.activity, Calendar.current.isDateInToday(activity.day) {
            for chat in activity.chats { if let text = ChatListPresentation.preview(chat.preview) { context.previews[chat.id] = text } }
        }
        return context
    }
    @MainActor static func place(_ session: AgentSession, store: AppStore) -> String {
        let folder = URL(fileURLWithPath: session.remote == nil ? store.workspacePath(for: session) : session.cwd).lastPathComponent
        return [session.remote?.hostName ?? "This Mac", folder.isEmpty ? nil : folder].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct ChatListRow: View {
    var session: AgentSession
    var place: String
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.chatListContext) private var context
    var body: some View {
        let preview = context.previews[session.id]
        let showsPlace = !context.hiddenPlaces.contains(session.id)
        Button(action: action) {
            HStack(spacing: 11) {
                AgentAvatar(session: session, active: selected || hovering, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).foregroundStyle(AppAppearance.text)
                    if showsPlace || preview != nil {
                        HStack(spacing: 6) {
                            if showsPlace { Text(place).foregroundStyle(AppAppearance.tertiary).layoutPriority(1) }
                            if let preview { Text(preview).foregroundStyle(AppAppearance.secondary) }
                        }.font(.system(size: 11)).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(HomeFormat.ago(session.updatedAt)).font(.system(size: 11)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(selected ? AppAppearance.surface : (hovering ? AppAppearance.hover : .clear),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? AppAppearance.separator : .clear))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([session.title, statusText, place, preview].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
    }
    private var statusText: String {
        if session.state == .waiting { return "Needs you" }
        if session.state == .working { return "Working" }
        return session.isDone ? "Ready to read" : "Idle"
    }
    private var statusColor: Color {
        if session.state == .waiting { return AppAppearance.amber }
        if session.state == .working { return AppAppearance.green }
        if session.isDone { return AppAppearance.blue }
        return AppAppearance.tertiary.opacity(0.5)
    }
}

private struct ChatDetail: View {
    var store: AppStore
    var session: AgentSession
    @State private var loader = TranscriptLoader()
    @State private var onScreen = false
    /// After you send a reply, keep refreshing for a while even before monitoring notices.
    @State private var followUntil: Date?
    @AppStorage("chats.inspector") private var showInspector = true

    private var host: RemoteHost? { store.remoteHosts.first { $0.id == session.remote?.hostID } }
    private var media: ChatMediaSource? { session.remote == nil ? .local : host.map { .remote($0) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                AgentAvatar(session: session, active: true, working: session.state == .working, size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ChatLocalStore.shared.manage.title(for: session.id) ?? loader.transcript?.title ?? session.title).font(.system(size: 18, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 8) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(statusText).font(.system(size: 12, weight: .medium)).foregroundStyle(statusColor)
                        Text("·").foregroundStyle(AppAppearance.tertiary)
                        Text("\(session.provider == .codex ? "Codex" : "Claude Code") · \(ChatsModel.place(session, store: store))")
                            .font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
                    }
                    // A remote chat shown from Burro's copy while its machine can't be reached.
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
                Spacer()
                if loader.loading { ProgressView().controlSize(.small) }
                if let url = session.chatURL {
                    PillButton(title: "Open in \(session.provider == .codex ? "Codex" : "Claude")", symbol: "arrow.up.right") { NSWorkspace.shared.open(url) }
                }
                PillButton(title: "Refresh", symbol: "arrow.clockwise") { Task { await reload() } }
                ChatHeaderMenu(store: store, session: session)
                Button { withAnimation(.easeOut(duration: 0.18)) { showInspector.toggle() } } label: {
                    Image(systemName: "sidebar.right").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(showInspector ? AppAppearance.text : AppAppearance.secondary)
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(showInspector ? "Hide details" : "Show details")
            }
            .padding(.horizontal, 26).padding(.vertical, 16)
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
                                           loadingEarlier: loader.loadingEarlier)
                            .environment(\.chatMediaSource, media)
                    }
                } else if let error = loader.error {
                    AppEmptyState("Can't show this chat", symbol: "exclamationmark.bubble", detail: error)
                } else {
                    ProgressView("Reading the conversation…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            ChatDraftLine(store: store, session: session)
            ChatComposer(store: store, session: session, host: host, onSent: {
                followUntil = Date().addingTimeInterval(120)
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    await reload()
                    if session.remote == nil { await store.refreshAgents() } else { await store.refreshRemotes() }
                }
            }, echo: { loader.echo($0) })
            }
            // The details panel, when there's room for it beside the conversation.
            if showInspector && geometry.size.width > 980 {
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
    private func reload() async {
        await loader.load(session, host: host, profiles: store.usage.preferences.profiles)
    }
    /// The chat's machine answered monitoring's last check (always true on this Mac).
    private var reachable: Bool { host.map { store.connection(for: $0).state == .online } ?? (session.remote == nil) }
    private var statusColor: Color {
        session.state == .waiting ? AppAppearance.amber : (session.state == .working ? AppAppearance.green : (session.isDone ? AppAppearance.blue : AppAppearance.tertiary))
    }
    private var statusText: String {
        if session.state == .waiting { return "Needs you" }
        if session.state == .working { return "Working" }
        if session.isDone { return "Ready to read" }
        return "Idle"
    }
}

/// Reply to the chat from Burro, with the choices its own app offers: access, model and effort.
/// Each defaults to "keep what this chat uses". While the chat works the composer stays open:
/// queue the message for when it's done, steer a Codex turn now, or stop it (■, ⌘.). When a
/// reply can't go, one line says why with the single right action instead of the pickers. An idle
/// Claude background session takes a reply: Send stops it and continues it (its help says so).
/// Files can be dropped, pasted or chosen for chats on this Mac. Decisions: `ComposerPlan`.
private struct ChatComposer: View {
    @Bindable var store: AppStore
    var session: AgentSession
    var host: RemoteHost?
    var onSent: () -> Void
    /// Called with the message text after a successful send or steer, for the transcript's
    /// optimistic "sending…" echo. The detail pane sets it (`TranscriptLoader.echo`).
    var echo: (String) -> Void = { _ in }
    @State private var text = ""
    @State private var access: ReplyAccess = .keep
    @State private var model = ""
    @State private var effort = ""
    @State private var sending = false
    @State private var stopping = false
    @State private var notice: String?
    @State private var error: String?
    @State private var remoteModels: [LaunchModel]?
    /// Codex setup on the chat's machine that prevents replies, found when the composer appears.
    @State private var setupProblem: String?
    /// Whether something has this Claude session open (and how), rechecked as its state changes.
    @State private var check: ChatReply.ClaudeCheck?
    @State private var attachments: [String] = []
    @State private var dropTargeted = false
    @FocusState private var focused: Bool
    private let inserts = ComposerInserts.shared
    private var queue: ReplyQueueModel { .shared }

    private var agent: String { session.provider == .codex ? "Codex" : "Claude" }
    private var models: [LaunchModel] {
        session.provider == .claude ? LaunchModel.claude : (session.remote == nil ? store.codexModels : (remoteModels ?? []))
    }
    private var efforts: [String] {
        guard session.provider == .codex else { return LaunchModel.claudeEfforts }
        let chosen = models.first { $0.id == model } ?? models.first(where: \.isDefault) ?? models.first
        return chosen?.efforts.isEmpty == false ? chosen!.efforts : ["low", "medium", "high", "xhigh"]
    }
    private var plan: ComposerPlan {
        ChatReply.composerPlan(session, host: host, check: check, setupProblem: setupProblem,
                               queued: queue.item(for: session.id) != nil, hasURL: session.chatURL != nil)
    }

    var body: some View {
        let plan = plan
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let busy = !plan.canSend && (plan.canQueue || plan.canSteer || plan.stop != nil)
        VStack(alignment: .leading, spacing: 8) {
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(AppAppearance.green)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(AppAppearance.amber).lineLimit(3)
            }
            if let item = queue.item(for: session.id) {
                QueuedReplyChip(item: item, sending: queue.sending.contains(session.id), edit: { editQueued() }, cancel: { queue.cancel(session.id) })
            } else if let last = queue.notice(for: session.id) {
                QueueNoticeLine(notice: last, edit: { text = last.text; queue.dismissNotice(session.id) }, dismiss: { queue.dismissNotice(session.id) })
            }
            VStack(alignment: .leading, spacing: 10) {
                if let reason = plan.reason {
                    ComposerReasonLine(reason: reason, action: plan.action, agent: agent, machine: session.remote?.hostName) { perform($0) }
                }
                if !attachments.isEmpty { AttachmentChips(paths: attachments) { path in attachments.removeAll { $0 == path } } }
                TextField(placeholder(plan), text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...8)
                    .focused($focused).onSubmit { submit(plan) }.disabled(!plan.canType || sending)
                HStack(spacing: 6) {
                    if plan.showPickers {
                        option(symbol: access.symbol, title: access == .keep ? "Access" : access.title) {
                            Picker("Access", selection: $access) {
                                ForEach(ReplyAccess.options(for: session.provider)) { option in
                                    Text(option == .keep ? "Keep current access" : option.title).tag(option)
                                }
                            }.pickerStyle(.inline).labelsHidden()
                        }
                    }
                    if plan.attachments && plan.canType { attachMenu }
                    Spacer(minLength: 8)
                    if plan.showPickers {
                        option(symbol: "bolt.fill", title: modelTitle) {
                            Picker("Model", selection: $model) {
                                Text("Keep current model").tag("")
                                ForEach(models) { Text($0.title).tag($0.id) }
                            }.pickerStyle(.inline).labelsHidden()
                        }
                        option(symbol: nil, title: effort.isEmpty ? "Effort" : Self.effortTitle(effort)) {
                            Picker("Effort", selection: $effort) {
                                Text("Keep current effort").tag("")
                                ForEach(efforts, id: \.self) { Text(Self.effortTitle($0)).tag($0) }
                            }.pickerStyle(.inline).labelsHidden()
                        }
                    }
                    if busy {
                        if plan.canSteer {
                            ComposerPill(title: "Steer now", symbol: "arrow.turn.down.right", help: "Add this to the turn Codex is on now",
                                         enabled: !empty && !sending) { steer() }
                        }
                        if plan.canQueue {
                            ComposerPill(title: "Queue for when it's done", symbol: "clock", help: "Burro sends it when the chat finishes (Return)",
                                         enabled: !empty && !sending) { enqueue() }
                        }
                        if let stop = plan.stop {
                            ComposerStopButton(stop: stop, stopping: stopping, canOpen: session.chatURL != nil) { halt(stop) }
                        }
                    } else {
                        Button(action: send) {
                            Group {
                                if sending { ProgressView().controlSize(.small).tint(.white) }
                                else { Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)) }
                            }
                            .foregroundStyle(.white).frame(width: 32, height: 32)
                            .background(Circle().fill(empty || !plan.canSend ? AppAppearance.tertiary.opacity(0.35) : AppAppearance.text))
                        }
                        .buttonStyle(.plain).disabled(empty || !plan.canSend || sending)
                        .help(ChatReply.sendHelp(plan))
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(dropTargeted ? AppAppearance.blue.opacity(0.6) : (focused ? AppAppearance.secondary.opacity(0.35) : AppAppearance.separator)))
            .shadow(color: AppAppearance.shadow, radius: 10, y: 3)
            .opacity(plan.canType ? 1 : 0.75)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard plan.attachments && plan.canType else { return false }
                return ComposerFiles.dropped(providers) { add($0) }
            }
        }
        .frame(maxWidth: 840).frame(maxWidth: .infinity)
        .padding(.horizontal, 36).padding(.top, 8).padding(.bottom, 18)
        .task(id: session.id) { await loadModels() }
        .task(id: "\(session.id)|\(session.state.rawValue)") { await recheckClaude() }
        .onChange(of: text) { _, _ in if !text.isEmpty { notice = nil } }
        .onChange(of: inserts.latest) { _, insert in if let merged = insert?.merged(into: text, chatID: session.id) { text = merged; focused = true } }
    }

    private func placeholder(_ plan: ComposerPlan) -> String {
        if !plan.canType { return "Replies aren't available for this chat" }
        if plan.canSend { return "Reply to \(agent)…" }
        return plan.canSteer ? "Steer \(agent) or queue a message…" : "Queue a message for when \(agent) is done…"
    }

    private var attachMenu: some View {
        Menu {
            Button("Choose Files…") { add(ComposerFiles.choose()) }
            Button("Paste File or Image") {
                do { add(try ComposerFiles.paste()) } catch { self.error = (error as? LocalizedError)?.errorDescription }
            }
        } label: {
            Image(systemName: "paperclip").font(.system(size: 12, weight: .semibold)).foregroundStyle(AppAppearance.secondary)
                .frame(width: 28, height: 28).background(AppAppearance.raised.opacity(0.6), in: Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Attach files or images (or drop them here)")
    }

    private func add(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let result = ChatAttachments.adding(paths, to: attachments)
        attachments = result.paths
        error = result.problem
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
        Menu { content() } label: {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.6)
            }
            .foregroundStyle(AppAppearance.secondary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(AppAppearance.raised.opacity(0.6), in: Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private func loadModels() async {
        guard session.provider == .codex else { return }
        if session.remote == nil { store.loadCodexModels(); return }
        guard remoteModels == nil, let host else { return }
        let result = await Task.detached(priority: .utility) { () -> Result<[LaunchModel], Error> in
            Result { try ChatReply.codexModels(host: host) }
        }.value
        switch result {
        case .success(let models): remoteModels = models; setupProblem = nil
        case .failure(let failure):
            remoteModels = []
            setupProblem = (failure as? LocalizedError)?.errorDescription
        }
    }

    /// Whether something has this Claude session open, again whenever its state changes.
    private func recheckClaude() async {
        guard session.provider == .claude else { return }
        let session = session, host = host
        check = await Task.detached(priority: .utility) { ChatReply.claudeCheck(session, host: host) }.value
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
        sending = true; error = nil; notice = nil
        let request = request, session = session, host = host
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                Result { try call(request, session, host) }
            }.value
            sending = false
            switch result {
            case .success(let confirmation):
                notice = confirmation; text = ""; attachments = []
                echo(request.text)
                onSent()
                Task { await recheckClaude() }
            case .failure(let failure): error = (failure as? LocalizedError)?.errorDescription ?? "Couldn't send."
            }
        }
    }

    /// Queues the message (your explicit action for it); it goes when the chat is done.
    private func enqueue() {
        guard !request.text.isEmpty, plan.canQueue else { return }
        do {
            try queue.enqueue(request, for: session.id)
            text = ""; attachments = []; error = nil
            notice = "Queued. Burro sends it when \(agent) is done."
        } catch { self.error = (error as? LocalizedError)?.errorDescription }
    }

    private func editQueued() {
        guard let item = queue.cancel(session.id) else { return }
        text = item.text; attachments = item.attachments
        focused = true
    }

    private func halt(_ stop: ChatStop) {
        if stop == .elsewhere { if let url = session.chatURL { NSWorkspace.shared.open(url) }; return }
        guard !stopping else { return }
        stopping = true; error = nil; notice = nil
        let session = session, host = host
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                Result { try ChatReply.stop(session, host: host) }
            }.value
            stopping = false
            switch result {
            case .success(let confirmation): notice = confirmation; onSent()
            case .failure(let failure): error = (failure as? LocalizedError)?.errorDescription ?? "Couldn't stop it."
            }
        }
    }

    private func perform(_ action: ComposerPlan.Action) {
        switch action {
        case .openInProvider: if let url = session.chatURL { NSWorkspace.shared.open(url) }
        case .attachInTerminal(let handle):
            store.open(LaunchResult(provider: .claude, sessionID: session.id, handle: handle, folder: session.cwd))
        case .attachOnMachine(let handle):
            guard let host else { return }
            error = RemoteAttachOpener.open(host: host, handle: handle)
        case .queue: enqueue()
        }
    }
}
