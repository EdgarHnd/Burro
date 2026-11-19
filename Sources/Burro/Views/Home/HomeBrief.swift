// Home's "Ask the Orchestrator", at the foot of the queue panel (`inline`: the composer and one quiet
// line; the card style remains for other hosts). What used to be the Brief
// card is split up: its Needs you items (with their drafts) are Home's Needs you cards, its
// Finished headlines are the Ready to read outcomes and its Stuck lines are the Working cards'
// state lines (HomeAttention.swift). This card keeps the rest: the composer (always open; Return
// sends the question to the Orchestrator, which only ever proposes work), a line for proposals
// the Orchestrator made in conversation that wait for you, what it is doing now or its last
// error, a link to its last answer with its age (never the earlier answer's text), its setup
// problem, and the triage footer ("Triage: 9 today · On" / "· Off" / why it's paused) that turns
// automatic triage on or off, with "Reading N chats…" while triage runs. The header opens the
// Orchestrator page. Plain values in `HomeAskCardContent` so it can be rendered offscreen.
import SwiftUI
import BurroCore

struct HomeAskCardData: Equatable {
    var footer: String
    var footerHelp: String
    var triaging = 0
    /// Why triage is paused, shown beside the footer while automatic triage is on.
    var problem: String?
    /// Proposals made in conversation that aren't shown as a Needs you draft.
    var proposalsWaiting = 0
    /// What the Orchestrator is doing now.
    var activity: String?
    var error: String?
    /// "Last answer 4m ago · Open".
    var lastAnswer: String?
    var setupProblem: String?
}

struct HomeAskCardContent<Composer: View>: View {
    var data: HomeAskCardData
    /// At the foot of Home's queue panel: no title row and no card; the last answer, the triage line
    /// and the Orchestrator link share one quiet line under the composer.
    var inline = false
    var toggleTriage: () -> Void = {}
    var openOrchestrator: () -> Void = {}
    @ViewBuilder var composer: () -> Composer

    var body: some View {
        if inline { inlineBody } else { card }
    }

    private var inlineBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            proposals
            composer()
            if let activity = data.activity {
                activityLine(activity)
            } else if let error = data.error {
                Label(error, systemImage: "exclamationmark.bubble").font(.system(size: 12)).foregroundStyle(AppAppearance.amber).lineLimit(2)
            }
            if let problem = data.setupProblem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(AppAppearance.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if data.activity == nil, data.error == nil, let lastAnswer = data.lastAnswer {
                    Button(lastAnswer, action: openOrchestrator)
                        .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                        .help("Open the conversation")
                }
                footerLine
                Spacer(minLength: 0)
                HomePanelLink(help: "Open the Orchestrator", action: openOrchestrator)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var proposals: some View {
        if data.proposalsWaiting > 0 {
            Button(action: openOrchestrator) {
                Label(data.proposalsWaiting == 1 ? "1 proposed action waits for you" : "\(data.proposalsWaiting) proposed actions wait for you",
                      systemImage: "hand.raised")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.amber)
            }
            .buttonStyle(.plain).help("Review and send or discard them on the Orchestrator page")
        }
    }

    private func activityLine(_ activity: String) -> some View {
        Button(action: openOrchestrator) {
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                Text(activity).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
            }
        }.buttonStyle(.plain).help("Open the conversation")
    }

    /// "Triage: 9 today · On" (a toggle), then "Reading N chats…" or why it's paused.
    private var footerLine: some View {
        HStack(spacing: 8) {
            Button(action: toggleTriage) {
                Text(data.footer).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(AppAppearance.tertiary).lineLimit(1)
            }
            .buttonStyle(.plain).help(data.footerHelp)
            if data.triaging > 0 {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Reading \(data.triaging) chat\(data.triaging == 1 ? "" : "s")…")
                }.font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
            } else if let problem = data.problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionLabel(title: "Ask the Orchestrator") {
                Button(action: openOrchestrator) {
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(AppAppearance.tertiary)
                .help("Open the Orchestrator").accessibilityLabel("Open the Orchestrator")
            }
            if data.proposalsWaiting > 0 {
                Button(action: openOrchestrator) {
                    Label(data.proposalsWaiting == 1 ? "1 proposed action waits for you" : "\(data.proposalsWaiting) proposed actions wait for you",
                          systemImage: "hand.raised")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.amber)
                }
                .buttonStyle(.plain).help("Review and send or discard them on the Orchestrator page")
            }
            composer()
            if let activity = data.activity {
                Button(action: openOrchestrator) {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text(activity).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                    }
                }.buttonStyle(.plain).help("Open the conversation")
            } else if let error = data.error {
                Label(error, systemImage: "exclamationmark.bubble").font(.system(size: 12)).foregroundStyle(AppAppearance.amber).lineLimit(2)
            } else if let lastAnswer = data.lastAnswer {
                Button(lastAnswer, action: openOrchestrator)
                    .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary)
                    .help("Open the conversation")
            }
            if let problem = data.setupProblem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(AppAppearance.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(HomeCardSurface())
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: toggleTriage) {
                Text(data.footer).font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
            }
            .buttonStyle(.plain).help(data.footerHelp)
            if data.triaging > 0 {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Reading \(data.triaging) chat\(data.triaging == 1 ? "" : "s")…")
                }.font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
            } else if let problem = data.problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The card on the live stores.
struct HomeAskCard: View {
    @Bindable var store: AppStore
    var inline = false

    var body: some View {
        let brief = store.brief
        let orchestrator = store.orchestrator
        HomeAskCardContent(data: data(brief: brief, orchestrator: orchestrator), inline: inline,
                           toggleTriage: { brief.autoTriage.toggle() },
                           openOrchestrator: { store.showOrchestrator() }) {
            OrchestratorComposer(orchestrator: orchestrator, placeholder: "Ask the Orchestrator…")
        }
        .task { await orchestrator.loadHistory() }
    }

    private func data(brief: OrchestratorBriefStore, orchestrator: OrchestratorStore) -> HomeAskCardData {
        let shown = brief.shownInline(orchestrator.actions)
        let lastAnswer = (orchestrator.messages.last(where: { $0.kind == .assistant })?.at).map { at -> String in
            let ago = age(at)
            return "Last answer \(ago == "now" ? "just now" : ago + " ago") · Open"
        }
        return HomeAskCardData(
            footer: brief.footer,
            footerHelp: brief.autoTriage ? "Turn automatic triage off"
                : "Turn automatic triage on (\(OrchestratorTriage.modelTitle), at most \(brief.dailyCap) runs a day)",
            triaging: brief.triaging, problem: brief.autoTriage ? brief.problem : nil,
            proposalsWaiting: orchestrator.waitingActions.filter { !shown.contains($0.id) }.count,
            activity: orchestrator.activity, error: orchestrator.error, lastAnswer: lastAnswer,
            setupProblem: orchestrator.setupProblem)
    }

    private func age(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}
