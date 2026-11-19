// Home in the dashboard layout, as plain values (HomeView maps the store onto it; snapshots draw it
// over a still aquarium). Top to bottom, over the fixed backdrop:
// - The greeting and one sentence (`HomeCover`, the needs-you count amber) and the four-number
//   `StatStrip`, straight on the water with no surface, so a band of live, hoverable aquarium stays
//   at the top and in the gutters.
// - One `JoinedPanels` surface at 0.9 opacity (no blur, no material): the main row 2:1, "What your
//   agents are doing" (`AgentLanes`, one lane per live chat, Today's lane rules, cap 6 then "Show
//   all N in Chats") beside the queue (`HomeQueuePanel`: Waiting on you / Working / Ready to read,
//   then Ask the Orchestrator); the bottom row 1:1:1, Machines, Limits, To-dos (`HomeBottomRow`:
//   without limits, To-dos and Notes).
// - A quieter section on the water: the caller's main project, benches and projects, then Notes
//   (unless the bottom row has it) and the Scratchpad.
// The main row stacks below 900 points of row width (the queue goes under the lanes: at a 1000-point
// window, 879, the queue would get about 250 points), the bottom row below 690, the strip folds 2×2
// below 640. Everything here is computed once per render by the caller.
import SwiftUI
import BurroCore

struct HomePageData {
    var now: Date
    var sentence: [TextRun]
    /// Before the first agent check.
    var checking = false
    var stats: [StatCellData] = []
    var lanes: [AgentLane] = []
    var laneWindow: DateInterval
    var day: DateInterval
    /// Today's agent scan has answered; until then lanes show without bars.
    var scanned = false
    var board = HomeBoardData()
    var machines: [HomeMachineRowData] = []
    /// Nil when there are no limits to show (usage off, or every provider hidden).
    var limits: [HomeLimitRow]? = nil
    /// Said in the Limits panel when it has no rows ("Loading limits…").
    var limitsNote = "Connect an account on the Usage page."
}

struct HomePageActions {
    var board = HomeBoardActions()
    var openLane: (String) -> Void = { _ in }
    var openToday: () -> Void = {}
    var openMachine: (HomeMachineRowData) -> Void = { _ in }
    var openMachines: () -> Void = {}
    var openUsage: () -> Void = {}
    var startChatFromTodo: ((TodoItem) -> Void)? = nil
    var startChatFromNote: ((HomeNote) -> Void)? = nil
    var openNotes: (NotesTarget) -> Void = { _ in }
}

struct HomePage<Ask: View, Below: View>: View {
    var data: HomePageData
    var actions: HomePageActions
    var todos: TodoStore
    var notes: NotesStore
    var editingID: String? = nil
    var editor: (String) -> AnyView = { _ in AnyView(EmptyView()) }
    @Binding var queueTab: String?
    @ViewBuilder var ask: () -> Ask
    @ViewBuilder var below: () -> Below

    nonisolated static var mainStackBelow: CGFloat { 900 }
    nonisolated static var bottomStackBelow: CGFloat { 690 }
    /// The panels' surface over the aquarium: fish read as faint shadows through it.
    nonisolated static var surfaceOpacity: Double { 0.9 }

