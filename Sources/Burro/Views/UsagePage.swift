// The Usage page in the dashboard layout (Today's). The shared page header: one sentence whose
// first run, in amber, is the most urgent low limit when there is one (UsageAlert's rule: used up,
// running out within three hours at this pace, or 10% or less and not lasting to its reset), then
// what runs out at this pace and today's local tokens; Settings and Refresh trailing with when the
// limits were read. A strip: each shown provider's tightest window, its second window when only one
// provider is shown, and today's API value (UsageComposition). Then one joined surface: the main row
// 2:1 (stacked below Today's 880 points) with every provider's limits as rows (UsageLimitCard,
// unframed: account menu, staleness, problem actions, meters with the even-pace tick, reset and
// forecast, extras, links, quota history and "Local history (30 days)") beside Low limits when any,
// else Last 7 days; the bottom row 1:1:1 (stacked below 690) with today by project, today by model
// and the Orchestrator budget; while a limit is low, Last 7 days sits under Low limits in that column.
// Every forecast is worded "at this pace". `UsagePage` takes plain values besides the UsageStore and
// no scroll view, so tests can render it with invented data. Token counts read "500K", "1.2M" in
// every language (`TokenCount`); money keeps the Mac's format.
import SwiftUI
import BurroCore

/// Figures the page shows from the app's other stores.
struct UsagePageExtras {
    /// Today's tokens by project on this Mac; nil before the first scan or without the usage reader.
    var projects: [UsageBreakdownRow]? = nil
    var projectsPartial = false
    var budget: UsageBudget? = nil
}

/// The scrolling shell around `UsagePage`.
struct UsagePageContent: View {
    @Bindable var usage: UsageStore
    var extras: UsagePageExtras
    var now: Date
    var calendar: Calendar = .current
    var localHistory: UsageLocalHistoryState = .shared
    var openSettings: () -> Void

    var body: some View {
        ScrollView {
            UsagePage(usage: usage, extras: extras, now: now, calendar: calendar, localHistory: localHistory, openSettings: openSettings)
                .padding(.horizontal, 36).padding(.vertical, 28)
                .frame(maxWidth: 1240).frame(maxWidth: .infinity)
        }
    }
}

struct UsagePage: View {
    @Bindable var usage: UsageStore
    var extras: UsagePageExtras
    var now: Date
    var calendar: Calendar = .current
    var localHistory: UsageLocalHistoryState = .shared
    var openSettings: () -> Void
    @State private var limitsWidth: CGFloat = 700

    nonisolated static var mainStackBelow: CGFloat { 880 }
    nonisolated static var bottomStackBelow: CGFloat { 690 }
    /// Below this inner width a limit's meter puts its reset and forecast under the bar.
    nonisolated static var meterCompactBelow: CGFloat { 620 }

    private var providers: [ProviderUsage] { usage.snapshot.providers }
    private var alerts: [UsageAlert] {
        usage.enabled ? UsageAlert.alerts(providers, now: now, modelLimits: usage.preferences.modelLimits) : []
    }

