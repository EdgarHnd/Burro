// Burro's landing page: a cover with a greeting, live chips and a plain-language summary, then what
// needs you, the Orchestrator, the main project, your projects and machines as benches, and to-dos,
// today so far (when activity tracking is on), notes and a scratchpad on the side.
// Read-only like the rest of monitoring. While on screen it keeps Mac Health sampling, syncs
// to-dos, rescans today's activity at most every 90 seconds and re-reads today's tracked activity
// once a minute; it starts no other background work.
import SwiftUI
import BurroCore

struct HomeView: View {
    @Bindable var store: AppStore
    var notch: NotchController
    @State private var onScreen = false
    @State private var editingBench: Bench?
    @State private var hover = AquariumHover()
    @AppStorage("home.coverStyle") private var coverStyle = CoverField.Style.aquarium.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let space = "home"

    var body: some View {
        let summary = store.homeSummary
        let fish = coverStyle == CoverField.Style.aquarium.rawValue ? AquariumFish.school(running: summary.running, waiting: summary.needsYou, scheduled: summary.scheduled, today: summary.today) : []
        GeometryReader { geometry in
        ZStack(alignment: .bottom) {
            // The backdrop stays put; the page scrolls over it.
            CoverBackdrop(running: summary.counts.running, waiting: summary.counts.waiting, fish: fish, hover: hover, animate: onScreen)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HomeCover(store: store, summary: summary)
                    HomeAttention(store: store, summary: summary)
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 30) {
                            HomeOrchestrator(store: store)
                            HomeMainProject(store: store, summary: summary)
                            benches(summary)
                            projects(summary)
                            machines(summary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(spacing: 16) {
                            HomeTodayCard(todos: store.todos)
                            if store.activityTracker.enabled {
                                HomeActivityCard(tracker: store.activityTracker, active: onScreen) {
                                    store.today.show(Date()); store.page = .today
                                }
                            }
                            HomeNotesCard(notes: store.notes) { store.showNotes?($0) }
                            HomeScratchpadCard(notes: store.notes)
                        }.frame(width: 320)
                    }
                }
                .padding(.horizontal, 30).padding(.top, 20).padding(.bottom, 120)
                .frame(maxWidth: 1240).frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .top)
                // Behind the cards: the open water, where a fish can be hovered and clicked.
                .background {
                    AquariumCatcher(hover: hover, fish: fish, size: geometry.size, animate: onScreen && !reduceMotion, space: Self.space) { id in
                        if let session = (summary.needsYou + summary.running + summary.scheduled + summary.today).first(where: { $0.id == id }) { store.showChat(session) }
                    }
                }
            }
            .scrollIndicators(.automatic)
            // Content fades out under the floating dock, leaving the backdrop showing through.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 110)
                }
            }
            HomeDock(store: store, summary: summary, notch: notch).padding(.bottom, 20).padding(.horizontal, 24)
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
            while onScreen && !Task.isCancelled {
                store.refreshProjectActivity()
                try? await Task.sleep(for: .seconds(90))
            }
        }
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

    @ViewBuilder private func machines(_ summary: HomeSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HomeSectionHeader(title: "Machines") { Button("All machines") { store.page = .machines } }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 18) {
                ForEach(summary.machines) { machine in
                    BenchCard(title: machine.name, symbol: machine.connection == .local ? "laptopcomputer" : "desktopcomputer",
                              dimmed: !(machine.connection == .local || machine.connection == .online),
                              counts: machine.counts,
                              quiet: machine.connection == .local || machine.connection == .online ? "Quiet" : MachinesModel.connection(machine.connection),
                              help: machine.connection == .local ? "Mac Health" : "Machines") {
                        store.page = machine.connection == .local ? .health : .machines
                    }
                }
            }
        }
    }
}