    var body: some View {
        let slots = HomeBottomRow.slots(limitsShown: data.limits != nil)
        VStack(alignment: .leading, spacing: 22) {
            HomeCover(sentence: data.sentence, checking: data.checking, now: data.now)
            StatStrip(cells: data.stats, bare: true)
            JoinedPanels(opacity: Self.surfaceOpacity) {
                JoinedRow(weights: [2, 1], stackBelow: Self.mainStackBelow) {
                    lanesPanel
                    HomeQueuePanel(data: data.board, actions: actions.board, editingID: editingID, editor: editor, selection: $queueTab, ask: ask)
                }
                JoinedRow(weights: [1, 1, 1], stackBelow: Self.bottomStackBelow) {
                    ForEach(slots, id: \.self) { slot in bottomPanel(slot) }
                }
            }
            VStack(alignment: .leading, spacing: 30) {
                below()
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: 2), alignment: .leading, spacing: 16) {
                    if !slots.contains(.notes) {
                        HomeNotesCard(notes: notes, startChat: actions.startChatFromNote, open: actions.openNotes)
                    }
                    HomeScratchpadCard(notes: notes)
                }
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Lanes

    private var lanesPanel: some View {
        Panel(title: "What your agents are doing", subtitle: lanesSummary) {
            HomePanelLink(help: "Open Today", action: actions.openToday)
        } content: {
            if !data.lanes.isEmpty {
                AgentLanes(lanes: data.lanes, window: data.laneWindow, day: data.day, now: data.now, away: [], tracked: nil, trackingOn: false,
                           shipped: nil, scanned: data.scanned, cap: HomeLanes.cap, showAll: actions.board.showAll, open: actions.openLane)
            }
        }
    }

    private var lanesSummary: [TextRun] {
        if data.lanes.isEmpty {
            return [TextRun(data.checking ? "Checking on your agents…" : "No live chats: nothing needs you, nothing is working and nothing waits to be read.")]
        }
        return TodayLanes.summary(data.lanes, isToday: true)
    }

    // MARK: Bottom row

    @ViewBuilder private func bottomPanel(_ slot: HomeBottomRow.Slot) -> some View {
        switch slot {
        case .machines:
            Panel(title: "Machines", subtitle: [TextRun(HomeMachineRows.subtitle(data.machines))]) {
                HomePanelLink(help: "Open Machines", action: actions.openMachines)
            } content: {
                HomeMachineRows(rows: data.machines, open: actions.openMachine)
            }
        case .limits:
            Panel(title: "Limits", subtitle: [TextRun("What's left in each window")]) {
                HomePanelLink(help: "Open Usage", action: actions.openUsage)
            } content: {
                HomeLimitsList(rows: data.limits ?? [], note: data.limitsNote)
            }
        case .todos:
            Panel(title: "To-dos", subtitle: [TextRun(todos.openCount > 0 ? "\(todos.openCount) open" : "Nothing open")]) {
                HomeTodayCard(todos: todos, startChat: actions.startChatFromTodo, framed: false)
            }
        case .notes:
            Panel(title: "Notes", subtitle: [TextRun(notes.sorted.isEmpty ? "None yet" : "\(notes.sorted.count) note\(notes.sorted.count == 1 ? "" : "s")")]) {
                Button { actions.openNotes(.new) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(AppAppearance.tertiary).help("New note").accessibilityLabel("New note")
            } content: {
                HomeNotesCard(notes: notes, startChat: actions.startChatFromNote, framed: false, open: actions.openNotes)
            }
        }
    }
}

/// The Limits panel's rows: "Claude · 5-hour", "62% left", a thin grey bar, the reset in grey; an
/// account problem is one grey line.
struct HomeLimitsList: View {
    var rows: [HomeLimitRow]
    var note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if rows.isEmpty {
                Text(note).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text([row.provider, row.window].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 12.5))
                            .foregroundStyle(AppAppearance.text).lineLimit(1)
                        Spacer(minLength: 6)
                        if let remaining = row.remaining {
                            Text("\(Int(remaining.rounded()))% left").font(.system(size: 12, weight: .medium)).monospacedDigit()
                                .foregroundStyle(row.stale ? AppAppearance.tertiary : AppAppearance.secondary).fixedSize()
                        }
                    }
                    if let remaining = row.remaining { HomeLimitBar(fraction: remaining / 100) }
                    Text(row.detail + (row.stale && row.remaining != nil ? " · not checked lately" : "")).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A thin monochrome bar: what's left of a window.
private struct HomeLimitBar: View {
    var fraction: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(AppAppearance.separator)
                Capsule().fill(AppAppearance.tertiary).frame(width: max(2, geometry.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4).accessibilityHidden(true)
    }
}

extension HomePage {
    /// The strip's cells from `HomeStats`: avatars of the chats waiting (up to four) before the
    /// Waiting on you line, the amber dot only above zero, and with tracking on the category bar
    /// under Focused today, its Recording / Paused word, and a click that opens Today.
    static func statCells(_ stats: [TodayStat], waiting: Int, avatars: [(id: String, provider: AgentProvider)], tracked: ActivityDay?,
                          tracking: Bool, paused: Bool, openToday: @escaping () -> Void) -> [StatCellData] {
        stats.map { stat in
            var cell = StatCellData(id: stat.id, label: stat.label, dot: stat.dot && waiting > 0 ? AppAppearance.amber : nil, value: stat.value,
                                    valuePrefix: stat.valuePrefix, muted: stat.unknown, sub: stat.sub, help: stat.help)
            if stat.key == .waiting, !avatars.isEmpty {
                cell.accessory = AnyView(HStack(spacing: -4) {
                    ForEach(avatars.prefix(4), id: \.id) { ProviderAvatar(provider: $0.provider, id: $0.id, active: false, working: false, size: 15) }
                })
            }
            if stat.key == .focus, tracking {
                cell.badge = paused ? ("Paused", AppAppearance.tertiary) : ("Recording", AppAppearance.green)
                if let tracked, tracked.total > 0 { cell.footer = AnyView(ActivityCategoryBar(day: tracked)) }
                cell.action = openToday
            }
            return cell
        }
    }
}
