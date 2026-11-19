// The Usage page's Orchestrator budget card: today's automatic triage runs against the daily cap
// (with the reason when triage is paused or off), what all of the Orchestrator's runs cost today as
// Claude Code reports them (from its runs log), and the models triage and questions run on.
// "Settings" opens Burro's settings, where the Brief's cap and automatic triage live.
import SwiftUI
import BurroCore

struct UsageBudget: Equatable {
    var triageRuns: Int
    var cap: Int
    var autoTriage: Bool
    /// Why triage can't run now ("Paused: Claude session 12% left"), nil when it can.
    var paused: String?
    /// Every Orchestrator run today: triage and your questions.
    var runsToday: Int
    var costToday: Double
    var triageModel: String
    var askModel: String
}

struct UsageBudgetCard: View {
    var budget: UsageBudget?
    var body: some View {
        Panel(title: "Orchestrator budget", subtitle: [TextRun("Triage runs against the daily cap")]) {
            SettingsLink { Text("Settings") }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                .help("Open Burro settings: the Brief’s daily cap and automatic triage")
        } content: {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let budget {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(budget.triageRuns)").font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(AppAppearance.text)
                    Text("of \(budget.cap) triage runs today").font(.system(size: 13)).foregroundStyle(AppAppearance.secondary)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppAppearance.raised)
                        Capsule().fill(budget.triageRuns >= budget.cap ? AppAppearance.amber : AppAppearance.secondary)
                            .frame(width: budget.triageRuns > 0 ? max(4, geometry.size.width * min(1, Double(budget.triageRuns) / Double(max(1, budget.cap)))) : 0)
                    }
                }
                .frame(height: 8)
                .accessibilityElement().accessibilityLabel("Triage runs").accessibilityValue("\(budget.triageRuns) of \(budget.cap)")
                if !budget.autoTriage || budget.paused != nil {
                    Text(budget.autoTriage ? budget.paused ?? "" : "Automatic triage is off").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                }
                Rectangle().fill(AppAppearance.separator).frame(height: 1).padding(.vertical, 2)
                row("Cost today") {
                    Text(UsagePageText.cost(budget.costToday)).fontWeight(.semibold).foregroundStyle(AppAppearance.text)
                        .help("What Claude Code reports for each run, at API prices; on a subscription they count toward your usage windows instead.")
                }
                row("Runs today") { Text("\(budget.runsToday)").foregroundStyle(AppAppearance.text) }
                row("Triage runs on") { tag("Claude · \(budget.triageModel)") }
                row("Questions run on") { tag("Claude · \(budget.askModel)") }
                Text("Costs are what Claude Code reports, at API prices; on a subscription they count toward your usage windows instead.")
                    .font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The Orchestrator’s runs appear here.").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<V: View>(_ title: String, @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(AppAppearance.secondary)
            Spacer()
            value()
        }.font(.system(size: 13)).monospacedDigit()
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).lineLimit(1).truncationMode(.middle)
    }
}
