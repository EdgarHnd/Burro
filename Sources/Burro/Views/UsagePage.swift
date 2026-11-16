// The Usage page, top to bottom: an amber line only when some limit is low (UsageAlert's rule:
// used up, running out within three hours at this pace, or 10% or less and not lasting to its
// reset); the title with one sentence on what runs out at this pace and today's local tokens; a
// card per provider with its limits as wide meters (UsageLimitCard), each ending in a collapsed
// "Local history (30 days)" that reads this Mac's logs only when opened; today by project and today by
// model; the last seven days; and the Orchestrator's triage budget. Every forecast is worded "at
// this pace". Below about 900 points the paired cards stack. Takes plain values besides the
// UsageStore, so tests can render it with invented data. Token counts read "500K", "1.2M" in every
// language (`TokenCount`); money keeps the Mac's format.
import SwiftUI
import BurroCore

/// Figures the page shows from the app's other stores.
struct UsagePageExtras {
    /// Today's tokens by project on this Mac; nil before the first scan or without the usage reader.
    var projects: [UsageBreakdownRow]? = nil
    var projectsPartial = false
    var budget: UsageBudget? = nil
}

struct UsagePageContent: View {
    @Bindable var usage: UsageStore
    var extras: UsagePageExtras
    var now: Date
    var calendar: Calendar = .current
    var localHistory: UsageLocalHistoryState = .shared
    var openSettings: () -> Void
    @State private var width: CGFloat = 1200

    private var wide: Bool { width >= 900 }
    private var providers: [ProviderUsage] { usage.snapshot.providers }
    private var alerts: [UsageAlert] {
        usage.enabled ? UsageAlert.alerts(providers, now: now, modelLimits: usage.preferences.modelLimits) : []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let alert = alerts.first { alertLine(alert, more: alerts.count - 1) }
                header
                if let message = usage.message { messageLine(message) }
                if !usage.enabled {
                    AppEmptyState(title: "Usage is paused", symbol: "pause.circle",
                                  detail: "Connect your coding accounts to see their limits and reset times.") {
                        Button("Enable usage") { usage.enabled = true }
                    }.modifier(AppCardSurface())
                } else if usage.snapshot.availability == .loading {
                    loading
                } else {
                    ForEach(providers) { provider in
                        UsageLimitCard(usage: usage, provider: provider, alerts: alerts, now: now, calendar: calendar, compact: !wide,
                                       localHistory: localHistory)
                    }
                    if providers.isEmpty {
                        AppEmptyState("Every provider is paused", symbol: "pause.circle", detail: "Turn one on in Usage settings.")
                            .modifier(AppCardSurface())
                    }
                }
                pair {
                    UsageProjectsCard(rows: extras.projects, partial: extras.projectsPartial)
                } second: {
                    UsageModelsCard(week: usage.week, scanning: usage.scanningWeek, alerts: alerts)
                }
                pair(firstWeight: 2.4) {
                    UsageWeekCard(week: usage.week, scanning: usage.scanningWeek, calendar: calendar)
                } second: {
                    UsageBudgetCard(budget: extras.budget)
                }
                Text("Quotas follow each account, across all its machines; token estimates are this Mac’s.")
                    .font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary)
                    .help("Burro connects directly to each provider. Quotas follow the account shown on each card; local session activity and token estimates belong to this Mac.")
            }
            .padding(.horizontal, wide ? 28 : 18).padding(.top, 26).padding(.bottom, 40)
            .frame(maxWidth: 1240).frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Usage").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(AppAppearance.text)
                Text(summary).font(.system(size: 14)).foregroundStyle(AppAppearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
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
        return parts.isEmpty ? "Every limit in one place" : parts.joined(separator: " ")
    }

    // MARK: Alert

    private func alertLine(_ alert: UsageAlert, more: Int) -> some View {
        let left = Int((alert.forecast.left ?? 0).rounded())
        let reset = UsageClock.reset(alert.forecast.resetsAt, duration: providers.first { $0.id == alert.provider }?
            .windows.first { $0.id == alert.windowID }?.duration, now: now, calendar: calendar)
        let lead = alert.forecast.outcome == .usedUp ? "\(alert.title): used up" : "\(alert.title): \(left)% left"
        var pace: String?
        if case .runsOut(let date) = alert.forecast.outcome {
            pace = "at this pace it runs out around \(UsageClock.moment(date, now: now, calendar: calendar))"
        }
        return HStack(spacing: 10) {
            Circle().fill(AppAppearance.amber).frame(width: 8, height: 8).accessibilityHidden(true)
            (Text(lead + ", " + reset.prefix(1).lowercased() + reset.dropFirst()).fontWeight(.semibold).foregroundColor(AppAppearance.text)
             + Text(pace.map { " · " + $0 } ?? "").foregroundColor(AppAppearance.secondary))
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if more > 0 {
                Text("+\(more) more low limit\(more == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(AppAppearance.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AppAppearance.amber.opacity(0.35)))
        .accessibilityElement(children: .combine)
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
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 16) {
                    RoundedRectangle(cornerRadius: 4).fill(AppAppearance.raised).frame(width: 160, height: 18)
                    RoundedRectangle(cornerRadius: 6).fill(AppAppearance.raised).frame(height: 12)
                    RoundedRectangle(cornerRadius: 6).fill(AppAppearance.raised).frame(height: 12)
                }.padding(20).modifier(AppCardSurface())
            }.accessibilityHidden(true)
            Text("Loading usage limits…").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
        }
    }

    /// Two cards side by side when wide, stacked when narrow.
    @ViewBuilder private func pair<A: View, B: View>(firstWeight: CGFloat = 1, @ViewBuilder _ first: () -> A,
                                                     @ViewBuilder second: () -> B) -> some View {
        if wide {
            HStack(alignment: .top, spacing: 16) {
                first().frame(width: (min(width, 1240) - 56 - 16) * firstWeight / (firstWeight + 1))
                second().frame(maxWidth: .infinity)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) { first(); second() }
        }
    }
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
