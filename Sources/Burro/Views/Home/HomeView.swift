// Burro's landing page, over the fixed aquarium backdrop. Left column: the greeting and one
// summary sentence, then what needs you, what is working and what is ready to read
// (HomeAttention.swift; one place per chat), then the main project, benches and projects as
// before. Right column: Ask the Orchestrator (composer and triage footer), Today so far (with
// activity tracking on), To-dos, Machines, Notes and the Scratchpad. Below about 900 pt the right
// column's cards move under Ready to read. New chat lives in the top bar.
// Read-only like the rest of monitoring. While on screen it keeps Mac Health sampling, syncs
// to-dos once a minute, rescans project activity every 90 seconds, and every 2 minutes (with
// tracking on) asks TodayStore to re-read today's tracked day once (shared by Today so far and
// the away figure) and reuse or redo today's agent scan without previews, from which it works out
// (locally, never sent anywhere) how long agents worked while you were away; it starts no other
// background work.
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
    /// Below this window width the right column's cards join the single column.
    static let twoColumnWidth: CGFloat = 900
    static let sideWidth: CGFloat = 320

    var body: some View {
        let summary = store.homeSummary
        let board = HomeChatSections.board(store: store, summary: summary)
        let fish = coverStyle == CoverField.Style.aquarium.rawValue ? AquariumFish.school(running: summary.running, waiting: summary.needsYou, scheduled: summary.scheduled, today: summary.today) : []
        GeometryReader { geometry in
        ZStack(alignment: .bottom) {
            // The backdrop stays put; the page scrolls over it.
            CoverBackdrop(running: summary.counts.running, waiting: summary.counts.waiting, fish: fish, hover: hover, animate: onScreen)
            ScrollView {
                page(summary: summary, board: board, width: geometry.size.width)
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
            // Today so far and the agents' time while you were away: one tracked-day read and at
            // most one preview-free agent scan per tick (the store reuses fresher results).
            while onScreen && !Task.isCancelled {
                if store.activityTracker.enabled { store.today.refreshAwayAgentTime() }
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

    @ViewBuilder private func page(summary: HomeSummary, board: HomeBoard, width: CGFloat) -> some View {
        let content = min(width, 1220) - 56
        let wide = width >= Self.twoColumnWidth
        let left = wide ? content - Self.sideWidth - 28 : content
        let top = VStack(alignment: .leading, spacing: 26) {
            HomeCover(sentence: sentence(board), checking: !store.didCheckAgents)
            HomeChatSections(store: store, summary: summary, board: board, columns: left >= 780 ? 3 : left >= 460 ? 2 : 1)
        }
        let lower = VStack(alignment: .leading, spacing: 30) {
            HomeMainProject(store: store, summary: summary)
            benches(summary)
            projects(summary)
        }
        if wide {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 34) { top; lower }.frame(maxWidth: .infinity, alignment: .leading)
                side(summary).frame(width: Self.sideWidth)
            }
        } else {
            VStack(alignment: .leading, spacing: 30) { top; side(summary); lower }
        }
    }

    private func side(_ summary: HomeSummary) -> some View {
        VStack(spacing: 14) {
            HomeAskCard(store: store)
            if store.activityTracker.enabled {
                HomeActivityCard(tracker: store.activityTracker, day: store.today.todayTracked, awayAgentTime: store.today.awayAgentTime,
                                 awayPartial: store.today.awayAgentTimePartial) {
                    store.today.show(Date()); store.page = .today
                }
            }
            HomeTodayCard(todos: store.todos, startChat: { store.startChat(from: $0) })
            HomeMachinesCard(store: store, summary: summary)
            HomeNotesCard(notes: store.notes, startChat: { store.startChat(withText: $0.content) }) { store.showNotes?($0) }
            HomeScratchpadCard(notes: store.notes)
        }
    }

    /// "2 chats need you, 3 are working, and 4 pull requests shipped today." plus a low usage limit.
    private func sentence(_ board: HomeBoard) -> String {
        let now = Date()
        let shipped = store.shipped.shipped(now)?.merged.count
        let providers = store.usage.enabled ? store.usage.snapshot.providers : []
        return HomeBoard.sentence(needsYou: board.needsYou.count, working: board.working.count, toRead: board.toRead.count,
                                  shipped: shipped, usageLine: HomeBoard.usageLine(providers, now: now))
    }

    private func newBench() -> Bench {
        Bench(id: UUID(), name: "", symbol: Bench.symbols[store.benches.benches.count % Bench.symbols.count],
              color: store.benches.benches.count % Bench.colors.count, projects: [])
    }

    @ViewBuilder private func benches(_ summary: HomeSummary) -> some View {
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

    @ViewBuilder private func projects(_ summary: HomeSummary) -> some View {
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
