// "Local history (30 days)" at the foot of each provider's card on the Usage page: collapsed by
// default, and whether it is open is remembered per provider. Opening it with a click reads that
// provider's local logs for the selected profile (LocalUsageScanner, off the main actor, the same
// bounded scan as before); nothing reads them when the page appears, so a section restored open
// shows the last result from this launch or a Load button. Inside: Refresh, 30-day tokens, today's
// tokens and estimated API value, a daily bar chart with a Tokens / API value switch, and the models
// by tokens behind their own disclosure. Grok reports only cumulative session tokens, so it gets the
// totals without days or dollars. Token history is this Mac's, separate from quotas and charges, and
// the API value is a reference figure, never a bill.
import SwiftUI
import Charts
import BurroCore

/// Which providers' local history sections are open (UserDefaults
/// `usageLocalHistoryExpanded.<provider>`) and the scans read since launch, by provider and profile.
@MainActor @Observable final class UsageLocalHistoryState {
    static let shared = UsageLocalHistoryState(defaults: .standard)
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var expanded: Set<UsageProvider>
    private(set) var results: [String: LocalUsageCost] = [:]
    private(set) var scanning: Set<String> = []

    init(defaults: UserDefaults) {
        self.defaults = defaults
        expanded = Set(UsageProvider.allCases.filter { defaults.bool(forKey: Self.expandedKey($0)) })
    }

    nonisolated static func expandedKey(_ provider: UsageProvider) -> String { "usageLocalHistoryExpanded.\(provider.rawValue)" }
    nonisolated static func key(_ provider: UsageProvider, _ profile: String?) -> String { provider.rawValue + "|" + (profile ?? "") }

    func result(_ provider: UsageProvider, profile: String?) -> LocalUsageCost? { results[Self.key(provider, profile)] }
    func isScanning(_ provider: UsageProvider, profile: String?) -> Bool { scanning.contains(Self.key(provider, profile)) }

    /// The owner's click: opens (and reads, unless this launch already has a result) or closes.
    func toggle(_ provider: UsageProvider, profile: String?) {
        let open = !expanded.contains(provider)
        if open { expanded.insert(provider) } else { expanded.remove(provider) }
        defaults.set(open, forKey: Self.expandedKey(provider))
        if open && result(provider, profile: profile) == nil { scan(provider, profile: profile) }
    }

    /// Reads the provider's logs for the last 30 days off the main actor.
    func scan(_ provider: UsageProvider, profile: String?) {
        let key = Self.key(provider, profile)
        guard !scanning.contains(key) else { return }
        scanning.insert(key)
        Task {
            let value = await Task.detached(priority: .utility) { LocalUsageScanner.scan(provider: provider, profile: profile) }.value
            results[key] = value
            scanning.remove(key)
        }
    }

    /// For snapshot tests: a result as if a scan had returned it.
    func seed(_ value: LocalUsageCost, provider: UsageProvider, profile: String?) { results[Self.key(provider, profile)] = value }
}

/// The disclosure row and, when open, the history itself; sits inside UsageLimitCard.
struct UsageLocalHistorySection: View {
    var state: UsageLocalHistoryState
    var provider: UsageProvider
    var profile: String?
    var now: Date
    var calendar: Calendar

    private var open: Bool { state.expanded.contains(provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(AppAppearance.separator).frame(height: 1)
            Button { state.toggle(provider, profile: profile) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(AppAppearance.tertiary).frame(width: 12)
                        .accessibilityHidden(true)
                    Text("Local history (30 days)").font(.system(size: 13, weight: .medium)).foregroundStyle(AppAppearance.text)
                    Spacer(minLength: 8)
                    Text("Tokens from this Mac’s logs").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                }
                .padding(.vertical, 11).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Hide local history" : "Read the last 30 days of \(provider.title) token counts from this Mac’s logs")
            .accessibilityLabel("Local history, 30 days")
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                UsageLocalHistoryView(state: state, provider: provider, profile: profile, now: now, calendar: calendar)
                    .padding(.bottom, 16)
            }
        }
    }
}

/// The 30-day view: totals, the daily chart and the models.
struct UsageLocalHistoryView: View {
    var state: UsageLocalHistoryState
    var provider: UsageProvider
    var profile: String?
    var now: Date
    var calendar: Calendar
    @State private var showCost = false
    @State private var showModels = false

