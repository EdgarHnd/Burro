// Usage in the dashboard layout, kept pure so it can be tested: the header's toned sentence (the most
// urgent low limit first, amber, as the old alert line was; then `UsageClock.headline` and "Today on
// this Mac …") and the strip: one cell per shown provider's tightest window (% left; the sub-line
// is the "runs out ~…" guess when it won't last at this pace, worded in full in help, else the reset), a provider's second
// window when only one provider is shown, "API value today" (never "Spent"), and "Last 7 days" only
// to make up three cells. Never an empty cell: an unread or signed-out provider reads "—" with why.
import Foundation

public enum UsageComposition {
    /// "Claude Fable weekly: 6% left, resets Thu 09:00 · 3d" and, when it runs out first, "at this pace it runs out around today 16:00".
    public static func alertText(_ alert: UsageAlert, providers: [ProviderUsage], now: Date, calendar: Calendar) -> (lead: String, pace: String?) {
        let left = Int((alert.forecast.left ?? 0).rounded())
        let duration = providers.first { $0.id == alert.provider }?.windows.first { $0.id == alert.windowID }?.duration
        let reset = UsageClock.reset(alert.forecast.resetsAt, duration: duration, now: now, calendar: calendar)
        let lead = (alert.forecast.outcome == .usedUp ? "\(alert.title): used up" : "\(alert.title): \(left)% left")
            + ", " + reset.prefix(1).lowercased() + reset.dropFirst()
        if case .runsOut(let date) = alert.forecast.outcome {
            return (lead, "at this pace it runs out around \(UsageClock.moment(date, now: now, calendar: calendar))")
        }
        return (lead, nil)
    }

    /// The header sentence: the first low limit in amber (with how many more), then the summary.
    public static func sentence(alerts: [UsageAlert], providers: [ProviderUsage], summary: String, now: Date, calendar: Calendar) -> [TextRun] {
        guard let first = alerts.first else { return [TextRun(summary)] }
        let text = alertText(first, providers: providers, now: now, calendar: calendar)
        // The pace guess stays in the summary's own "at this pace" clause and the Low limits panel, so it isn't said twice.
        var runs = [TextRun(text.lead + ".", .needsYou)]
        if alerts.count > 1 { runs.append(TextRun(" +\(alerts.count - 1) more low limit\(alerts.count == 2 ? "" : "s")."))}
        runs.append(TextRun(" " + summary))
        return runs
    }

    /// Up to four cells; see the file comment. `cost` formats money (the Mac's currency format in the app).
    public static func stats(providers: [ProviderUsage], enabled: Bool, modelLimits: Bool, pace: Bool, week: UsageWeek?, scanning: Bool,
                             now: Date, calendar: Calendar, cost: (Double) -> String, tokens: (Double) -> String) -> [DashboardStat] {
        var cells: [DashboardStat] = []
        let shown = enabled ? Array(providers.prefix(3)) : []
        for provider in shown {
            let ranked = windows(provider, modelLimits: modelLimits)
            cells.append(limitCell(provider, ranked.first, now: now, calendar: calendar, pace: pace))
            if shown.count == 1, ranked.count > 1 {
                cells.append(limitCell(provider, ranked[1], now: now, calendar: calendar, pace: pace, second: true))
            }
        }
        if !enabled || shown.isEmpty {
            cells.append(DashboardStat(id: "limits", label: "Limits", value: "—",
                                       sub: [TextRun(enabled ? "every provider is paused" : "usage is paused")],
                                       help: enabled ? "Turn a provider on in Usage settings." : "Enable usage to see each account's limits."))
        }
        cells.append(apiValueCell(week, scanning: scanning, cost: cost, tokens: tokens))
        if cells.count < 3 { cells.append(weekCell(week, scanning: scanning, cost: cost, tokens: tokens)) }
        return cells
    }

    /// A provider's windows with a percentage, least left first (what the page shows: model windows only with `modelLimits`).
    static func windows(_ provider: ProviderUsage, modelLimits: Bool) -> [UsageWindow] {
        provider.windows.filter { (modelLimits || $0.model == nil) && $0.remainingPercent != nil }
            .sorted { ($0.remainingPercent ?? 100) < ($1.remainingPercent ?? 100) }
    }

