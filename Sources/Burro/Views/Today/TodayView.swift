// The Today page: one day at a glance, top to bottom and full width. The date header; one row of
// stat tiles (tracked focus, tracked time, Break, longest focus, messages, to-dos, questions;
// with tracking off the first-to-last-message span leads instead); the hours strip; the day Burro
// tracked on this Mac (timeline with Your day so far beside it), or a small card that explains
// tracking and turns it on; what shipped on GitHub; chats grouped by status or project.
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
            TodayPage(today: today, activity: today.activity, rows: rows, todos: todos, waitingNow: today.isToday ? store.agentActivity.waitingCount : 0,
                      grouping: $grouping, open: { row in if let session = row.session { store.showChat(session) } }) {
                TodayShippedSection(store: store)
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
                // What shipped on GitHub: the day shown, and yesterday's recap on today.
                store.shipped.refresh(today.day)
                if today.isToday, let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today.day) {
                    store.shipped.refresh(yesterday)
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .task(id: onScreen) { if onScreen && today.isToday { store.todos.sync() } }
        .onChange(of: today.tracker.revision) { if onScreen { today.refreshTracked() } }
    }

    private var todos: TodaySummaryRow.Todos? {
        guard today.isToday else { return nil }
        let items = store.todos.items, start = TodayDayStart.millis
        return .init(done: items.filter(\.done).count, open: items.filter { !$0.done }.count, added: items.filter { $0.createdAt >= start }.count)
    }
}

/// The page's sections in order. Takes its inputs explicitly so snapshots can render it with a synthetic day.
struct TodayPage<Shipped: View>: View {
    var today: TodayStore
    var activity: DailyActivity?
    var rows: [TodayRow]
    var todos: TodaySummaryRow.Todos?
    var waitingNow: Int
    @Binding var grouping: String
    /// Fixed only for snapshots; otherwise the time of this render.
    var now: Date? = nil
    var open: (TodayRow) -> Void
    @ViewBuilder var shipped: () -> Shipped

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                TodayHeader(today: today)
                TodaySummaryRow(activity: activity, tracked: today.tracked, tracking: today.tracker.enabled, isToday: today.isToday,
                                todos: todos, waitingNow: waitingNow)
                TodayHoursCard(activity: activity, tracked: today.tracker.enabled ? today.tracked : nil, isToday: today.isToday, now: now)
            }
            if today.tracker.enabled { TodayDaySection(today: today, now: now) } else { TodayActivityCard(today: today) }
            shipped()
            TodayChatsSection(today: today, rows: rows, grouping: $grouping, open: open)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TodayChatsSection: View {
    var today: TodayStore
    var rows: [TodayRow]
    @Binding var grouping: String
    var open: (TodayRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("CHATS").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
                Text("\(rows.count)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(AppAppearance.raised, in: Capsule()).foregroundStyle(AppAppearance.secondary)
                if !rows.isEmpty {
                    let places = Set(rows.map(\.project)).count
                    Text("in \(places) place\(places == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
                        .help("Projects these chats touched")
                }
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
                    TodayChatGroup(title: group.title, color: group.color, rows: group.rows, open: open)
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
