// Account-scoped quota samples and explicitly linear pace estimates; no credentials or chat text.
import Foundation

public struct UsageHistorySample: Codable, Sendable, Identifiable, Equatable {
    public var provider: UsageProvider
    public var account: String
    public var date: Date
    public var windows: [UsageWindow]
    public var id: String { "\(provider.rawValue):\(account):\(date.timeIntervalSince1970)" }
    public init?(usage: ProviderUsage) {
        guard !usage.isLoading, usage.issue == nil, let identity = usage.identity, let date = usage.updatedAt else { return nil }
        provider = usage.id; account = identity.scope; self.date = date; windows = usage.windows
    }
    public static func retaining(_ samples: [Self], now: Date = Date()) -> [Self] {
        Array(samples.filter { $0.date >= now.addingTimeInterval(-30 * 86400) && $0.date <= now.addingTimeInterval(60) }
            .sorted { $0.date < $1.date }.suffix(15000))
    }
}
public struct UsagePace: Sendable, Equatable {
    public var reserve: Double
    public var expectedRemaining: Double
    public var exhaustion: Date?
    public init?(window: UsageWindow, now: Date) {
        guard let remaining = window.remainingPercent, let end = window.resetsAt,
              let duration = window.duration, duration > 0, end > now else { return nil }
        let elapsed = duration - end.timeIntervalSince(now)
        guard elapsed > 60, elapsed <= duration else { return nil }
        expectedRemaining = 100 * (1 - elapsed / duration)
        reserve = remaining - expectedRemaining
        let rate = (100 - remaining) / elapsed
        exhaustion = rate > 0 ? now.addingTimeInterval(remaining / rate) : nil
    }
}
