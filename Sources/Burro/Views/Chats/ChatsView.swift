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
                        ChatTranscriptView(transcript: transcript, provider: session.provider)
                    }
                } else if let error = loader.error {
                    AppEmptyState("Can't show this chat", symbol: "exclamationmark.bubble", detail: error)
                } else {
                    ProgressView("Reading the conversation…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(WindowOcclusionReader { onScreen = $0 })
        .task { await reload() }
        // Live chats refresh every few seconds while they're on screen.
        .task(id: onScreen) {
            while onScreen && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                if session.state == .working || session.state == .waiting { await reload() }
            }
        }
    }
    private func reload() async {
        let host = store.remoteHosts.first { $0.id == session.remote?.hostID }
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
