// Local token history is explicitly separate from subscription quotas and paid charges.
import SwiftUI
import Charts
import BurroCore

struct UsageCostView: View {
    var provider: UsageProvider
    var profile: String?
    @State private var result: LocalUsageCost?
    @State private var scanning = false
    @State private var showCost = false
    @State private var expandedModels = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Local usage & cost").font(.headline)
                    Text(result?.partial == true ? "Partial local history · last 30 days" : "This Mac · selected profile · last 30 days").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(scanning ? "Reading logs…" : (result == nil ? "Load local history" : "Refresh history")) { scan() }.disabled(scanning)
            }
            if let result {
                if result.recordCount == 0 {
                    Text("No supported usage records found. This does not mean your account has no usage.").font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 40) {
                        metric(result.partial ? "Observed tokens" : "30-day tokens", value: result.tokens.formatted(.number.notation(.compactName)))
                        if provider != .grok {
                            metric("Today’s tokens", value: (result.days.first { Calendar.current.isDateInToday($0.date) }?.tokens ?? 0).formatted(.number.notation(.compactName)))
                        }
                        metric(result.partial ? "Observed API value" : "Est. API value", value: result.pricedCount > 0 ? result.apiValue.formatted(.currency(code: "USD")) : "Unavailable")
                        Spacer()
                    }
                    if provider != .grok {
                        HStack {
                            Text("Daily history").font(.callout.weight(.medium)); Spacer()
                            Picker("Metric", selection: $showCost) { Text("Tokens").tag(false); Text("API value").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
                        }
                        Chart(result.days) { day in
                            BarMark(x: .value("Day", day.date, unit: .day), y: .value(showCost ? "USD" : "Tokens", showCost ? day.apiValue : day.tokens))
                                .foregroundStyle(provider.color.gradient).cornerRadius(3)
                        }.frame(height: 150)
                    }
                    DisclosureGroup("Models", isExpanded: $expandedModels) {
                        ForEach(result.models.keys.sorted { result.models[$0, default: 0] > result.models[$1, default: 0] }, id: \.self) { model in
                            HStack { Text(model); Spacer(); Text(result.models[model, default: 0].formatted(.number.notation(.compactName)) + " tokens").monospacedDigit() }.font(.caption).padding(.vertical, 3)
                        }
                    }
                    if result.partial { Label("Partial history: the scan reached a file, size, or time limit.", systemImage: "info.circle").font(.caption).foregroundStyle(.orange) }
                    Text(provider == .grok ? "Grok reports cumulative session tokens. This includes sessions updated in the last 30 days; it cannot be split accurately by day or converted into dollars." : "Reference API value, not your bill. Standard short-context rates, checked Sep 29, 2026; excludes tool fees, tier/context premiums and unknown models. Priced \(result.pricedCount) of \(result.recordCount) records. Logs may include multiple accounts and exclude remote work.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Read token counters from local logs to see daily activity and estimated API value. No conversation text is saved or uploaded.").font(.callout).foregroundStyle(.secondary)
            }
            if provider != .grok {
                Link("Pricing reference ↗", destination: URL(string: provider == .claude ? "https://platform.claude.com/docs/en/about-claude/pricing" : "https://developers.openai.com/api/docs/pricing")!).font(.caption)
            }
        }.padding(22).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .onChange(of: provider) { _, _ in result = nil }
        .onChange(of: profile) { _, _ in result = nil }
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title2.weight(.semibold)).monospacedDigit() }
    }
    private func scan() {
        scanning = true
        let selected = provider, path = profile
        Task {
            let value = await Task.detached(priority: .utility) { LocalUsageScanner.scan(provider: selected, profile: path) }.value
            if provider == selected && profile == path { result = value }
            scanning = false
        }
    }
}
