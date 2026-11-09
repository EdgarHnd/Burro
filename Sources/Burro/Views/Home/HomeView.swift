// Burro's landing page: a cover, your projects and machines as benches, a plain-language summary,
// and to-dos, notes and a scratchpad on the side. Read-only like the rest of monitoring. While on
// screen it keeps Mac Health sampling, syncs to-dos and rescans today's activity at most every
// 90 seconds; it starts no other background work.
import SwiftUI
import BurroCore

struct HomeView: View {
    @Bindable var store: AppStore
    var notch: NotchController
    @State private var onScreen = false
    @State private var editingBench: Bench?

    var body: some View {
        let summary = store.homeSummary
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HomeCover(store: store, summary: summary)
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 30) {
                            quickActions
                            HomeOrchestrator(store: store)
                            HomeMainProject(store: store, summary: summary)
                            benches(summary)
                            projects(summary)
                            machines(summary)
                            summaryText(summary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(spacing: 16) {
                            HomeTodayCard(todos: store.todos)
                            if !summary.needsYou.isEmpty || !summary.unread.isEmpty { HomeInbox(store: store, summary: summary) }
                            HomeNotesCard(notes: store.notes)
                            HomeScratchpadCard(notes: store.notes)
                        }.frame(width: 320)
                    }
                }
                .padding(.horizontal, 30).padding(.top, 20).padding(.bottom, 120)
                .frame(maxWidth: 1240).frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            // Content fades out under the floating dock instead of colliding with it.
            LinearGradient(colors: [AppAppearance.background.opacity(0), AppAppearance.background.opacity(0.92)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 96).allowsHitTesting(false)
            HomeDock(store: store, summary: summary, notch: notch).padding(.bottom, 20).padding(.horizontal, 24)
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

    private var quickActions: some View {
        HStack(spacing: 12) {
            PillButton(title: "Chat", symbol: "plus.bubble") { store.newChatPresented = true }.help("Start a Codex or Claude chat (⌘N)")
            PillButton(title: "Project", symbol: "folder.badge.plus") { store.addRepository() }.help("Add a repository")
            PillButton(title: "Machine", symbol: "server.rack") { store.page = .machines }.help("See your machines and their agent tools")
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
                        BenchCard(title: bench.name, symbol: bench.symbol, tint: bench.tint, counts: rollup.counts,
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
                        BenchCard(title: project.name, symbol: project.isRepository ? nil : "folder",
                                  tint: HomeStyle.tint(for: project.name), counts: project.counts,
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
                              tint: machine.connection == .local ? AppAppearance.green : (machine.connection == .online ? .teal : AppAppearance.tertiary),
                              counts: machine.counts,
                              quiet: machine.connection == .local || machine.connection == .online ? "Quiet" : MachinesModel.connection(machine.connection),
                              help: machine.connection == .local ? "Mac Health" : "Machines") {
                        store.page = machine.connection == .local ? .health : .machines
                    }
                }
            }
        }
    }

    private func summaryText(_ summary: HomeSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.didCheckAgents ? summary.sentence : "Checking on your agents…")
                .font(.system(size: 17)).lineSpacing(5).foregroundStyle(AppAppearance.text)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 720, alignment: .leading)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Image(systemName: "clock")
                Text(store.agentActivity.sampledAt == .distantPast ? "Waiting for the first check" : "Updated \(HomeFormat.ago(store.agentActivity.sampledAt))")
                Button { Task { await store.refreshAgents() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Check agents now")
            }.font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
        }.padding(.top, 4)
    }
}
