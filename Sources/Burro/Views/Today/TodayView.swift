// The Today page: one day at a glance. Chats grouped by status or project, how long you've been
// at it, messages, to-dos, questions agents asked, and Dayflow's timeline when it's installed.
import SwiftUI
import BurroCore

struct TodayView: View {
    @Bindable var store: AppStore
    @State private var onScreen = false
    @AppStorage("today.grouping") private var grouping = TodayGrouping.status.rawValue
    private var today: TodayStore { store.today }

    var body: some View {
        let rows = TodayRows.build(store: store)
        ScrollView {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 26) {
                    TodayHeader(today: today)
                    chats(rows)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 14) {
                    TodayWorkedCard(today: today)
                    TodayMessagesCard(activity: today.activity)
                    if today.isToday { TodayTodosCard(todos: store.todos) }
                    TodayQuestionsCard(asked: today.activity?.questions ?? 0,
                                       waitingNow: today.isToday ? store.agentActivity.waitingCount : 0)
                    TodayChatsCard(rows: rows)
                    if today.dayflowInstalled { TodayDayflowCard(dayflow: today.dayflow) }
                }.frame(width: 320)
            }
            .padding(.horizontal, 36).padding(.vertical, 28)
            .frame(maxWidth: 1240).frame(maxWidth: .infinity)
        }
        .background(AppAppearance.background)
        .background(WindowOcclusionReader { onScreen = $0 })
        .task(id: onScreen) {
            today.profiles = { [weak store] in store?.usage.preferences.profiles ?? [:] }
            while onScreen && !Task.isCancelled {
                today.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .task(id: onScreen) { if onScreen && today.isToday { store.todos.sync() } }
    }

    @ViewBuilder private func chats(_ rows: [TodayRow]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("CHATS").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
                Text("\(rows.count)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(AppAppearance.raised, in: Capsule()).foregroundStyle(AppAppearance.secondary)
                Spacer()
                CapsulePicker(options: TodayGrouping.allCases.map { ($0.rawValue, $0.title) }, selection: $grouping)
                TogglePill(title: "Previews", symbol: "eye", isOn: Binding(get: { today.previews }, set: { today.previews = $0 }))
                    .help("Show the first line of each chat's latest reply. Read on demand, kept in memory only.")
            }.padding(.horizontal, 2)
            if rows.isEmpty {
                HomeEmptyCard(symbol: "bubble.left.and.bubble.right", title: today.isToday ? "No chats yet today" : "No chats that day",
                              detail: today.scanning ? "Reading your agent logs…" : "Chats you start or continue show up here.") { EmptyView() }
            } else {
                ForEach(TodayRows.groups(rows, by: TodayGrouping(rawValue: grouping) ?? .status), id: \.title) { group in
                    TodayChatGroup(title: group.title, color: group.color, rows: group.rows) { row in
                        if let session = row.session { store.showChat(session) }
                    }
                }
            }
        }
    }
}

enum TodayGrouping: String, CaseIterable, Identifiable {
    case status, project
    var id: String { rawValue }
    var title: String { self == .status ? "Status" : "Project" }
}

struct TodayRow: Identifiable {
    enum Status: Int, CaseIterable { case needsYou, working, toRead, idle
        var title: String { switch self { case .needsYou: "Needs you"; case .working: "Working"; case .toRead: "Ready to read"; case .idle: "Earlier" } }
        var color: Color { switch self { case .needsYou: AppAppearance.amber; case .working: AppAppearance.green; case .toRead: AppAppearance.blue; case .idle: AppAppearance.tertiary } }
    }
    var id: String
    var title: String
    var provider: AgentProvider
    var status: Status
    var project: String
    var breadcrumb: String
    var lastAt: Date
    var preview: String?
    var turns: Int
    var session: AgentSession?
}

enum TodayRows {
    @MainActor static func build(store: AppStore) -> [TodayRow] {
        let today = store.today
        let calendar = Calendar.current
        let start = today.day, end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let live = store.notchChatSessions.filter { $0.isSubagent != true }
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let activity = Dictionary((today.activity?.chats ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ids = Set(activity.keys)
        if today.isToday { ids.formUnion(live.filter { $0.updatedAt >= start && $0.updatedAt < end }.map(\.id)) }
        let worktrees = store.snapshot.worktrees
        return ids.compactMap { id -> TodayRow? in
            let session = byID[id], chat = activity[id]
            guard session != nil || chat != nil else { return nil }
            let folder = session.map { store.workspacePath(for: $0) } ?? chat?.folder ?? ""
            let tree = worktrees.first { $0.path == Paths.owner(of: folder, in: worktrees.map(\.path)) }
            let project = tree?.repository ?? (folder.isEmpty ? "Unknown folder" : URL(fileURLWithPath: folder).lastPathComponent)
            var crumbs: [String] = []
            if let host = session?.remote?.hostName { crumbs.append(host) }
            crumbs.append(project)
            if let tree, !tree.isPrimary { crumbs.append(URL(fileURLWithPath: tree.path).lastPathComponent) }
            let status: TodayRow.Status
            if let session, today.isToday {
                if session.state == .waiting && session.remote?.stale != true { status = .needsYou }
                else if session.state == .working || session.state == .scheduled { status = .working }
                else if session.isDone { status = .toRead }
                else { status = .idle }
            } else { status = .idle }
            let title = session?.title ?? chat?.title ?? "Chat in \(project)"
            return TodayRow(id: id, title: title, provider: session?.provider ?? chat?.provider ?? .codex, status: status,
                            project: project, breadcrumb: crumbs.joined(separator: " / "),
                            lastAt: max(chat?.lastAt ?? .distantPast, session.map { min($0.updatedAt, end) } ?? .distantPast),
                            preview: today.previews ? chat?.preview : nil, turns: chat?.turns ?? 0, session: session)
        }.sorted { $0.lastAt > $1.lastAt }
    }

    static func groups(_ rows: [TodayRow], by grouping: TodayGrouping) -> [(title: String, color: Color, rows: [TodayRow])] {
        switch grouping {
        case .status:
            return TodayRow.Status.allCases.compactMap { status in
                let matching = rows.filter { $0.status == status }
                return matching.isEmpty ? nil : (status.title, status.color, matching)
            }
        case .project:
            return Dictionary(grouping: rows, by: \.project)
                .map { (title: $0.key, color: HomeStyle.tint(for: $0.key), rows: $0.value) }
                .sorted { ($0.rows.first?.lastAt ?? .distantPast) > ($1.rows.first?.lastAt ?? .distantPast) }
        }
    }
}