    var body: some View {
        let alerts = self.alerts
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Usage", inset: 0, eyebrow: "Limits and tokens",
                       sentence: UsageComposition.sentence(alerts: alerts, providers: providers, summary: summary, now: now, calendar: calendar),
                       top: 0, bottom: 0) { headerControls }
            if let message = usage.message { messageLine(message) }
            StatStrip(cells: cells)
            JoinedPanels {
                JoinedRow(weights: [2, 1], stackBelow: Self.mainStackBelow) {
                    limitsPanel(alerts)
                    if alerts.isEmpty {
                        UsageWeekCard(week: usage.week, scanning: usage.scanningWeek, calendar: calendar)
                    } else {
                        // Low limits is short and Limits is tall, so the week sits under it, not in a row of its own.
                        JoinedRow(weights: [], stackBelow: .infinity) {
                            UsageLowLimitsPanel(alerts: alerts, providers: providers, now: now, calendar: calendar)
                            UsageWeekCard(week: usage.week, scanning: usage.scanningWeek, calendar: calendar)
                        }
                    }
                }
                JoinedRow(weights: [1, 1, 1], stackBelow: Self.bottomStackBelow) {
                    UsageProjectsCard(rows: extras.projects, partial: extras.projectsPartial)
                    UsageModelsCard(week: usage.week, scanning: usage.scanningWeek, alerts: alerts)
                    UsageBudgetCard(budget: extras.budget)
                }
            }
            Text("Quotas follow each account, across all its machines; token estimates are this Mac’s.")
                .font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary)
                .help("Burro connects directly to each provider. Quotas follow the account shown with each provider; local session activity and token estimates belong to this Mac.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header and strip

    private var headerControls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
                PillButton(title: "Settings", symbol: "slider.horizontal.3", action: openSettings).help("Usage settings")
                PillButton(title: usage.checking ? "Refreshing…" : "Refresh", symbol: "arrow.clockwise") {
                    Task { await usage.refresh(force: true) }
                }.disabled(usage.checking || !usage.enabled).help("Read every provider’s limits again")
            }
            if let updated = UsagePageText.updated(providers.compactMap(\.updatedAt).max(), now: now) {
                Text(updated).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
            }
        }
    }

    /// "At this pace … runs out …. Today on this Mac: 7.6M tokens, about $70."
    private var summary: String {
        let forecasts = usage.enabled ? providers.flatMap { provider in
            let stale = provider.isStale(now: now)
            return provider.windows.filter { usage.preferences.modelLimits || $0.model == nil }.map {
                (title: UsageAlert.title(provider.id, $0.title), forecast: UsageForecast(window: $0, now: now, stale: stale))
            }
        } : []
        var parts: [String] = []
        if usage.preferences.pace, let headline = UsageClock.headline(forecasts, now: now, calendar: calendar) { parts.append(headline) }
        if let today = usage.week?.today, today.tokens > 0 {
            let cost = (usage.week?.pricedRecords ?? 0) > 0 ? ", about \(UsagePageText.cost(today.apiValue))" : ""
            parts.append("Today on this Mac: \(UsagePageText.tokens(today.tokens)) tokens\(cost).")
        }
        return parts.isEmpty ? "Every limit in one place." : parts.joined(separator: " ")
    }

    private var cells: [StatCellData] {
        UsageComposition.stats(providers: usage.snapshot.availability == .loading ? [] : providers, enabled: usage.enabled,
                               modelLimits: usage.preferences.modelLimits, pace: usage.preferences.pace, week: usage.week,
                               scanning: usage.scanningWeek, now: now, calendar: calendar,
                               cost: UsagePageText.cost, tokens: UsagePageText.tokens).map { stat in
            StatCellData(id: stat.id, label: stat.label, value: stat.value, muted: stat.unknown, sub: stat.sub, help: stat.help)
        }
    }

    // MARK: Limits

    private func limitsPanel(_ alerts: [UsageAlert]) -> some View {
        Panel(title: "Limits", subtitle: [TextRun(limitsSubtitle)]) {
            VStack(alignment: .leading, spacing: 0) {
                if !usage.enabled {
                    AppEmptyState(title: "Usage is paused", symbol: "pause.circle",
                                  detail: "Connect your coding accounts to see their limits and reset times.") {
                        Button("Enable usage") { usage.enabled = true }
                    }.frame(minHeight: 200)
                } else if usage.snapshot.availability == .loading {
                    loading
                } else if providers.isEmpty {
                    AppEmptyState("Every provider is paused", symbol: "pause.circle", detail: "Turn one on in Usage settings.").frame(minHeight: 200)
                } else {
                    ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                        if index > 0 { Rectangle().fill(AppAppearance.separator).frame(height: 1).padding(.vertical, 6) }
                        UsageLimitCard(usage: usage, provider: provider, alerts: alerts, now: now, calendar: calendar,
                                       compact: limitsWidth < Self.meterCompactBelow, localHistory: localHistory, framed: false)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { limitsWidth = $0 }
        }
    }

    private var limitsSubtitle: String {
        if !usage.enabled { return "Paused" }
        let count = providers.count
        return count == 0 ? "No provider is on" : "What’s left in each window, for \(count) account\(count == 1 ? "" : "s")"
    }

    private func messageLine(_ message: String) -> some View {
        HStack {
            Label(message, systemImage: "info.circle")
            Spacer()
            Button { usage.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                .accessibilityLabel("Dismiss message").help("Dismiss")
        }
        .font(.system(size: 13)).foregroundStyle(AppAppearance.secondary).padding(12)
        .background(AppAppearance.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 4).fill(AppAppearance.raised).frame(width: 160, height: 16)
                    RoundedRectangle(cornerRadius: 6).fill(AppAppearance.raised).frame(height: 12)
                    RoundedRectangle(cornerRadius: 6).fill(AppAppearance.raised).frame(height: 12)
                }
            }.accessibilityHidden(true)
            Text("Loading usage limits…").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
        }
    }
}

/// The right-hand panel while some limit is low: each low window, most urgent first, with what is
/// left (amber), the reset and the "at this pace" guess.
struct UsageLowLimitsPanel: View {
    var alerts: [UsageAlert]
    var providers: [ProviderUsage]
    var now: Date
    var calendar: Calendar
    var body: some View {
        Panel(title: "Low limits", subtitle: [TextRun("\(alerts.count) limit\(alerts.count == 1 ? "" : "s") running low", .needsYou)]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(alerts.enumerated()), id: \.element.id) { index, alert in
                    if index > 0 { Rectangle().fill(AppAppearance.separator).frame(height: 1) }
                    let text = UsageComposition.alertText(alert, providers: providers, now: now, calendar: calendar)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(AppAppearance.amber).frame(width: 7, height: 7).accessibilityHidden(true)
                            Text(alert.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppAppearance.text).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(alert.forecast.outcome == .usedUp ? "Used up" : "\(Int((alert.forecast.left ?? 0).rounded()))% left")
                                .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(AppAppearance.amber).fixedSize()
                        }
                        Text(text.lead.components(separatedBy: ", ").dropFirst().joined(separator: ", ").capitalizedFirst)
                            .font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).padding(.leading, 15)
                        if let pace = text.pace {
                            Text(pace.capitalizedFirst).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                                .fixedSize(horizontal: false, vertical: true).padding(.leading, 15)
                        }
                    }
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Number and time words shared by the Usage page's cards.
enum UsagePageText {
    /// "7.6M", "320K", "940", the same in every language (`TokenCount`).
    static func tokens(_ value: Double) -> String { TokenCount.compact(value) }
    /// "$540", "$38", "$1.84"; whole dollars from $10.
    static func cost(_ value: Double) -> String {
        value >= 10 ? value.formatted(.currency(code: "USD").precision(.fractionLength(0)))
            : value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
    /// "Updated just now", "Updated 4 min ago"; nil before any reading.
    static func updated(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return "Updated just now" }
        if minutes < 60 { return "Updated \(minutes) min ago" }
        return "Updated \(minutes / 60) h ago"
    }
}
