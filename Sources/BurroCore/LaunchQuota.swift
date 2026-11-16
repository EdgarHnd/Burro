// The New chat sheet's quiet quota line for the chosen provider, from the usage store's last
// reading: "Claude session: 38% left · resets 23:00". It names the limit with the least left among
// the provider's general windows (Claude's session and weekly, Codex's own limits) and a model
// window that matches the chosen model (Claude's "Opus weekly" for Opus); on a tie the shorter
// window wins. The reset time is the clock time today, else weekday and time. Nothing is shown when
// usage is off, the provider reported a problem, the reading is stale, or no window has a value.
import Foundation

public enum LaunchQuota {
    public static func line(provider: LaunchProvider, modelTitle: String?, usage: ProviderUsageSnapshot,
                            now: Date, calendar: Calendar, locale: Locale = Locale(identifier: "en_US_POSIX")) -> String? {
        guard usage.availability == .available else { return nil }
        let id: UsageProvider = provider == .claude ? .claude : .codex
        guard let reading = usage.providers.first(where: { $0.id == id }), reading.issue == nil, !reading.isLoading,
              !reading.isStale(now: now) else { return nil }
        let candidates = reading.windows.filter { window in
            guard window.remainingPercent != nil, !window.isExpired(now: now) else { return false }
            return applies(window, provider: provider, modelTitle: modelTitle)
        }
        guard let window = candidates.min(by: { a, b in
            let left = a.remainingPercent ?? 0, right = b.remainingPercent ?? 0
            if left != right { return left < right }
            return (a.duration ?? .infinity) < (b.duration ?? .infinity)
        }), let remaining = window.remainingPercent else { return nil }
        let percent = Int(max(0, min(100, remaining)).rounded())
        var text = "\(name(window, provider: provider)): \(percent)% left"
        if let resets = window.resetsAt { text += " · resets " + resetTime(resets, now: now, calendar: calendar, locale: locale) }
        return text
    }

    /// General windows always apply; a model's own window only for that model.
    static func applies(_ window: UsageWindow, provider: LaunchProvider, modelTitle: String?) -> Bool {
        switch provider {
        case .codex:
            // Other buckets ("<name> · 5 hours") are separate model quotas; only Codex's own limits.
            return window.id.hasPrefix("codex:")
        case .claude:
            guard let scope = modelScope(window) else { return true }
            guard let modelTitle, let family = scope.split(separator: " ").first.map({ $0.lowercased() }) else { return false }
            return modelTitle.lowercased().split(separator: " ").first.map(String.init) == family
        }
    }

    /// The model a Claude window is limited to ("Opus", "Sonnet 4.5"), or nil for a general window.
    static func modelScope(_ window: UsageWindow) -> String? {
        if let model = window.model { return model }
        switch window.id {
        case "seven_day_opus": return "Opus"
        case "seven_day_sonnet": return "Sonnet"
        default: return nil
        }
    }

    static func name(_ window: UsageWindow, provider: LaunchProvider) -> String {
        let agent = provider == .claude ? "Claude" : "Codex"
        if window.duration == 5 * 3600 { return provider == .claude ? "\(agent) session" : "\(agent) 5-hour" }
        // A model's own window keeps the model's capital ("Claude Opus weekly"); general ones read as a phrase.
        if modelScope(window) != nil { return "\(agent) \(window.title)" }
        return "\(agent) \(window.title.prefix(1).lowercased() + window.title.dropFirst())"
    }

    static func resetTime(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.locale = locale
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }
}
