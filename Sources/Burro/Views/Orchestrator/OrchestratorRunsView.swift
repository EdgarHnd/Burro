// The Orchestrator page's Runs tab: how many model runs it made today and what they cost (as Claude
// Code reports it), then the latest runs with their trigger, model, time taken and tokens. Read from
// the runs log, which also holds automatic triage runs. Token counts read "500K", "1.2M" in every
// language (`TokenCount`).
import SwiftUI
import BurroCore

struct OrchestratorRunsView: View {
    @Bindable var store: AppStore
    var body: some View {
        let orchestrator = store.orchestrator
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 28) {
                    stat("\(orchestrator.runsToday.count)", "runs today")
                    stat(Self.cost(orchestrator.todayCost), "today")
                    stat(Self.tokens(orchestrator.runsToday.reduce(0) { $0 + $1.cacheReadTokens }), "cached tokens read today")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("RECENT RUNS").font(.system(size: 10.5, weight: .semibold)).tracking(0.7).foregroundStyle(AppAppearance.tertiary)
                    if orchestrator.recentRuns.isEmpty {
                        Text("No runs yet.").font(.system(size: 12.5)).foregroundStyle(AppAppearance.tertiary)
                    }
                    ForEach(Array(orchestrator.recentRuns.enumerated()), id: \.offset) { _, run in
                        HStack(spacing: 12) {
                            Text(run.at.formatted(date: Calendar.current.isDateInToday(run.at) ? .omitted : .abbreviated, time: .shortened))
                                .frame(width: 120, alignment: .leading)
                            Text(run.trigger).frame(width: 70, alignment: .leading)
                            Text(Orchestrator.modelTitle(run.model)).lineLimit(1).frame(width: 110, alignment: .leading)
                            Text(String(format: "%.1fs", Double(run.durationMs) / 1000)).frame(width: 50, alignment: .trailing)
                            Text("\(Self.tokens(run.inputTokens)) in · \(Self.tokens(run.outputTokens)) out · \(Self.tokens(run.cacheReadTokens)) cached")
                                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(Self.cost(run.costUSD)).frame(width: 60, alignment: .trailing)
                        }
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.secondary)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                Text("Costs are what Claude Code reports for each run, at API prices; on a subscription they count toward your usage windows instead.")
                    .font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 36).padding(.vertical, 18)
            .frame(maxWidth: 780).frame(maxWidth: .infinity)
        }
        .onAppear { orchestrator.reloadRuns() }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary)
        }
    }

    nonisolated static func cost(_ value: Double) -> String { String(format: "$%.2f", value) }
    nonisolated static func tokens(_ value: Int) -> String { TokenCount.compact(value) }
}
