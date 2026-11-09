// Burro's landing page: what your agents are doing, where, and what needs you, at a glance.
// Read-only like the rest of monitoring. While on screen it keeps Mac Health sampling and
// rescans today's activity at most every 90 seconds; it starts no new background polling.
import SwiftUI
import BurroCore

struct HomeView: View {
    @Bindable var store: AppStore
    var notch: NotchController
    @State private var onScreen = false

    var body: some View {
        let summary = store.homeSummary
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    HomeHero(store: store, summary: summary, notch: notch)
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 32) {
                            projects(summary)
                            machines(summary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(spacing: 14) {
                            HomeInbox(store: store, summary: summary)
                            HomeUsageTile(store: store)
                            HomeMacTile(store: store)
                        }.frame(width: 300)
                    }
                }
                .padding(.horizontal, 36).padding(.top, 28).padding(.bottom, 120)
                .frame(maxWidth: 1200).frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            HomeDock(store: store, summary: summary, notch: notch).padding(.bottom, 22)
        }
        .background(AppAppearance.background)
        .background(WindowOcclusionReader { onScreen = $0 })
        // Each task ends when Home is hidden, covered or closed.
        .task(id: onScreen) { if onScreen { await store.health.observe() } }
        .task(id: onScreen) { if onScreen { await store.refreshUsage() } }
        .task(id: onScreen) {
            while onScreen && !Task.isCancelled {
                store.refreshProjectActivity()
                try? await Task.sleep(for: .seconds(90))
            }
        }
    }

    @ViewBuilder private func projects(_ summary: HomeSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: "Projects") {
                Button(summary.projects.count > 6 ? "View all \(summary.projects.count)" : "All worktrees") {
                    store.filter = .all; store.page = .worktrees
                }
            }
            if summary.projects.isEmpty {
                HomeEmptyCard(symbol: "folder.badge.plus", title: store.didScan ? "No projects yet" : "Looking for projects…",
                              detail: "Burro finds repositories in ~/Dev and wherever your agents work.") {
                    Button("Add repository") { store.addRepository() }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 236), spacing: 12)], spacing: 12) {
                    ForEach(summary.projects.prefix(6)) { project in
                        HomeProjectCard(project: project) { store.showProject(project) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func machines(_ summary: HomeSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: "Machines") {
                if store.remoteHosts.isEmpty { SettingsLink { Text("Add a machine") }.help("Remote machines are added in Settings") }
                else { Button("Remote sessions") { store.page = .remote } }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 236), spacing: 12)], spacing: 12) {
                ForEach(summary.machines) { machine in
                    HomeMachineCard(machine: machine, health: machine.connection == .local ? store.health.snapshot : nil) {
                        store.page = machine.connection == .local ? .health : .remote
                    }
                }
            }
        }
    }
}

// MARK: Hero

private struct HomeHero: View {
    var store: AppStore
    var summary: HomeSummary
    var notch: NotchController
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            BurroMark(active: true, working: summary.counts.running > 0, tint: HomeStyle.butter)
                .frame(width: 34, height: 34)
                .frame(width: 60, height: 60)
                .background(HomeStyle.charcoal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.06)))
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(greeting).font(.system(size: 28, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                }
                Text(store.didCheckAgents ? summary.sentence : "Checking on your agents…")
                    .font(.system(size: 14)).foregroundStyle(AppAppearance.secondary)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 680, alignment: .leading)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    HomeChip(count: summary.counts.running, label: "running", color: AppAppearance.green, symbol: "waveform.path") {
                        store.filter = .working; store.page = .worktrees
                    }
                    HomeChip(count: summary.counts.waiting, label: "need you", color: AppAppearance.amber, symbol: "hand.raised") {
                        if let first = summary.needsYou.first { store.open(first) } else { notch.show() }
                    }
                    HomeChip(count: summary.counts.done, label: "to read", color: AppAppearance.blue, symbol: "checkmark.circle") {
                        if let first = summary.unread.first { store.open(first) } else { notch.show() }
                    }
                    if summary.counts.scheduled > 0 {
                        HomeChip(count: summary.counts.scheduled, label: "scheduled", color: .teal, symbol: "clock") { notch.show() }
                    }
                    if let activity = store.projectActivity, activity.tokens > 0 {
                        HomeChip(text: HomeFormat.tokens(activity.tokens) + " tokens today", symbol: "chart.bar") { store.page = .usage }
                            .help(activity.apiValue > 0 ? "About \(HomeFormat.money(activity.apiValue)) at API prices. Local Codex and Claude logs on this Mac." : "Local Codex and Claude logs on this Mac.")
                    }
                }.padding(.top, 4)
            }
        }
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(AppAppearance.surface)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [HomeStyle.heroWash, .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(AppAppearance.separator))
        .shadow(color: AppAppearance.shadow, radius: 14, y: 4)
    }
    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        case 18..<23: "Good evening"
        default: "Working late"
        }
    }
}
