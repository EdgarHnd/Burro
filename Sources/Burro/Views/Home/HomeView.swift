// Burro's landing page, over the fixed aquarium backdrop, in the dashboard layout (HomePage.swift):
// the greeting and sentence and the KPI strip straight on the water, the joined panels (what your
// agents are doing beside the queue with Ask the Orchestrator; Machines, Limits, To-dos) at 0.9
// opacity, then the main project, benches, projects, notes and the scratchpad below. New chat lives
// in the window's strip.
// Read-only like the rest of monitoring. While on screen it keeps Mac Health sampling, syncs
// to-dos once a minute, rescans project activity every 90 seconds, and every 2 minutes asks
// TodayStore for today's agent scan without previews (reused when under 100 seconds old) for the
// lanes; with tracking on the same call also re-reads today's tracked day once (Focused today and
// the away figure, worked out locally and never sent anywhere). It starts no other background work
// and no timer of its own.
import SwiftUI
import BurroCore

struct HomeView: View {
    @Bindable var store: AppStore
    /// Kept for the caller; the notch button left with the dock (⇧⌘B still shows it).
    var notch: NotchController
    @State private var onScreen = false
    @State private var editingBench: Bench?
    @State private var hover = AquariumHover()
    @AppStorage("home.coverStyle") private var coverStyle = CoverField.Style.aquarium.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let space = "home"

    var body: some View {
        let summary = store.homeSummary
        let board = HomeChatSections.board(store: store, summary: summary)
        let fish = coverStyle == CoverField.Style.aquarium.rawValue ? AquariumFish.school(running: summary.running, waiting: summary.needsYou, scheduled: summary.scheduled, today: summary.today) : []
        GeometryReader { geometry in
        ZStack(alignment: .bottom) {
            // The backdrop stays put; the page scrolls over it.
            CoverBackdrop(running: summary.counts.running, waiting: summary.counts.waiting, fish: fish, hover: hover, animate: onScreen)
            ScrollView {
                HomeLivePage(store: store, summary: summary, board: board, editingBench: $editingBench)
                .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 48)
                .frame(maxWidth: 1220).frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .top)
                // Behind the cards: the open water, where a fish can be hovered and clicked.
                .background {
                    AquariumCatcher(hover: hover, fish: fish, size: geometry.size, animate: onScreen && !reduceMotion, space: Self.space) { id in
                        if let session = (summary.needsYou + summary.running + summary.scheduled + summary.today).first(where: { $0.id == id }) { store.showChat(session) }
                    }
                }
            }
            .scrollIndicators(.automatic)
            AquariumLabel(hover: hover, size: geometry.size)
        }
        .coordinateSpace(name: Self.space)
        }
        .background(AppAppearance.background)
        .background(WindowOcclusionReader { onScreen = $0 })
        .sheet(item: $editingBench) { bench in
            BenchEditor(bench: bench, benches: store.benches, projects: store.repositoriesFound)
        }
        // Each task ends when Home is hidden, covered or closed.
        .task(id: onScreen) { if onScreen { await store.health.observe() } }
        .task(id: onScreen) { if onScreen { await store.refreshUsage() } }
        .task(id: onScreen) {
            while onScreen && !Task.isCancelled {
                store.todos.sync()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .task(id: onScreen) {
            // The lanes (and, with tracking on, Focused today and the agents' time while you were away):
            // at most one preview-free agent scan per tick, and one tracked-day read with tracking on
            // (the store reuses fresher results).
            guard onScreen else { return }
            store.today.profiles = { [weak store] in store?.usage.preferences.profiles ?? [:] }
            while onScreen && !Task.isCancelled {
                if store.activityTracker.enabled { store.today.refreshAwayAgentTime() } else { store.today.refreshTodayActivity() }
                try? await Task.sleep(for: .seconds(120))
            }
        }
        .task(id: onScreen) {
            while onScreen && !Task.isCancelled {
                store.refreshProjectActivity()
                try? await Task.sleep(for: .seconds(90))
            }
        }
    }
}

