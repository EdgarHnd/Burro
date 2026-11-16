// "Will I run out?" for one usage limit window, as an explicitly linear guess: the share of the
// window already used, divided by the share of its time already gone, extended to the reset.
// It is never certain, so the page words it "at this pace". The even-pace tick is where the
// window would stand if it were used evenly across its whole length.
//
// No guess is made when the provider's reading is stale, when the percentage, the reset time or
// the window's length is unknown (so its start is unknown), or when the reset time has passed and
// the provider hasn't reported the refill. In the first 30 minutes or 5% of a window (whichever is
// longer) a rate would mislead, so it says "too early" instead. 0% left is "used up".
//
// The alert rule (UsageAlert) picks the windows the page leads with: used up; or at this pace
// running out within three hours; or 10% or less left unless it lasts until reset at this pace.
// Stale readings and windows awaiting their refill never alert. UsageClock words times and spans.
import Foundation

public struct UsageForecast: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// At this pace the window lasts until it resets.
        case fineUntilReset
        /// At this pace it reaches 0% at this time, before the reset.
        case runsOut(Date)
        /// Nothing left; it comes back at the reset.
        case usedUp
        /// The window began too recently for a rate to mean anything.
        case tooEarly
        /// The percentage, reset time or window length (so its start) is unknown.
        case unknown
        /// The provider's reading is old.
        case stale
        /// The reset time has passed and the provider hasn't reported the refill yet.
        case awaitingReset
    }

    /// Percent left, 0–100, when known.
    public var left: Double?
    /// Percent that would be left now if the window were used evenly; nil when its start is unknown.
    public var evenPaceLeft: Double?
    public var resetsAt: Date?
    public var outcome: Outcome

    /// A window younger than this (or than `minimumElapsedShare` of its length) is "too early".
    public static let minimumElapsed: TimeInterval = 30 * 60
    public static let minimumElapsedShare = 0.05

    public init(window: UsageWindow, now: Date, stale: Bool = false) {
        self.init(left: window.remainingPercent, resetsAt: window.resetsAt, duration: window.duration, now: now, stale: stale)
    }

    public init(left rawLeft: Double?, resetsAt: Date?, duration: TimeInterval?, now: Date, stale: Bool = false) {
        let left = rawLeft.map { min(100, max(0, $0)) }
        self.left = left
        self.resetsAt = resetsAt
        evenPaceLeft = nil
        outcome = .unknown
        guard let left else { outcome = stale ? .stale : .unknown; return }
        if stale { outcome = .stale; return }
        if let resetsAt, resetsAt <= now { outcome = .awaitingReset; return }
        if left <= 0 { outcome = .usedUp }
        guard let resetsAt, let duration, duration > 0 else { return }
        let untilReset = resetsAt.timeIntervalSince(now)
        // A reset further away than the window is long means the numbers don't fit together.
        guard untilReset <= duration + 60 else { return }
        let elapsed = max(0, duration - untilReset)
        evenPaceLeft = min(100, max(0, 100 * untilReset / duration))
        if left <= 0 { return }
        if elapsed < max(Self.minimumElapsed, Self.minimumElapsedShare * duration) { outcome = .tooEarly; return }
        let used = 100 - left
        guard used > 0 else { outcome = .fineUntilReset; return }
        let secondsToEmpty = left / (used / elapsed)
        outcome = secondsToEmpty >= untilReset ? .fineUntilReset : .runsOut(now.addingTimeInterval(secondsToEmpty))
    }

    /// True when the guess says the window will not last (or already hasn't).
    public var isShort: Bool {
        switch outcome {
        case .runsOut, .usedUp: true
        default: false
        }
    }
}

/// A limit low enough to lead the page with.
public struct UsageAlert: Sendable, Equatable, Identifiable {
    public var provider: UsageProvider
    public var windowID: String
    /// "Claude Fable weekly", "Codex Weekly" (the provider then the window's own title).
    public var title: String
    public var model: String?
    public var forecast: UsageForecast
    public var id: String { provider.rawValue + ":" + windowID }

    public static let lowLeft = 10.0
    public static let soon: TimeInterval = 3 * 3600

    /// "Claude Fable weekly", "Codex weekly", "Claude session": a common first word is lowercased.
    public static func title(_ provider: UsageProvider, _ window: String) -> String {
        let common: Set<String> = ["session", "weekly", "daily", "monthly", "primary", "additional", "subscription"]
        let first = window.split(separator: " ").first.map { String($0).lowercased() } ?? ""
        return provider.title + " " + (common.contains(first) ? window.prefix(1).lowercased() + window.dropFirst() : window)
    }

    public static func isLow(_ forecast: UsageForecast, now: Date) -> Bool {
        guard let left = forecast.left else { return false }
        switch forecast.outcome {
        case .usedUp: return true
        case .runsOut(let date): return date.timeIntervalSince(now) <= soon || left <= lowLeft
        case .tooEarly, .unknown: return left <= lowLeft
        case .fineUntilReset, .stale, .awaitingReset: return false
        }
    }

