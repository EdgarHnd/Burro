// Every chat across your machines in one place, with the conversation readable inside Burro.
import SwiftUI
import BurroCore

struct ChatsView: View {
    @Bindable var store: AppStore
    @State private var query = ""

    var body: some View {
        let sessions = ChatsModel.sessions(store: store, query: query)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Chats").font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("\(sessions.count)").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                        Spacer()
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                        TextField("Search chats, projects, machines", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                    }
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(AppAppearance.surface, in: Capsule()).overlay(Capsule().strokeBorder(AppAppearance.separator))
                }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(ChatsModel.groups(sessions), id: \.title) { group in
                            Section {
                                ForEach(group.sessions) { session in
                                    ChatListRow(session: session, place: ChatsModel.place(session, store: store),
                                                selected: store.remoteSelection == session.id) { store.remoteSelection = session.id }
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
                        if sessions.isEmpty {
                            Text(query.isEmpty ? "No chats yet." : "No chats match.").font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary)
                                .frame(maxWidth: .infinity).padding(.top, 40)
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 16)
                }
            }
            .frame(width: 380)
            Rectangle().fill(AppAppearance.separator).frame(width: 1)
            Group {
                if let session = store.notchChatSessions.first(where: { $0.id == store.remoteSelection }) {
                    ChatDetail(store: store, session: session).id(session.id)
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
    static func groups(_ sessions: [AgentSession]) -> [(title: String, color: Color, sessions: [AgentSession])] {
        let needs = sessions.filter { $0.state == .waiting && $0.remote?.stale != true }
        let working = sessions.filter { $0.state == .working || $0.state == .scheduled }
        let unread = sessions.filter(\.isDone)
        let taken = Set((needs + working + unread).map(\.id))
        let recent = sessions.filter { !taken.contains($0.id) }.sorted { $0.updatedAt > $1.updatedAt }
        return [("Needs you", AppAppearance.amber, needs), ("Working", AppAppearance.green, working),
                ("Ready to read", AppAppearance.blue, unread), ("Recent", AppAppearance.tertiary, recent)].filter { !$0.2.isEmpty }
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
    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                AgentAvatar(session: session, active: selected || hovering, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).foregroundStyle(AppAppearance.text)
                    Text(place).font(.system(size: 11)).lineLimit(1).foregroundStyle(AppAppearance.tertiary)
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

    private var host: RemoteHost? { store.remoteHosts.first { $0.id == session.remote?.hostID } }
    private var media: ChatMediaSource? { session.remote == nil ? .local : host.map { .remote($0) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                AgentAvatar(session: session, active: true, working: session.state == .working, size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(loader.transcript?.title ?? session.title).font(.system(size: 18, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 8) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(statusText).font(.system(size: 12, weight: .medium)).foregroundStyle(statusColor)
                        Text("·").foregroundStyle(AppAppearance.tertiary)
                        Text("\(session.provider == .codex ? "Codex" : "Claude Code") · \(ChatsModel.place(session, store: store))")
                            .font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if loader.loading { ProgressView().controlSize(.small) }
                if let url = session.chatURL {
                    PillButton(title: "Open in \(session.provider == .codex ? "Codex" : "Claude")", symbol: "arrow.up.right") { NSWorkspace.shared.open(url) }
                }
                PillButton(title: "Refresh", symbol: "arrow.clockwise") { Task { await reload() } }
            }
            .padding(.horizontal, 26).padding(.vertical, 16)
            Rectangle().fill(AppAppearance.separator).frame(height: 1)
            Group {
                if let transcript = loader.transcript {
                    if transcript.messages.isEmpty {
                        AppEmptyState("No messages yet", symbol: "bubble.left", detail: "This chat hasn't said anything Burro can show.")
                    } else {
                        ChatTranscriptView(transcript: transcript, provider: session.provider, working: session.state == .working)
                            .environment(\.chatMediaSource, media)
                    }
                } else if let error = loader.error {
                    AppEmptyState("Can't show this chat", symbol: "exclamationmark.bubble", detail: error)
                } else {
                    ProgressView("Reading the conversation…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            ChatComposer(store: store, session: session, host: host) {
                followUntil = Date().addingTimeInterval(120)
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    await reload()
                    if session.remote == nil { await store.refreshAgents() } else { await store.refreshRemotes() }
                }
            }
        }
        .background(WindowOcclusionReader { onScreen = $0 })
        .task { await reload() }
        // Live chats refresh every few seconds while they're on screen.
        .task(id: onScreen) {
            while onScreen && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                if session.state == .working || session.state == .waiting || (followUntil.map { $0 > Date() } ?? false) { await reload() }
            }
        }
    }
    private func reload() async {
        await loader.load(session, host: host, profiles: store.usage.preferences.profiles)
    }
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
/// Each defaults to "keep what this chat uses".
private struct ChatComposer: View {
    @Bindable var store: AppStore
    var session: AgentSession
    var host: RemoteHost?
    var onSent: () -> Void
    @State private var text = ""
    @State private var access: ReplyAccess = .keep
    @State private var model = ""
    @State private var effort = ""
    @State private var sending = false
    @State private var notice: String?
    @State private var error: String?
    @State private var remoteModels: [LaunchModel]?
    /// Set when the chat can't take replies right now (Codex setup on its machine, or a Claude
    /// session that something still has open), found when the composer appears.
    @State private var remoteProblem: String?
    @State private var attachHandle: String?
    @FocusState private var focused: Bool

    private var agent: String { session.provider == .codex ? "Codex" : "Claude" }
    private var models: [LaunchModel] {
        session.provider == .claude ? LaunchModel.claude : (session.remote == nil ? store.codexModels : (remoteModels ?? []))
    }
    private var efforts: [String] {
        guard session.provider == .codex else { return LaunchModel.claudeEfforts }
        let chosen = models.first { $0.id == model } ?? models.first(where: \.isDefault) ?? models.first
        return chosen?.efforts.isEmpty == false ? chosen!.efforts : ["low", "medium", "high", "xhigh"]
    }

    var body: some View {
        let blocked = ChatReply.unavailable(session, host: host) ?? remoteProblem
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 8) {
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(AppAppearance.green)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(AppAppearance.amber).lineLimit(3)
            }
            VStack(alignment: .leading, spacing: 10) {
                if let blocked {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Label(blocked, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if let attachHandle, session.remote == nil {
                            Button("Attach in Terminal") {
                                store.open(LaunchResult(provider: .claude, sessionID: session.id, handle: attachHandle, folder: session.cwd))
                            }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppAppearance.blue)
                        }
                    }
                }
                TextField(blocked == nil ? "Reply to \(agent)…" : "Replies aren't available for this chat", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...8)
                    .focused($focused).onSubmit(send).disabled(blocked != nil || sending)
                HStack(spacing: 6) {
                    option(symbol: access.symbol, title: access == .keep ? "Access" : access.title) {
                        Picker("Access", selection: $access) {
                            ForEach(ReplyAccess.options(for: session.provider)) { option in
                                Text(option == .keep ? "Keep current access" : option.title).tag(option)
                            }
                        }.pickerStyle(.inline).labelsHidden()
                    }
                    Spacer(minLength: 8)
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
                    Button(action: send) {
                        Group {
                            if sending { ProgressView().controlSize(.small).tint(.white) }
                            else { Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)) }
                        }
                        .foregroundStyle(.white).frame(width: 32, height: 32)
                        .background(Circle().fill(empty || blocked != nil ? AppAppearance.tertiary.opacity(0.35) : AppAppearance.text))
                    }
                    .buttonStyle(.plain).disabled(empty || blocked != nil || sending)
                    .help(session.state == .working && session.provider == .codex ? "Send now; Codex takes it into the current turn" : "Send (Return)")
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(focused ? AppAppearance.secondary.opacity(0.35) : AppAppearance.separator))
            .shadow(color: AppAppearance.shadow, radius: 10, y: 3)
            .opacity(blocked == nil ? 1 : 0.75)
        }
        .frame(maxWidth: 840).frame(maxWidth: .infinity)
        .padding(.horizontal, 36).padding(.top, 8).padding(.bottom, 18)
        .task(id: session.id) { await loadModels() }
        .onChange(of: text) { _, _ in if !text.isEmpty { notice = nil } }
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
        if session.provider == .claude {
            let session = session, host = host
            let check = await Task.detached(priority: .utility) { ChatReply.claudeCheck(session, host: host) }.value
            remoteProblem = check.problem; attachHandle = check.attach
            return
        }
        if session.remote == nil { store.loadCodexModels(); return }
        guard remoteModels == nil, let host else { return }
        let result = await Task.detached(priority: .utility) { () -> Result<[LaunchModel], Error> in
            Result { try ChatReply.codexModels(host: host) }
        }.value
        switch result {
        case .success(let models): remoteModels = models; remoteProblem = nil
        case .failure(let failure):
            remoteModels = []
            remoteProblem = (failure as? LocalizedError)?.errorDescription
        }
    }

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !sending, ChatReply.unavailable(session, host: host) == nil, remoteProblem == nil else { return }
        sending = true; error = nil; notice = nil
        let request = ReplyRequest(text: message, model: model.isEmpty ? nil : model, effort: effort.isEmpty ? nil : effort, access: access)
        let session = session, host = host
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                Result { try ChatReply.send(request, to: session, host: host) }
            }.value
            sending = false
            switch result {
            case .success(let confirmation): notice = confirmation; text = ""; onSent()
            case .failure(let failure): error = (failure as? LocalizedError)?.errorDescription ?? "Couldn't send."
            }
        }
    }
}
