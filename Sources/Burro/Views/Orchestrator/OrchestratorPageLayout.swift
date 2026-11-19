// The Orchestrator page in the dashboard layout (Today's). The shared page header: the title, what
// the Brief holds and when triage last ran as its sentence ("2 need you" amber), and Run triage now
// trailing, which looks through the newest chats waiting on you or unread and triages up to five not
// triaged since they last changed, at once, through the Brief's own gate (off, the caps or Claude's
// limits queue nothing and say why; "Nothing new to triage" when so). A strip of four numbers
// (`OrchestratorComposition`: Needs you, Finished, Stuck, Triage today). The Brief · Memory · Runs
// tabs. The Brief tab is one joined surface: the conversation and composer in the tall left column
// (OrchestratorPage.swift), and beside it a scrolling right column of stacked panels with hairlines:
// the Brief queue (OrchestratorBriefQueue.swift), Memory, Budget and the last runs
// (OrchestratorSideCards.swift); below 760 points everything stacks in one scrolling column with the
// conversation 620 points tall. Memory and Runs keep their content on the same kind of surface. The
// page reloads memory or runs when you switch to that tab (OrchestratorPage loads both when it
// appears); `tab` can be set from outside, so snapshot tests draw any tab without reading files.
import SwiftUI
import BurroCore

/// The page with everything it shows passed in, so it can also be drawn offscreen with sample data.
struct OrchestratorPageLayout: View {
    @Bindable var store: AppStore
    var budget: OrchestratorBudget
    var now: Date
    @State private var tab: OrchestratorTab
    @State private var triageNote: String?

    init(store: AppStore, budget: OrchestratorBudget, now: Date, tab: OrchestratorTab = .brief) {
        self.store = store; self.budget = budget; self.now = now
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Orchestrator", inset: 0, eyebrow: "Brief, memory and runs", sentence: sentence, top: 0, bottom: 0) { headerControls }
            StatStrip(cells: cells)
            tabBar
            switch tab {
            case .brief: briefTab
            case .memory: tabScroll { OrchestratorMemoryView(store: store) }
            case .runs: tabScroll { OrchestratorRunsView(store: store) }
            }
        }
        .padding(.horizontal, 36).padding(.top, 28).padding(.bottom, 24)
        .frame(maxWidth: 1240, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: takeTabRequest)
        .onChange(of: store.orchestratorTabRequest) { _, _ in takeTabRequest() }
        .onChange(of: tab) { _, tab in
            switch tab {
            case .memory: store.orchestrator.reloadMemory()
            case .runs: store.orchestrator.reloadRuns()
            case .brief: break
            }
        }
    }

    /// Settings can ask for a tab (Memory); show it once and clear the request.
    private func takeTabRequest() {
        guard let request = store.orchestratorTabRequest else { return }
        tab = request
        store.orchestratorTabRequest = nil
    }

    // MARK: Header, strip, tabs

    private var sentence: [TextRun] {
        let brief = store.brief
        return OrchestratorComposition.sentence(needs: brief.needsYou.count, finished: brief.finished.count, stuck: brief.stuck.count,
                                                lastTriage: brief.lastRunAt, triaging: brief.triaging, now: now)
    }

    private var cells: [StatCellData] {
        let brief = store.brief
        return OrchestratorComposition.stats(needs: brief.needsYou.count, oldestNeed: brief.needsYou.map(\.updatedAt).min(),
                                             finished: brief.finished.count, stuck: brief.stuck.count, budget: budget, gate: brief.gate, now: now)
            .map { StatCellData($0) }
    }

    private var headerControls: some View {
        let brief = store.brief
        let gate = brief.gate
        return HStack(spacing: 10) {
            if let triageNote {
                Text(triageNote).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
            }
            Button(brief.checkingNow ? "Looking…" : "Run triage now") { runTriage() }
                .buttonStyle(OrchButtonStyle(kind: .ghost, large: true)).fixedSize()
                .disabled(!gate.allowsRun || brief.triaging > 0 || brief.checkingNow)
                .help(gate == .off ? "Automatic triage is off: turn it on in Budget first."
                      : gate.reason ?? (brief.triaging > 0 ? "Triage is reading chats now."
                      : "Triage up to five of the newest chats waiting on you or unread that haven't been triaged since they last changed, now (counted toward today's cap)."))
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(OrchestratorTab.allCases) { item in
                Button { tab = item } label: {
                    Text(item.rawValue).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tab == item ? AppAppearance.text : AppAppearance.secondary)
                        .padding(.horizontal, 12).frame(height: 32)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(tab == item ? AppAppearance.text : .clear).frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
            Spacer()
        }
        .overlay(alignment: .bottom) { Rectangle().fill(AppAppearance.separator).frame(height: 1) }
    }

    private func runTriage() {
        Task {
            let outcome = await store.brief.runNow()
            triageNote = outcome.message
            try? await Task.sleep(for: .seconds(6))
            if triageNote == outcome.message { triageNote = nil }
        }
    }

    // MARK: Brief tab

    private var briefTab: some View {
        GeometryReader { proxy in
            let width = Double(proxy.size.width)
            if OrchestratorPageColumns.count(width: width) == 2 {
                HStack(spacing: 0) {
                    OrchestratorTodayCard(store: store, now: now).frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle().fill(AppAppearance.separator).frame(width: 1).accessibilityHidden(true)
                    ScrollView { sideColumn }.scrollIndicators(.never)
                        .frame(width: CGFloat(OrchestratorPageColumns.sideWidth(width: width)))
                }
                .modifier(OrchJoinedSurface())
            } else {
                tabScroll {
                    VStack(spacing: 0) {
                        OrchestratorTodayCard(store: store, now: now).frame(height: 620)
                        Rectangle().fill(AppAppearance.separator).frame(height: 1).accessibilityHidden(true)
                        sideColumn
                    }
                    .modifier(OrchJoinedSurface())
                }
            }
        }
    }

    /// A tab's scrolling surface, reaching into the page's margins so the surface's shadow isn't cut off at its sides.
    private func tabScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView { content().padding(.horizontal, 14).padding(.bottom, 14) }
            .scrollIndicators(.never).padding(.horizontal, -14)
    }

    /// The queue, then Memory, Budget and the last runs, stacked with hairlines.
    private var sideColumn: some View {
        JoinedRow(weights: [], stackBelow: .infinity) {
            OrchestratorBriefQueue(store: store, now: now)
            OrchestratorMemoryCard(store: store) { tab = .memory }
            OrchestratorBudgetCard(budget: budget, enabled: Bindable(store.brief).autoTriage, now: now)
            OrchestratorRecentRunsCard(runs: store.orchestrator.recentRuns) { tab = .runs }
        }
    }
}

/// The Brief tab's one surface, drawn as `JoinedPanels` draws its own: cells unfilled inside it,
/// clipped to the card radius, the soft surface and its hairline edge.
struct OrchJoinedSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.panelFill, .clear)
            .clipShape(RoundedRectangle(cornerRadius: AppAppearance.cardRadius, style: .continuous))
            .modifier(SoftSurface(radius: AppAppearance.cardRadius))
    }
}