/// Maps the live feed, the Brief, the Orchestrator's proposals, today's scan, the tracked day,
/// usage and machines onto `HomePage`, and runs its actions. Every action is the owner's click;
/// nothing here starts, messages or stops a chat by itself. Lanes, counts and cells are computed
/// once per render from values already in memory.
struct HomeLivePage: View {
    @Bindable var store: AppStore
    var summary: HomeSummary
    var board: HomeBoard
    @Binding var editingBench: Bench?
    @State private var editing: String?
    @State private var stopping: Set<String> = []
    /// Stop's result line per chat, kept only while that chat's turn (HomeBoard.turnKey) is the same.
    @State private var notes: [String: (text: String, turn: String)] = [:]
    @State private var queueTab: String?

    var body: some View {
        let now = Date()
        let shownWorking = board.working.prefix(HomeChatSections.workingCap).map(\.session)
        let claude = shownWorking.filter { $0.provider == .claude }
        let unlisted = store.unlistedChatIDs(board.needsYou.prefix(HomeChatSections.needsCap).filter { $0.session == nil }.compactMap { $0.item?.chatID })
        HomePage(data: data(now: now), actions: pageActions, todos: store.todos, notes: store.notes, editingID: editing,
                 editor: { id in needs.editor(board.needsYou.first { $0.id == id }) }, queueTab: $queueTab) {
            HomeAskCard(store: store, inline: true)
        } below: {
            HomeMainProject(store: store, summary: summary)
            benches
            projects
        }
        // The Claude open-session checks Stop is decided by, shared with the notch and cached
        // for a minute per chat and state; run only for the working rows shown.
        .task(id: claude.map { "\($0.id)|\($0.state.rawValue)" }) {
            for session in claude { await NotchReplyChecks.shared.refresh(session, host: host(session)) }
        }
        // Claude app links for Brief items whose chat has left Burro's list (closed chats).
        .task(id: unlisted) { await ClosedChatLinks.shared.refresh(unlisted) }
    }

    private var needs: HomeNeedsBuilder { HomeNeedsBuilder(store: store) }
    private func host(_ session: AgentSession) -> RemoteHost? { store.remoteHosts.first { $0.id == session.remote?.hostID } }
    private func turnKey(_ session: AgentSession) -> String { HomeBoard.turnKey(session, turnStart: store.turnClock.starts[session.id]) }

    /// Today's scan, only while it is today's.
    private var todayActivity: DailyActivity? {
        store.today.todayActivity.flatMap { Calendar.current.isDateInToday($0.day) ? $0 : nil }
    }

    // MARK: Page values

    private func data(now: Date) -> HomePageData {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let day = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
        let activity = todayActivity
        let builder = needs
        let inputs = HomeLanes.inputs(board, place: builder.place, turnStart: { store.turnClock.starts[$0] })
        let lanes = TodayLanes.build(inputs, activity: activity, needsSince: HomeLanes.needsSince(board), brief: store.brief.file.items,
                                     window: day, isToday: true, now: now, calendar: calendar)
        // The axis spans what is drawn: the lanes shown (the rest open in Chats).
        let window = DayRibbonLayout.laneWindow(day: day, pieces: HomeLanes.pieces(Array(lanes.prefix(HomeLanes.cap))), now: now, calendar: calendar)
        let tracking = store.activityTracker.enabled
        let projects = summary.projects
        let stats = HomeStats.cells(
            working: board.working.count, longestTurn: board.working.compactMap { store.turnClock.turn($0.id, now: now) }.max(),
            machines: board.working.map { builder.machine($0.session) }, waiting: board.needsYou.count,
            oldestWaiting: board.needsYou.map(\.since).min(), activity: activity, toRead: board.toRead.count, stuck: store.brief.stuck.count,
            newestToRead: board.toRead.map(\.session.updatedAt).max(),
            day: tracking ? .tracked(store.today.todayTracked, away: store.today.awayAgentTime, awayPartial: store.today.awayAgentTimePartial)
                : .value(dollars: store.projectActivity == nil ? nil : projects.reduce(0) { $0 + $1.apiValueToday },
                         tokens: store.projectActivity == nil ? nil : projects.reduce(0) { $0 + $1.tokensToday }),
            calendar: calendar)
        let usage = store.usage
        let limitsShown = usage.enabled && !usage.preferences.providers.isEmpty
        return HomePageData(
            now: now, sentence: sentence(now: now), checking: !store.didCheckAgents,
            stats: HomePage<EmptyView, EmptyView>.statCells(stats, waiting: board.needsYou.count,
                                                            avatars: board.needsYou.compactMap { entry in entry.session.map { ($0.id, $0.provider) } },
                                                            tracked: store.today.todayTracked, tracking: tracking, paused: store.activityTracker.paused,
                                                            openToday: openToday),
            lanes: lanes, laneWindow: window.window, day: day, scanned: activity != nil, board: boardData(now: now),
            machines: HomeMachineRows.rows(store: store, summary: summary),
            limits: limitsShown ? HomeLimits.rows(usage.snapshot.providers, shown: usage.preferences.providers, now: now) : nil,
            limitsNote: usage.snapshot.availability == .loading ? "Loading limits…" : "Connect an account on the Usage page.")
    }

