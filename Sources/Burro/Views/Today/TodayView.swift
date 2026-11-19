// The Today page: one day at a glance, in the dashboard layout (one flat surface of panels joined
// by hairlines). Top to bottom: the header (the weekday and date, ← the day pill → on the right, and
// one sentence of facts: the time now, first and last message, the agents' merged time and how much
// of it ran while you were away, to-dos); the KPI strip (Focused or With agents, Agents worked,
// Waiting on you or Questions asked, Shipped); the main row: the lanes panel (AgentLanes: what each
// chat did on one axis, with the You and Shipped lanes; or the List timeline, by the remembered
// Lanes | List switch, `today.dayView`) beside the attention queue (Waiting on you, Home's own Needs
// you cards with the same Send / Edit / Discard, and While you were away); then three panels (Most
// time on, or the tracking-off card; Shipped with Details that opens the full Shipped section below;
// Chats by project); then today's chats in compact columns by status or project (TodayChatsSection).
// The main row stacks below about 950 points of content (the queue goes under the lanes), the bottom
// row below about 760, the KPI strip folds 2×2 below 640. Every number comes from what the page
// already holds; lanes and totals are computed once per render. One per-minute tick (today only)
// keeps "now" current. A chat's latest reply is cleaned the way the Chats list cleans it.
import SwiftUI
import BurroCore

struct TodayView: View {
    @Bindable var store: AppStore
    @State private var onScreen = false
    @State private var editing: String?
    @AppStorage("today.grouping") private var grouping = TodayGrouping.status.rawValue
    @AppStorage("today.dayView") private var mode = TodayDayMode.ribbon.rawValue
    @AppStorage("today.shippedDetails") private var shippedDetails = false
    private var today: TodayStore { store.today }

    var body: some View {
        let rows = TodayRows.build(store: store)
        // Home's own board: the queue, the KPI and the lanes' amber dots all count the same chats.
        let board = today.isToday ? HomeBoard.build(sessions: store.agentActivity.sessions, briefNeeds: store.brief.needsYou, all: store.notchChatSessions)
            : HomeBoard()
        let unlisted = store.unlistedChatIDs(board.needsYou.prefix(TodayQueue.cardCap).filter { $0.session == nil }.compactMap { $0.item?.chatID })
        ScrollView {
            if today.isToday {
                TimelineView(.everyMinute) { context in page(rows, board: board, now: context.date) }
            } else {
                page(rows, board: board, now: nil)
            }
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
        // Claude app links for queue items whose chat has left Burro's list (closed chats).
        .task(id: unlisted) { if onScreen { await ClosedChatLinks.shared.refresh(unlisted) } }
        .onChange(of: today.tracker.revision) { if onScreen { today.refreshTracked() } }
    }

    private func page(_ rows: [TodayRow], board: HomeBoard, now: Date?) -> some View {
        TodayPage(today: today, activity: today.activity, away: today.away, rows: rows, todos: todos,
                  waitingNow: board.needsYou.count, shippedState: shippedState, outcomes: outcomes,
                  grouping: $grouping, mode: $mode, shippedDetails: $shippedDetails, now: now,
                  open: { row in if let session = row.session { store.showChat(session) } },
                  openChats: { store.page = .remote },
                  queue: queue(board, now: now ?? Date()), brief: store.brief.file.items, yesterdayMerged: yesterdayMerged,
                  openLane: { id in if let session = rows.first(where: { $0.id == id })?.session { store.showChat(session) } }) {
            TodayShippedSection(store: store)
        }
        .padding(.horizontal, 36).padding(.vertical, 28)
        .frame(maxWidth: 1240).frame(maxWidth: .infinity)
    }

    private func queue(_ board: HomeBoard, now: Date) -> TodayQueue {
        let builder = HomeNeedsBuilder(store: store)
        var since: [String: Date] = [:]
        for entry in board.needsYou { if let session = entry.session { since[session.id] = entry.since } }
        return TodayQueue(cards: board.needsYou.prefix(TodayQueue.cardCap).map { builder.card($0, now: now) }, total: board.needsYou.count,
                          needsSince: since, oldest: board.needsYou.map(\.since).min(),
                          avatars: board.needsYou.compactMap { entry in entry.session.map { ($0.id, $0.provider) } },
                          actions: builder.actions(board) { id in editing = editing == id ? nil : id }, editingID: editing,
                          editor: { id in builder.editor(board.needsYou.first { $0.id == id }) }, checking: !store.didCheckAgents)
    }

    private var todos: TodayTodos? {
        guard today.isToday else { return nil }
        let items = store.todos.items, start = TodayDayStart.millis
        return .init(done: items.filter(\.done).count, open: items.filter { !$0.done }.count, added: items.filter { $0.createdAt >= start }.count)
    }

    private var yesterdayMerged: Int? {
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today.day) else { return nil }
        return store.shipped.shipped(yesterday)?.merged.count
    }