    /// The low windows across providers, most urgent first: used up, then the earliest run-out,
    /// then the least left. `modelLimits` false leaves out per-model windows like the page does.
    public static func alerts(_ providers: [ProviderUsage], now: Date, modelLimits: Bool = true) -> [UsageAlert] {
        var result: [UsageAlert] = []
        for provider in providers where !provider.isLoading {
            let stale = provider.isStale(now: now)
            for window in provider.windows where modelLimits || window.model == nil {
                let forecast = UsageForecast(window: window, now: now, stale: stale)
                guard isLow(forecast, now: now) else { continue }
                result.append(UsageAlert(provider: provider.id, windowID: window.id, title: title(provider.id, window.title),
                                         model: window.model, forecast: forecast))
            }
        }
        func rank(_ alert: UsageAlert) -> (Int, Date, Double) {
            switch alert.forecast.outcome {
            case .usedUp: (0, .distantPast, 0)
            case .runsOut(let date): (1, date, alert.forecast.left ?? 0)
            default: (2, .distantFuture, alert.forecast.left ?? 0)
            }
        }
        return result.sorted { a, b in
            let (x, y) = (rank(a), rank(b))
            if x.0 != y.0 { return x.0 < y.0 }
            if x.1 != y.1 { return x.1 < y.1 }
            return x.2 < y.2
        }
    }
}

/// Words for times and spans on the Usage page. Every function takes the calendar it formats in.
public enum UsageClock {
    /// "today 10:40", "tomorrow 09:00", "Thu 14:00" within the week, else "Nov 24 14:00".
    public static func moment(_ date: Date, now: Date, calendar: Calendar) -> String {
        let locale = calendar.locale ?? Locale(identifier: "en_US_POSIX")
        let time = formatter("jmm", locale: locale, calendar: calendar).string(from: date)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "today \(time)"
        case 1: return "tomorrow \(time)"
        case 2...6: return formatter("EEE", locale: locale, calendar: calendar).string(from: date) + " " + time
        default: return formatter("MMMd", locale: locale, calendar: calendar).string(from: date) + " " + time
        }
    }

    /// "45m", "2h 10m", "1d 4h", "5d".
    public static func span(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(ceil(min(seconds, 366 * 86400) / 60)))
        if minutes >= 2 * 1440 { return "\(minutes / 1440)d" }
        if minutes >= 1440 { return "1d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" }
        return "\(minutes)m"
    }

    /// When the window refills: "Resets in 2h 10m" for short windows, "Resets Tue 09:00 · 2d" for long ones.
    public static func reset(_ resetsAt: Date?, duration: TimeInterval?, now: Date, calendar: Calendar) -> String {
        guard let resetsAt else { return "Reset time unavailable" }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return "Awaiting reset update" }
        if (duration ?? .infinity) <= 6 * 3600 { return "Resets in \(span(seconds))" }
        return "Resets \(moment(resetsAt, now: now, calendar: calendar)) · \(span(seconds))"
    }

    /// The forecast line under a meter.
    public static func forecast(_ forecast: UsageForecast, now: Date, calendar: Calendar) -> String {
        switch forecast.outcome {
        case .fineUntilReset: "At this pace: fine until reset"
        case .runsOut(let date): "At this pace: runs out \(moment(date, now: now, calendar: calendar))"
        case .usedUp: "Used up until reset"
        case .tooEarly: "Just reset: too early to tell"
        case .unknown, .stale, .awaitingReset: "—"
        }
    }

    /// The page's opening sentence about limits, or nil when no window has a guess.
    public static func headline(_ forecasts: [(title: String, forecast: UsageForecast)], now: Date, calendar: Calendar) -> String? {
        let usedUp = forecasts.filter { $0.forecast.outcome == .usedUp }.map(\.title)
        let running = forecasts.compactMap { item -> (String, Date)? in
            if case .runsOut(let date) = item.forecast.outcome { return (item.title, date) }
            return nil
        }.sorted { $0.1 < $1.1 }
        let guessed = forecasts.contains { item in
            switch item.forecast.outcome {
            case .fineUntilReset, .runsOut, .usedUp: true
            default: false
            }
        }
        guard guessed else { return nil }
        var parts: [String] = []
        if !usedUp.isEmpty { parts.append(list(usedUp) + (usedUp.count == 1 ? " is" : " are") + " used up") }
        if !running.isEmpty {
            parts.append("at this pace " + list(running.map { "\($0.0) runs out \(moment($0.1, now: now, calendar: calendar))" }))
        }
        if parts.isEmpty {
            // Only windows that last: "every limit" only when every window is known to; otherwise
            // name the ones that are and say nothing about the rest (too early, unknown, stale).
            let fine = forecasts.filter { $0.forecast.outcome == .fineUntilReset }.map(\.title)
            if fine.count == forecasts.count { return "At this pace every limit lasts until it resets." }
            return "At this pace " + list(fine) + (fine.count == 1 ? " lasts until it resets." : " last until they reset.")
        }
        let sentence = parts.joined(separator: "; ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: items[0] + " and " + items[1]
        default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    private static func formatter(_ template: String, locale: Locale, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale)
        return formatter
    }
}