    static func limitCell(_ provider: ProviderUsage, _ window: UsageWindow?, now: Date, calendar: Calendar, pace: Bool, second: Bool = false) -> DashboardStat {
        let id = "limit:" + provider.id.rawValue + (second ? ":2" : "")
        guard let window, let left = window.remainingPercent else {
            let why = provider.isLoading ? "connecting…" : provider.issue.map { $0.accountLabel.prefix(1).lowercased() + $0.accountLabel.dropFirst() }
                ?? "no limits reported"
            return DashboardStat(id: id, label: provider.title, value: "—", sub: [TextRun(why)],
                                 help: "\(provider.title)'s limits aren't available right now; its card below says why.")
        }
        let stale = provider.isStale(now: now)
        let forecast = UsageForecast(window: window, now: now, stale: stale)
        let title = UsageAlert.title(provider.id, window.title)
        let percent = "\(Int(min(100, max(0, left)).rounded()))%"
        var sub: [TextRun]
        if stale {
            sub = [TextRun(provider.updatedAt.map { "last seen \(UsageClock.span(now.timeIntervalSince($0))) ago" } ?? "not read yet", .stuck)]
        } else if forecast.outcome == .usedUp {
            sub = [TextRun("used up · " + resetWords(window, now: now, calendar: calendar), .needsYou)]
        } else if pace, case .runsOut(let date) = forecast.outcome {
            sub = [TextRun("runs out ~\(UsageClock.moment(date, now: now, calendar: calendar))",
                           UsageAlert.isLow(forecast, now: now) ? .needsYou : .plain)]
        } else {
            sub = [TextRun(resetWords(window, now: now, calendar: calendar))]
        }
        var help = "\(percent) of \(title) left. \(UsageClock.reset(window.resetsAt, duration: window.duration, now: now, calendar: calendar))."
        if pace, forecast.outcome != .stale { help += " " + UsageClock.forecast(forecast, now: now, calendar: calendar) + " (a straight-line guess)." }
        return DashboardStat(id: id, label: title, value: percent, sub: sub, help: help)
    }

    /// "resets in 2h 10m" for short windows, "resets Thu 09:00" for long ones.
    static func resetWords(_ window: UsageWindow, now: Date, calendar: Calendar) -> String {
        guard let resetsAt = window.resetsAt else { return "reset time unavailable" }
        guard resetsAt > now else { return "awaiting reset update" }
        if (window.duration ?? .infinity) <= 6 * 3600 { return "resets in \(UsageClock.span(resetsAt.timeIntervalSince(now)))" }
        return "resets \(UsageClock.moment(resetsAt, now: now, calendar: calendar))"
    }

    static func apiValueCell(_ week: UsageWeek?, scanning: Bool, cost: (Double) -> String, tokens: (Double) -> String) -> DashboardStat {
        let help = "Today's tokens on this Mac priced at reference API rates: a value, not a bill. Subscriptions count toward their windows instead."
        guard let week, let today = week.today else {
            return DashboardStat(id: "value", label: "API value today", value: "—",
                                 sub: [TextRun(scanning ? "reading this Mac's logs…" : "usage reader isn't running")], help: help)
        }
        return DashboardStat(id: "value", label: "API value today", value: week.pricedRecords > 0 && today.tokens > 0 ? cost(today.apiValue) : "—",
                             sub: [TextRun(today.tokens > 0 ? "\(tokens(today.tokens)) tokens on this Mac" : "no local tokens yet today")], help: help)
    }

    static func weekCell(_ week: UsageWeek?, scanning: Bool, cost: (Double) -> String, tokens: (Double) -> String) -> DashboardStat {
        guard let week else {
            return DashboardStat(id: "week", label: "Last 7 days", value: "—",
                                 sub: [TextRun(scanning ? "reading this Mac's logs…" : "usage reader isn't running")], help: "This Mac's tokens over seven days.")
        }
        return DashboardStat(id: "week", label: "Last 7 days", value: tokens(week.tokens),
                             sub: [TextRun(week.pricedRecords > 0 ? "tokens · about \(cost(week.apiValue))" : "tokens on this Mac")],
                             help: "This Mac's Codex and Claude tokens over the last seven days, today included.")
    }
}
