// The Today page: one day at a glance, top to bottom and full width. The date header (← and →
// step a day); the summary (tracked focus as the headline, then one line of facts that starts with
// "Agents worked … while you were away" when there is such time; with tracking off the
// first-to-last-message span leads instead); the Activity row (recording state and its menu, and a
// remembered Ribbon | List switch); then either the day ribbon (TodayRibbon.swift: You, Agents and
// Shipped lanes across 0–24 h) or the vertical timeline with Your day beside it (TodayDayView.swift),
// with the small card that explains tracking and turns it on while it's off; the cards (While you
// were away, Most time on the ribbon, Shipped with Details that opens the full Shipped section);
// and today's chats in compact columns by status or project (TodayCards.swift). A chat's latest
// reply is cleaned the way the Chats list cleans it (`ChatListPresentation.preview`: plain text,
// Codex directive lines left out).
import SwiftUI
import BurroCore

struct TodayView: View {
    @Bindable var store: AppStore
    @State private var onScreen = false
    @AppStorage("today.grouping") private var grouping = TodayGrouping.status.rawValue
    @AppStorage("today.dayView") private var mode = TodayDayMode.ribbon.rawValue
    @AppStorage("today.shippedDetails") private var shippedDetails = false
    private var today: TodayStore { store.today }

    var body: some View {
        let rows = TodayRows.build(store: store)
        ScrollView {
            TodayPage(today: today, activity: today.activity, away: today.away, rows: rows, todos: todos,
                      waitingNow: today.isToday ? store.agentActivity.waitingCount : 0, shippedState: shippedState, outcomes: outcomes,
                      grouping: $grouping, mode: $mode, shippedDetails: $shippedDetails,
                      open: { row in if let session = row.session { store.showChat(session) } },
                      openChats: { store.page = .remote }) {
                TodayShippedSection(store: store)
            }
            .padding(.horizontal, 36).padding(.vertical, 28)
            .frame(maxWidth: 1240).frame(maxWidth: .infinity)
        }
        .background(AppAppearance.background)
        // The activity controls' "Open Burro at login" item.
        .environment(store.loginItem)
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

    private var shippedState: TodayShippedCard.State {
        let day = today.day, shipped = store.shipped
        switch shipped.state(day) {
        case .loaded(let value): return .loaded(value)
        case .failed(let failure): return .failed(title: failure.title, detail: failure.detail, retry: { shipped.refresh(day, force: true) })
        case nil where store.mainProject == nil && store.didScan: return .noProject
        case .loading, nil: return .loading
        }
    }

    /// The Brief's one-line headline per chat, the best outcome line Burro has.
    private var outcomes: [String: String] {
        let brief = store.brief
        return Dictionary((brief.stuck + brief.finished + brief.needsYou).compactMap { item in item.chatID.map { ($0, item.headline) } }, uniquingKeysWith: { _, last in last })
    }
}

enum TodayDayMode: String { case ribbon, list }

/// The page's sections in order. Takes its inputs explicitly so snapshots can render it with a synthetic day.
struct TodayPage<Shipped: View>: View {
    var today: TodayStore
    var activity: DailyActivity?
    var away: AgentAwayTime.Summary?
    var rows: [TodayRow]
    var todos: TodaySummaryRow.Todos?
    var waitingNow: Int
    var shippedState: TodayShippedCard.State
    /// Outcome lines by chat id (the Brief's headlines).
    var outcomes: [String: String] = [:]
    @Binding var grouping: String
    @Binding var mode: String
    @Binding var shippedDetails: Bool
    /// Fixed only for snapshots; otherwise the time of this render.
    var now: Date? = nil
    var open: (TodayRow) -> Void
    var openChats: () -> Void = {}
    @ViewBuilder var shipped: () -> Shipped

    private var tracker: ActivityTracker { today.tracker }
    private var ribbon: Bool { mode != TodayDayMode.list.rawValue }

