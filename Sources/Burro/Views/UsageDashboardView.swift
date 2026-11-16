// The desktop Usage page's host: refreshes provider limits when it opens, and while it is on screen
// rescans this Mac's seven days of tokens, today's project activity and the Orchestrator's runs log
// every 90 seconds (nothing polls while it is hidden, covered or closed). The page itself is
// UsagePageContent; Usage settings (providers, refresh, display, history) is the sheet below.
import SwiftUI
import BurroCore

extension UsageProvider {
    var color: Color { switch self { case .codex: AppAppearance.green; case .claude: AppAppearance.claude; case .grok: AppAppearance.blue } }
}
struct UsageDashboardView: View {
    @Bindable var usage: UsageStore
    @State private var settings = false
    @State private var onScreen = true
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            UsagePageContent(usage: usage, extras: extras, now: context.date) { settings = true }
        }
        .background(AppAppearance.background)
        .background(WindowOcclusionReader { onScreen = $0 })
        .modifier(AppTheme())
        .sheet(isPresented: $settings) { UsageSettingsView(usage: usage) }
        .task { await usage.refresh() }
        // Local token figures and the Orchestrator's runs refresh while the page is on screen.
        .task(id: onScreen) {
            while onScreen && !Task.isCancelled {
                usage.refreshWeek()
                usage.app?.refreshProjectActivity()
                usage.app?.orchestrator.reloadRuns()
                try? await Task.sleep(for: .seconds(90))
            }
        }
    }
    /// Today's projects and the Orchestrator's budget, from the app's stores (nil in a bare UsageStore).
    private var extras: UsagePageExtras {
        guard let app = usage.app else { return UsagePageExtras() }
        var extras = UsagePageExtras()
        if let activity = app.projectActivity {
            let named = app.homeSummary.projects.filter { $0.tokensToday > 0 }.map { (name: $0.name, tokens: $0.tokensToday, apiValue: $0.apiValueToday) }
            extras.projects = UsageBreakdown.projects(named, total: activity.tokens, totalValue: activity.apiValue)
            extras.projectsPartial = activity.partial
        }
        let runs = app.orchestrator.runsToday
        extras.budget = UsageBudget(triageRuns: app.brief.runsToday, cap: app.brief.dailyCap, autoTriage: app.brief.autoTriage,
                                    paused: app.brief.gate.reason, runsToday: runs.count, costToday: app.orchestrator.todayCost,
                                    triageModel: OrchestratorTriage.modelTitle, askModel: Orchestrator.modelTitle(app.orchestrator.model))
        return extras
    }
}

struct UsageSettingsView: View {
    @Bindable var usage: UsageStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Usage settings").font(AppAppearance.pageTitle); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(20)
            Form {
                Section("Providers") {
                    ForEach(UsageProvider.allCases) { provider in
                        Toggle(provider.title, isOn: Binding(get: { usage.preferences.providers.contains(provider) }, set: { enabled in
                            if enabled { usage.preferences.providers.insert(provider) } else { usage.preferences.providers.remove(provider) }
                        }))
                    }
                }
                Section("Display") {
                    Picker("Refresh", selection: $usage.preferences.interval) { Text("Every minute").tag(60); Text("Every 5 minutes").tag(300); Text("Every 15 minutes").tag(900) }
                    Toggle("Show remaining instead of used", isOn: $usage.preferences.remaining)
                    Toggle("Show linear pace estimates", isOn: $usage.preferences.pace)
                    Toggle("Show separate model limits", isOn: $usage.preferences.modelLimits)
                    Text("The notch always shows remaining limits, including separate model quotas.").font(.caption).foregroundStyle(.secondary)
                }
                Section("History") {
                    Toggle("Keep 30 days of quota readings on this Mac", isOn: $usage.preferences.history)
                    Button("Clear quota history", role: .destructive) { usage.clearHistory() }
                    Text("Only quota readings and a hashed account identifier are saved. Turning history off deletes saved readings.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
        }.frame(width: 470, height: 560).modifier(AppTheme())
    }
}
