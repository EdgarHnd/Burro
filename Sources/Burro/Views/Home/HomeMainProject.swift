// The featured project on Home (FocusTown by default): what's live in it on every machine, its
// recent chats, and one click to start a chat there.
import SwiftUI
import BurroCore

struct HomeMainProject: View {
    @Bindable var store: AppStore
    var summary: HomeSummary

    var body: some View {
        if let main = store.mainProject {
            let project = summary.projects.first { $0.id == main.path }
            let sessions = store.sessions(inProject: main.path, name: main.name)
            let live = sessions.filter { $0.state == .working || $0.state == .waiting || $0.isDone }
                .sorted { NotchGroup.priority($0) != NotchGroup.priority($1) ? NotchGroup.priority($0) < NotchGroup.priority($1) : $0.updatedAt > $1.updatedAt }
            let liveIDs = Set(live.map(\.id))
            let recent = sessions.filter { !liveIDs.contains($0.id) && Calendar.current.isDateInToday($0.updatedAt) }
                .sorted { $0.updatedAt > $1.updatedAt }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 16) {
                    GradientTile(initial: String(main.name.prefix(1)).uppercased(), symbol: nil, tint: HomeStyle.tint(for: main.name), size: 64)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MAIN PROJECT").font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
                        Text(main.name).font(.system(size: 22, weight: .bold, design: .rounded)).lineLimit(1).truncationMode(.middle)
                        // Stats drop from the end when the card is narrow instead of wrapping.
                        ViewThatFits(in: .horizontal) {
                            stats(live: live, project: project, count: 5)
                            stats(live: live, project: project, count: 4)
                            stats(live: live, project: project, count: 3)
                            stats(live: live, project: project, count: 2)
                        }
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    PillButton(title: "New chat", symbol: "plus.bubble") { store.startChat(in: main.path) }
                    PillButton(title: "Worktrees", symbol: "arrow.triangle.branch") {
                        store.search = ""; store.filter = .repository(main.path); store.page = .worktrees
                    }
                    Menu {
                        ForEach(store.repositoriesFound, id: \.path) { repo in
                            Button(repo.name) { store.mainProjectPath = repo.path }
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34)
                            .background(AppAppearance.raised, in: Circle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Change the main project")
                }
                .padding(22)
                Rectangle().fill(AppAppearance.separator).frame(height: 1)
                HStack(alignment: .top, spacing: 0) {
                    column("LIVE", empty: "Nothing running in \(main.name) right now.", sessions: Array(live.prefix(5)))
                    Rectangle().fill(AppAppearance.separator).frame(width: 1)
                    column("EARLIER TODAY", empty: "No other chats today.", sessions: Array(recent.prefix(5)))
                }
            }
            .modifier(SoftSurface(radius: 22, shadowRadius: 14, y: 4))
        }
    }

    private func stats(live: [AgentSession], project: HomeProject?, count: Int) -> some View {
        var items: [(String, String, Color)] = [
            ("waveform.path", "\(live.filter { $0.state == .working }.count) running", AppAppearance.green),
            ("hand.raised", "\(live.filter { $0.state == .waiting }.count) need you", AppAppearance.amber),
            ("arrow.triangle.branch", "\(project?.worktrees ?? 0) worktrees", AppAppearance.secondary),
        ]
        if let tokens = project?.tokensToday, tokens > 0 { items.append(("chart.bar", HomeFormat.tokens(tokens) + " today", AppAppearance.secondary)) }
        if let ready = project?.readyToRemove, ready > 0 { items.append(("trash", "\(ready) to clean", AppAppearance.secondary)) }
        return HStack(spacing: 14) {
            ForEach(Array(items.prefix(count).enumerated()), id: \.offset) { _, item in stat(item.0, item.1, item.2) }
        }
    }

    private func stat(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            Text(text).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(AppAppearance.secondary)
        }
        .fixedSize()
    }

    private func column(_ title: String, empty: String, sessions: [AgentSession]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
                .padding(.horizontal, 8).padding(.bottom, 4)
            if sessions.isEmpty {
                Text(empty).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).padding(.horizontal, 8).padding(.vertical, 6)
            }
            ForEach(sessions) { session in
                ProjectChatRow(session: session) { store.showChat(session) }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct ProjectChatRow: View {
    var session: AgentSession
    var open: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                AgentAvatar(session: session, active: hovering, working: session.state == .working, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(1).foregroundStyle(AppAppearance.text)
                    Text(session.remote?.hostName ?? "This Mac").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
                }
                Spacer(minLength: 4)
                Text(HomeFormat.ago(session.updatedAt)).font(.system(size: 11)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                Circle().fill(color).frame(width: 6, height: 6)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(hovering ? AppAppearance.hover : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }.help("Read this chat")
    }
    private var color: Color {
        session.state == .waiting ? AppAppearance.amber : (session.state == .working ? AppAppearance.green : (session.isDone ? AppAppearance.blue : AppAppearance.tertiary.opacity(0.5)))
    }
}