    var body: some View {
        let now = self.now ?? Date()
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                TodayHeader(today: today)
                TodaySummaryRow(activity: activity, tracked: today.tracked, tracking: tracker.enabled, isToday: today.isToday,
                                todos: todos, waitingNow: waitingNow, away: away)
            }
            VStack(alignment: .leading, spacing: 12) {
                activityHeader
                if tracker.enabled && !tracker.accessibilityTrusted { ActivityAccessPrompt(tracker: tracker).padding(.horizontal, 2) }
                if !tracker.enabled { TodayActivityCard(today: today) }
                if ribbon {
                    TodayRibbonCard(day: dayInterval, now: today.isToday ? now : nil, tracked: tracker.enabled ? today.tracked : nil,
                                    trackingOn: tracker.enabled, agents: agents(byID), agentsUnknown: agentsUnknown, away: away,
                                    shipped: shippedMarks)
                } else if tracker.enabled {
                    TodayDaySection(today: today, now: now, showsHeader: false)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                // With tracking off the card above already says what turning it on adds.
                if tracker.enabled { TodayAwayCard(summary: away, rows: awayRows(byID), reason: awayReason) }
                if ribbon, tracker.enabled, let day = today.tracked, day.total > 0 {
                    TodayMostTimeCard(day: day, tracker: tracker)
                }
                TodayShippedCard(state: shippedState, isToday: today.isToday, details: $shippedDetails)
            }
            if shippedDetails, case .loaded = shippedState { shipped() }
            TodayChatsSection(today: today, rows: rows, grouping: $grouping, now: now, open: open, openChats: openChats)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activityHeader: some View {
        HStack(spacing: 12) {
            Text("ACTIVITY").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
            if tracker.enabled { ActivityControls(today: today) } else { Spacer() }
            CapsulePicker(options: [(TodayDayMode.ribbon.rawValue, "Ribbon"), (TodayDayMode.list.rawValue, "List")], selection: $mode)
                .help("Ribbon: the whole day in lanes. List: the timeline with each block's title.")
        }
        .padding(.horizontal, 2)
    }

    private var dayInterval: DateInterval {
        let start = Calendar.current.startOfDay(for: today.day)
        return DateInterval(start: start, end: Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
    }

    // MARK: Agents and away

    private func agents(_ byID: [String: TodayRow]) -> [TodayRibbonAgent]? {
        guard let activity else { return nil }
        return activity.chats.compactMap { chat -> TodayRibbonAgent? in
            guard let active = chat.active, !active.isEmpty else { return nil }
            let row = byID[chat.id]
            return TodayRibbonAgent(id: chat.id, title: row?.title ?? chat.title ?? "Chat", intervals: active,
                                    open: row?.session == nil ? nil : { [open] in if let row { open(row) } })
        }
        .sorted { ($0.intervals.first?.start ?? .distantPast) < ($1.intervals.first?.start ?? .distantPast) }
    }

    /// The scan answered, but no chat carries stretches: an older helper. Say so rather than claim idle.
    private var agentsUnknown: Bool {
        guard let activity, !activity.chats.isEmpty else { return false }
        return activity.chats.allSatisfy { $0.active == nil }
    }

    private var shippedMarks: [TodayRibbonShip]? {
        if case .loaded(let day) = shippedState { return TodayShippedCard.marks(day) }
        return nil
    }

    private func awayRows(_ byID: [String: TodayRow]) -> [TodayAwayCard.Row] {
        let chats = Dictionary((activity?.chats ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (away?.chats ?? []).map { chat in
            let row = byID[chat.id]
            return TodayAwayCard.Row(id: chat.id, title: row?.title ?? chats[chat.id]?.title ?? "Chat",
                                     outcome: outcomes[chat.id] ?? row?.preview, seconds: chat.seconds, status: row?.status ?? .idle,
                                     open: row?.session == nil ? nil : { [open] in if let row { open(row) } })
        }
    }

    private var awayReason: String {
        if activity == nil || today.tracked == nil { return "Reading…" }
        if agentsUnknown { return "Burro's helper needs updating to tell when agents worked." }
        return today.isToday ? "Nothing recorded yet today, so Burro can't tell when you were away." : "Nothing was recorded that day."
    }
}

struct TodayChatsSection: View {
    var today: TodayStore
    var rows: [TodayRow]
    @Binding var grouping: String
    var now: Date
    var open: (TodayRow) -> Void
    var openChats: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("\(today.isToday ? "TODAY'S CHATS" : "CHATS") · \(rows.count)").font(.system(size: 11, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(AppAppearance.tertiary)
                if !rows.isEmpty {
                    let places = Set(rows.map(\.project)).count
                    Text("in \(places) place\(places == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
                        .help("Projects these chats touched")
                }
                Spacer()
                CapsulePicker(options: TodayGrouping.allCases.map { ($0.rawValue, $0.title) }, selection: $grouping)
                TogglePill(title: "Previews", symbol: "eye", isOn: Binding(get: { today.previews }, set: { today.previews = $0 }))
                    .help("Read the first line of each chat's latest reply: shown on hover and under While you were away. Kept in memory only.")
                Button("Open Chats", action: openChats).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(AppAppearance.blue)
            }.padding(.horizontal, 2)
            if rows.isEmpty {
                HomeEmptyCard(symbol: "bubble.left.and.bubble.right", title: today.isToday ? "No chats yet today" : "No chats that day",
                              detail: today.scanning ? "Reading your agent logs…" : "Chats you start or continue show up here.") { EmptyView() }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(TodayRows.groups(rows, by: TodayGrouping(rawValue: grouping) ?? .status), id: \.title) { group in
                        TodayChatColumn(title: group.title, color: group.color, rows: group.rows, now: now,
                                        needsYou: group.rows.first?.status == .needsYou && grouping == TodayGrouping.status.rawValue, open: open)
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
        var title: String { switch self { case .needsYou: "Needs you"; case .working: "Working"; case .toRead: "Ready to read"; case .idle: "Done" } }
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
    /// Start of the chat's current active stretch, when it is still going.
    var activeSince: Date? = nil
}

enum TodayRows {
    @MainActor static func build(store: AppStore) -> [TodayRow] {
        let today = store.today
        let calendar = Calendar.current, now = Date()
        let start = today.day, end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let live = store.notchChatSessions.filter { $0.isSubagent != true }
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let activity = Dictionary((today.activity?.chats ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ids = Set(activity.keys)
        if today.isToday { ids.formUnion(live.filter { $0.updatedAt >= start && $0.updatedAt < end }.map(\.id)) }
        // Worktree paths and lookup are built once per build, not once per row.
        let worktrees = store.snapshot.worktrees
        let roots = worktrees.map(\.path)
        let byPath = Dictionary(worktrees.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { id -> TodayRow? in
            let session = byID[id], chat = activity[id]
            guard session != nil || chat != nil else { return nil }
            // Same answer as `store.workspacePath(for:)`: a local chat's owning worktree, else its folder.
            let owned = session.flatMap { session -> String? in
                guard session.remote == nil else { return nil }
                return session.attachedPaths.lazy.compactMap { Paths.owner(of: $0, in: roots) }.first ?? Paths.owner(of: session.cwd, in: roots)
            }
            let folder = owned ?? session?.cwd ?? chat?.folder ?? ""
            let tree = owned.flatMap { byPath[$0] } ?? Paths.owner(of: folder, in: roots).flatMap { byPath[$0] }
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
            // A stretch that reached the last few minutes is still going: how long this turn has run.
            let current = chat?.active?.last.flatMap { now.timeIntervalSince($0.end) < 300 ? $0.start : nil }
            return TodayRow(id: id, title: title, provider: session?.provider ?? chat?.provider ?? .codex, status: status,
                            project: project, breadcrumb: crumbs.joined(separator: " / "),
                            lastAt: max(chat?.lastAt ?? .distantPast, session.map { min($0.updatedAt, end) } ?? .distantPast),
                            preview: today.previews ? ChatListPresentation.preview(chat?.preview) : nil, turns: chat?.turns ?? 0, session: session, activeSince: current)
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