    private var shippedState: TodayShippedList.State {
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

/// The queue's Waiting on you tab, as plain values: Home's Needs-you cards (HomeNeedsBuilder) and
/// their actions, built by TodayView from the store.
struct TodayQueue {
    static let cardCap = 5
    var cards: [HomeNeedsCardData] = []
    var total = 0
    /// When each chat waiting now started waiting, by chat id (the lanes' amber dots).
    var needsSince: [String: Date] = [:]
    var oldest: Date? = nil
    /// The waiting chats' ids and providers, for the KPI's avatars.
    var avatars: [(id: String, provider: AgentProvider)] = []
    var actions = HomeBoardActions()
    var editingID: String? = nil
    var editor: (String) -> AnyView = { _ in AnyView(EmptyView()) }
    var checking = false
}

/// The page's sections in order. Takes its inputs explicitly so snapshots can render it with a synthetic day.
struct TodayTodos { var done: Int; var open: Int; var added: Int }

struct TodayPage<Shipped: View>: View {
    /// A day other than the store's, for snapshots (showing a past day would start a real scan).
    struct Shown { var day: Date; var tracked: ActivityDay? }

    var today: TodayStore
    var activity: DailyActivity?
    var away: AgentAwayTime.Summary?
    var rows: [TodayRow]
    var todos: TodayTodos?
    /// Home's Needs you count (today only).
    var waitingNow: Int
    var shippedState: TodayShippedList.State
    /// Outcome lines by chat id (the Brief's headlines).
    var outcomes: [String: String] = [:]
    @Binding var grouping: String
    @Binding var mode: String
    @Binding var shippedDetails: Bool
    /// Fixed only for snapshots; otherwise the time of this render.
    var now: Date? = nil
    var open: (TodayRow) -> Void
    var openChats: () -> Void = {}
    var queue = TodayQueue()
    /// The Brief's items (open and resolved), for the lanes' marks.
    var brief: [BriefItem] = []
    /// Pull requests merged the day before, for the Shipped cell.
    var yesterdayMerged: Int? = nil
    var shown: Shown? = nil
    var openLane: (String) -> Void = { _ in }
    @ViewBuilder var shipped: () -> Shipped

    @State private var queueTab = "waiting"

    private var tracker: ActivityTracker { today.tracker }
    private var ribbon: Bool { mode != TodayDayMode.list.rawValue }
    private var day: Date { shown?.day ?? today.day }
    private var isToday: Bool { shown.map { Calendar.current.isDateInToday($0.day) } ?? today.isToday }
    private var tracked: ActivityDay? { shown.map(\.tracked) ?? today.tracked }

    /// Below these content widths the main row and the bottom row stack.
    static var mainStackBelow: CGFloat { 880 }
    static var bottomStackBelow: CGFloat { 690 }

    var body: some View {
        let now = self.now ?? Date()
        let calendar = Calendar.current
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let agentTime = TodayAgentTime.make(activity)
        let lanes = self.lanes(now: now, calendar: calendar)
        let lanesWindow = self.lanesWindow(lanes, now: now, calendar: calendar)
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()), inset: 0,
                       eyebrow: isToday ? "Today" : "Earlier", sentence: headerSentence(agentTime: agentTime, now: now, calendar: calendar),
                       top: 0, bottom: 0) {
                TodayDayStepper(today: today)
            }
            if tracker.enabled && !tracker.accessibilityTrusted { ActivityAccessPrompt(tracker: tracker) }
            StatStrip(cells: stats(agentTime: agentTime, calendar: calendar))
            JoinedPanels {
                JoinedRow(weights: [2, 1], stackBelow: Self.mainStackBelow) {
                    lanesPanel(lanes, window: lanesWindow, now: now)
                    queuePanel(byID)
                }
                JoinedRow(weights: [1, 1, 1], stackBelow: Self.bottomStackBelow) {
                    timePanel
                    Panel(title: "Shipped", subtitle: [TextRun(TodayShippedList.source(shippedState))]) {
                        TodayShippedList(state: shippedState, isToday: isToday, details: $shippedDetails, limit: 4)
                    }
                    projectsPanel
                }
            }
            if shippedDetails, case .loaded = shippedState { shipped() }
            TodayChatsSection(today: today, rows: rows, grouping: $grouping, now: now, open: open, openChats: openChats)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dayInterval: DateInterval {
        let start = Calendar.current.startOfDay(for: day)
        return DateInterval(start: start, end: Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
    }

    /// The tracked day for the You lane, or nil with tracking off.
    private var laneTracked: ActivityDay? { tracker.enabled ? tracked : nil }

    // MARK: Header and KPIs

    private func headerSentence(agentTime: TodayAgentTime?, now: Date, calendar: Calendar) -> [TextRun] {
        let facts = TodayHeadline.sentence(activity: activity, agentTime: agentTime, away: tracker.enabled ? away : nil, isToday: isToday,
                                           todos: todos.map { ($0.done, $0.done + $0.open) }, calendar: calendar)
        return isToday ? [TextRun("Now \(TodayClock.hm(now, calendar: calendar)). ", .strong)] + facts : facts
    }

    private func stats(agentTime: TodayAgentTime?, calendar: Calendar) -> [StatCellData] {
        let shipped: TodayStats.Shipped
        switch shippedState {
        case .loading: shipped = .loading
        case .noProject: shipped = .noProject
        case .failed: shipped = .failed
        case .loaded(let day): shipped = .loaded(merged: day.merged.count, deploys: day.production.count, dayBefore: yesterdayMerged)
        }
        let waiting = isToday ? waitingNow : 0
        return TodayStats.cells(activity: activity, tracked: tracked, tracking: tracker.enabled, isToday: isToday, agentTime: agentTime,
                                waiting: waiting, oldestWaiting: queue.oldest, shipped: shipped, calendar: calendar).map { stat in
            var accessory: AnyView?
            if stat.key == .waiting, isToday, !queue.avatars.isEmpty {
                accessory = AnyView(HStack(spacing: -4) {
                    ForEach(queue.avatars.prefix(4), id: \.id) { ProviderAvatar(provider: $0.provider, id: $0.id, active: false, working: false, size: 15) }
                })
            }
            return StatCellData(id: stat.id, label: stat.label, dot: stat.dot && waiting > 0 ? AppAppearance.amber : nil, value: stat.value,
                                valuePrefix: stat.valuePrefix, muted: stat.unknown, sub: stat.sub, help: stat.help, accessory: accessory)
        }
    }

    // MARK: Main row

    private func lanes(now: Date, calendar: Calendar) -> [AgentLane] {
        let inputs = rows.map { row in
            TodayLaneInput(id: row.id, title: row.title, provider: row.provider, state: TodayLaneInput.State(rawValue: row.status.rawValue) ?? .idle,
                           place: row.breadcrumb, lastAt: row.lastAt, turnStart: row.activeSince, remote: row.session?.remote != nil,
                           canOpen: row.session != nil)
        }
        return TodayLanes.build(inputs, activity: activity, needsSince: queue.needsSince, brief: brief, window: dayInterval,
                                isToday: isToday, now: now, calendar: calendar)
    }

    /// Everything the lanes draw (chat stretches and marks, tracked blocks, shipped ticks) decides the axis.
    private func lanesWindow(_ lanes: [AgentLane], now: Date, calendar: Calendar) -> DayRibbonLayout.LaneWindow {
        var pieces = lanes.flatMap { $0.intervals ?? [] }
        pieces += lanes.flatMap { $0.marks.map { DateInterval(start: $0.at, duration: 0) } }
        pieces += (laneTracked?.blocks ?? []).map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
        pieces += (shippedMarks ?? []).map { DateInterval(start: $0.at, duration: 0) }
        return DayRibbonLayout.laneWindow(day: dayInterval, pieces: pieces, now: isToday ? now : nil, calendar: calendar)
    }

    private func lanesPanel(_ lanes: [AgentLane], window: DayRibbonLayout.LaneWindow, now: Date) -> some View {
        Panel(title: isToday ? "What each chat did today" : "What each chat did", subtitle: TodayLanes.summary(lanes, isToday: isToday)) {
            HStack(spacing: 10) {
                if tracker.enabled { ActivityControls(today: today).fixedSize() }
                CapsulePicker(options: [(TodayDayMode.ribbon.rawValue, "Lanes"), (TodayDayMode.list.rawValue, "List")], selection: $mode)
                    .fixedSize()
                    .help("Lanes: every chat on one time axis. List: the tracked timeline with each block's title.")
            }
        } content: {
            if ribbon {
                AgentLanes(lanes: lanes, window: window.window, day: dayInterval, now: isToday ? now : nil, away: awayPeriods(now: now),
                           tracked: laneTracked, trackingOn: tracker.enabled, shipped: shippedMarks, scanned: activity != nil,
                           cut: window.cut, showList: { mode = TodayDayMode.list.rawValue }, open: openLane)
            } else if tracker.enabled {
                TodayDaySection(today: today, now: now, showsHeader: false)
            } else {
                Text("The List view shows the timeline Burro tracked, and activity tracking is off. Lanes shows each chat's day without it.")
                    .font(.system(size: 13)).foregroundStyle(AppAppearance.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The day's away periods: the summary's when there is one, else worked out from the tracked day
    /// the same way (time Burro wasn't recording is never away). Empty with tracking off.
    private func awayPeriods(now: Date) -> [DateInterval] {
        guard let tracked = laneTracked else { return [] }
        return away?.away ?? AgentAwayTime.away(tracked: tracked, within: DateInterval(start: dayInterval.start,
                                                                                     end: min(dayInterval.end, max(dayInterval.start, isToday ? now : dayInterval.end))))
    }

    private func queuePanel(_ byID: [String: TodayRow]) -> some View {
        let awayCount: Int? = tracker.enabled ? away.map { $0.total >= 60 ? $0.chats.count : 0 } : nil
        var tabs: [AttentionQueueTab] = []
        if isToday { tabs.append(.init(id: "waiting", title: "Waiting on you", short: "Waiting", count: waitingNow, needsYou: true)) }
        tabs.append(.init(id: "away", title: "While you were away", short: "While away", count: awayCount))
        return PanelCell {
            AttentionQueue(tabs: tabs, selection: $queueTab) { tab in
                if tab == "waiting" {
                    NeedsQueueList(cards: queue.cards, total: queue.total, actions: queue.actions, editingID: queue.editingID,
                                   editor: queue.editor, checking: queue.checking)
                } else {
                    TodayAwayList(summary: tracker.enabled ? away : nil, rows: awayRows(byID), reason: awayReason)
                }
            }
        }
    }

    // MARK: Bottom row

    @ViewBuilder private var timePanel: some View {
        if tracker.enabled {
            Panel(title: "Most time on", subtitle: TodayFacts.tracked(tracked)) {
                if let day = tracked, day.total > 0 {
                    TodayMostTimeList(day: day, tracker: tracker)
                } else {
                    Text(tracked == nil ? "Reading…" : isToday ? "Nothing tracked yet today." : "Nothing tracked that day.")
                        .font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary)
                }
            }
        } else {
            Panel(title: "Activity tracking", subtitle: [TextRun("Off")]) { TodayActivityCard(today: today, framed: false) }
        }
    }

    private var projectsPanel: some View {
        let chats = Dictionary((activity?.chats ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projects = TodayProjects.rows(rows.map { (project: $0.project, active: chats[$0.id]?.active) })
        return Panel(title: "Chats by project",
                     subtitle: [TextRun(rows.isEmpty ? (isToday ? "No chats yet today" : "No chats that day")
                                        : "\(rows.count) chat\(rows.count == 1 ? "" : "s") in \(projects.count) place\(projects.count == 1 ? "" : "s")")]) {
            TodayProjectsList(rows: projects)
        }
    }

    private var shippedMarks: [TodayRibbonShip]? {
        if case .loaded(let day) = shippedState { return TodayShippedList.marks(day) }
        return nil
    }

    // MARK: Away

    private func awayRows(_ byID: [String: TodayRow]) -> [TodayAwayList.Row] {
        let chats = Dictionary((activity?.chats ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (away?.chats ?? []).map { chat in
            let row = byID[chat.id]
            return TodayAwayList.Row(id: chat.id, title: row?.title ?? chats[chat.id]?.title ?? "Chat",
                                     outcome: outcomes[chat.id] ?? row?.preview, seconds: chat.seconds, status: row?.status ?? .idle,
                                     open: row?.session == nil ? nil : { [open] in if let row { open(row) } })
        }
    }

    /// The scan answered, but no chat carries stretches: an older helper. Say so rather than claim idle.
    private var agentsUnknown: Bool {
        guard let activity, !activity.chats.isEmpty else { return false }
        return activity.chats.allSatisfy { $0.active == nil }
    }

    private var awayReason: String {
        if !tracker.enabled { return "Activity tracking is off, so Burro can't tell when you were away." }
        if activity == nil || tracked == nil { return "Reading…" }
        if agentsUnknown { return "Burro's helper needs updating to tell when agents worked." }
        return isToday ? "Nothing recorded yet today, so Burro can't tell when you were away." : "Nothing was recorded that day."
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