    private var result: LocalUsageCost? { state.result(provider, profile: profile) }
    private var scanning: Bool { state.isScanning(provider, profile: profile) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(result?.partial == true ? "Partial local history · last 30 days" : "This Mac · \(profile == nil ? "default account" : "selected profile") · last 30 days")
                    .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                Spacer(minLength: 8)
                Button(scanning ? "Reading logs…" : (result == nil ? "Load local history" : "Refresh history")) {
                    state.scan(provider, profile: profile)
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                .disabled(scanning)
                .help("Read token counters from this Mac’s \(provider.title) logs again")
            }
            if let result {
                if result.recordCount == 0 {
                    note("No supported usage records found. This does not mean your account has no usage.")
                } else {
                    content(result)
                }
            } else {
                note(scanning ? "Reading the last 30 days of logs on this Mac…"
                     : "Read token counters from local logs to see daily activity and estimated API value. No conversation text is saved or uploaded.")
            }
            if provider != .grok {
                Link("Pricing reference ↗", destination: URL(string: provider == .claude ? "https://platform.claude.com/docs/en/about-claude/pricing" : "https://developers.openai.com/api/docs/pricing")!)
                    .font(.system(size: 12))
            }
        }
        .padding(.leading, 20)
    }

    @ViewBuilder private func content(_ result: LocalUsageCost) -> some View {
        HStack(alignment: .top, spacing: 36) {
            metric(result.partial ? "Observed tokens" : "30-day tokens", UsagePageText.tokens(result.tokens))
            if provider != .grok {
                let today = result.days.first { calendar.isDate($0.date, inSameDayAs: now) }?.tokens ?? 0
                metric(result.partial ? "Observed today" : "Today’s tokens", UsagePageText.tokens(today))
            }
            metric(result.partial ? "Observed API value" : "Est. API value", result.pricedCount > 0 ? UsagePageText.cost(result.apiValue) : "Unavailable")
            Spacer(minLength: 0)
        }
        if provider != .grok {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Daily history").font(.system(size: 13, weight: .medium)).foregroundStyle(AppAppearance.text)
                    Spacer()
                    CapsulePicker(options: [(false, "Tokens"), (true, "API value")], selection: $showCost)
                }
                Chart(result.days) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value(showCost ? "USD" : "Tokens", showCost ? day.apiValue : day.tokens))
                        .foregroundStyle(calendar.isDate(day.date, inSameDayAs: now) ? AppAppearance.text.opacity(0.75) : AppAppearance.secondary.opacity(0.55))
                        .cornerRadius(3)
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine().foregroundStyle(AppAppearance.separator)
                        AxisValueLabel {
                            if let number = value.as(Double.self) { Text(showCost ? UsagePageText.cost(number) : UsagePageText.tokens(number)) }
                        }
                    }
                }
                .frame(height: 140)
                .accessibilityLabel(showCost ? "Daily estimated API value, last 30 days" : "Daily tokens, last 30 days")
            }
        }
        models(result)
        VStack(alignment: .leading, spacing: 6) {
            if result.partial {
                Label("Partial history: the scan reached a file, size, or time limit.", systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
            }
            note(provider == .grok
                 ? "Grok reports cumulative session tokens. This includes sessions updated in the last 30 days; it cannot be split accurately by day or converted into dollars."
                 : "Reference API value, not your bill. Standard short-context rates, checked Sep 29, 2026; excludes tool fees, tier/context premiums and unknown models. Priced \(result.pricedCount) of \(result.recordCount) records. Logs may include multiple accounts and exclude remote work.")
        }
    }

    @ViewBuilder private func models(_ result: LocalUsageCost) -> some View {
        let names = result.models.keys.sorted { result.models[$0, default: 0] > result.models[$1, default: 0] }
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button { showModels.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(showModels ? 90 : 0)).accessibilityHidden(true)
                        Text("Models · \(names.count)").font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(AppAppearance.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showModels ? "Expanded" : "Collapsed")
                if showModels {
                    VStack(spacing: 0) {
                        ForEach(names, id: \.self) { model in
                            HStack {
                                Text(model).foregroundStyle(AppAppearance.text).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 12)
                                Text(UsagePageText.tokens(result.models[model, default: 0]) + " tokens").monospacedDigit().foregroundStyle(AppAppearance.secondary)
                            }
                            .font(.system(size: 12.5)).padding(.vertical, 4)
                        }
                    }
                    .padding(.top, 6).padding(.leading, 15)
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(AppAppearance.text)
        }
        .accessibilityElement(children: .combine)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary).fixedSize(horizontal: false, vertical: true)
    }
}