    /// "2 chats need you, 3 are working, and 4 pull requests shipped today." plus a low usage limit.
    private func sentence(now: Date) -> [TextRun] {
        let shipped = store.shipped.shipped(now)?.merged.count
        let providers = store.usage.enabled ? store.usage.snapshot.providers : []
        return HomeBoard.sentenceRuns(needsYou: board.needsYou.count, working: board.working.count, toRead: board.toRead.count,
                                      shipped: shipped, usageLine: HomeBoard.usageLine(providers, now: now))
    }

    private func boardData(now: Date) -> HomeBoardData {
        HomeBoardData(
            needsYou: board.needsYou.prefix(HomeChatSections.needsCap).map { needs.card($0, now: now) }, needsTotal: board.needsYou.count,
            working: board.working.prefix(HomeChatSections.workingCap).map { workingCard($0, now: now) }, workingTotal: board.working.count,
            toRead: board.toRead.prefix(HomeChatSections.readCap).map {
                HomeReadRowData(id: $0.id, title: $0.session.title, outcome: $0.outcome, time: HomeTime.clock($0.session.updatedAt, now: now))
            },
            toReadTotal: board.toRead.count, checking: !store.didCheckAgents)
    }

    private func workingCard(_ entry: HomeBoard.Working, now: Date) -> HomeWorkingCardData {
        let session = entry.session
        let folder = URL(fileURLWithPath: session.remote == nil ? store.workspacePath(for: session) : session.cwd).lastPathComponent
        let state = entry.stuck?.headline ?? (folder.isEmpty ? "Working" : "Working in \(folder)")
        let time = store.turnClock.turn(session.id, now: now).map(HomeBoard.turnText) ?? HomeBoard.activeText(session.updatedAt, now: now)
        let note = notes[session.id].flatMap { $0.turn == turnKey(session) ? $0.text : nil }
        return HomeWorkingCardData(id: session.id, title: session.title, state: state, machine: needs.machine(session), time: time,
                                   stop: HomeBoard.stopOffer(session, host: host(session), check: NotchReplyChecks.shared.check(for: session)),
                                   handOff: needs.handOffTitle(session), stopping: stopping.contains(session.id), note: note,
                                   stuck: entry.stuck != nil)
    }

    // MARK: Actions

    private var pageActions: HomePageActions {
        var actions = needs.actions(board) { id in editing = editing == id ? nil : id }
        actions.stop = { id in if let session = board.working.first(where: { $0.id == id })?.session { stop(session) } }
        actions.markAllRead = { [board, store] in
            // Burro's own "seen"; the providers' unread markers are never written.
            var changed = false
            for entry in board.toRead { changed = ChatLocalStore.shared.markSeen(entry.session) || changed }
            if changed { store.rebuildAgentActivity() }
        }
        let store = self.store, board = self.board
        return HomePageActions(
            board: actions,
            openLane: { id in
                let session = board.needsYou.first { $0.session?.id == id }?.session
                    ?? board.working.first { $0.id == id }?.session ?? board.toRead.first { $0.id == id }?.session
                if let session { store.showChat(session) }
            },
            openToday: openToday,
            openMachine: { row in store.page = row.local ? .health : .machines },
            openMachines: { store.page = .machines },
            openUsage: { store.page = .usage },
            startChatFromTodo: { store.startChat(from: $0) },
            startChatFromNote: { store.startChat(withText: $0.content) },
            openNotes: { store.showNotes?($0) })
    }

    private var openToday: () -> Void {
        let store = self.store
        return { store.today.show(Date()); store.page = .today }
    }

    private func stop(_ session: AgentSession) {
        guard !stopping.contains(session.id) else { return }
        stopping.insert(session.id); notes[session.id] = nil
        let host = host(session), turn = turnKey(session)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                Result { try ChatReply.stop(session, host: host) }
            }.value
            stopping.remove(session.id)
            switch result {
            case .success(let confirmation): notes[session.id] = (confirmation, turn); await store.refreshAgents()
            case .failure(let failure): notes[session.id] = ((failure as? LocalizedError)?.errorDescription ?? "Couldn't stop it.", turn)
            }
            NotchReplyChecks.shared.invalidate(session.id)
        }
    }

    // MARK: Below

    private func newBench() -> Bench {
        Bench(id: UUID(), name: "", symbol: Bench.symbols[store.benches.benches.count % Bench.symbols.count],
              color: store.benches.benches.count % Bench.colors.count, projects: [])
    }

    @ViewBuilder private var benches: some View {
        if !store.benches.benches.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HomeSectionHeader(title: "Benches") { Button("New bench") { editingBench = newBench() } }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 18) {
                    ForEach(store.benches.benches) { bench in
                        let rollup = store.benches.rollup(bench, projects: summary.projects)
                        BenchCard(title: bench.name, symbol: bench.symbol, counts: rollup.counts,
                                  quiet: rollup.tokens > 0 ? HomeFormat.tokens(rollup.tokens) + " tokens today"
                                         : "\(bench.projects.count) project\(bench.projects.count == 1 ? "" : "s") · Quiet",
                                  help: "Show \(bench.name)'s worktrees") {
                            store.search = ""; store.filter = .bench(bench.id); store.page = .worktrees
                        }
                        .contextMenu {
                            Button("Edit Bench…") { editingBench = bench }
                            Button("Delete Bench", role: .destructive) { store.benches.remove(bench.id) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var projects: some View {
        // With benches, show only the projects that aren't on one.
        let benched = Set(store.benches.benches.flatMap(\.projects))
        let main = store.mainProject?.path
        let loose = summary.projects.filter { !benched.contains($0.id) && $0.id != main }
        if !(loose.isEmpty && !benched.isEmpty) {
        VStack(alignment: .leading, spacing: 14) {
            HomeSectionHeader(title: benched.isEmpty ? "Projects" : "Other projects") {
                HStack(spacing: 14) {
                    if store.benches.benches.isEmpty { Button("Group into benches") { editingBench = newBench() } }
                    Button(loose.count > 6 ? "View all \(loose.count)" : "All worktrees") {
                        store.filter = .all; store.page = .worktrees
                    }
                }
            }
            if loose.isEmpty && benched.isEmpty {
                HomeEmptyCard(symbol: "folder.badge.plus", title: store.didScan ? "No projects yet" : "Looking for projects…",
                              detail: "Burro finds repositories in ~/Dev and wherever your agents work.") {
                    Button("Add repository") { store.addRepository() }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 18) {
                    ForEach(loose.prefix(6)) { project in
                        BenchCard(title: project.name, symbol: project.isRepository ? nil : "folder", counts: project.counts,
                                  quiet: project.tokensToday > 0 ? HomeFormat.tokens(project.tokensToday) + " tokens today" : "Quiet",
                                  help: project.isRepository ? "Show \(project.name)'s worktrees" : project.id) { store.showProject(project) }
                    }
                }
            }
        }
        }
    }
}
