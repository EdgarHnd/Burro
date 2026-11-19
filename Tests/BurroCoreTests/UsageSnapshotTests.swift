import AppKit
import SwiftUI
import XCTest
@testable import Burro
@testable import BurroCore

/// Renders the Usage page with invented limits, tokens and runs to PNGs for a visual check. Skipped
/// unless BURRO_USAGE_SNAPSHOTS=1; writes to dist/screenshots (gitignored) or BURRO_SNAPSHOT_DIR.
/// Draws views offscreen; never reads real accounts, logs or history and never contacts a provider.
@MainActor final class UsageSnapshotTests: XCTestCase {
    private let calendar = Calendar.current
    /// A Monday at 09:20 local time.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 9, minute: 20)) ?? Date()
    }
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86400

    private func window(_ id: String, _ title: String, left: Double?, resetIn: TimeInterval?, duration: TimeInterval?, model: String? = nil) -> UsageWindow {
        UsageWindow(id: id, title: title, remainingPercent: left, resetsAt: resetIn.map { now.addingTimeInterval($0) }, duration: duration, model: model)
    }

    private func providers() -> [ProviderUsage] {
        var claude = ProviderUsage(id: .claude, updatedAt: now.addingTimeInterval(-60), windows: [
            window("session", "Session", left: 58, resetIn: 2 * hour + 10 * 60, duration: 5 * hour),
            window("weekly", "Weekly", left: 41, resetIn: 2 * day, duration: 7 * day),
            window("weekly-model:fable", "Fable weekly", left: 6, resetIn: 3 * day, duration: 7 * day, model: "Fable"),
        ])
        claude.identity = UsageIdentity(account: "sample@example.com", plan: "Max", owner: "sample-claude")
        claude.balance = UsageBalance(title: "Extra usage", used: 12.5, limit: 50, currency: "USD", enabled: true)
        var codex = ProviderUsage(id: .codex, updatedAt: now.addingTimeInterval(-60), windows: [
            window("codex:primary", "5 hours", left: 72, resetIn: 3 * hour + 5 * 60, duration: 5 * hour),
            window("codex:secondary", "Weekly", left: 33, resetIn: 4 * day, duration: 7 * day),
        ])
        codex.identity = UsageIdentity(account: "sample@example.org", plan: "Pro", owner: "sample-codex")
        codex.resetCredits = 1
        var grok = ProviderUsage(id: .grok, updatedAt: now.addingTimeInterval(-25 * 60), windows: [
            window("grok", "Subscription credits", left: 64, resetIn: nil, duration: nil),
        ])
        grok.identity = UsageIdentity(account: "sample-grok", plan: "SuperGrok", owner: "sample-grok")
        grok.products = [UsageProductShare(id: "chat", title: "Chat", usedPercent: 21), UsageProductShare(id: "code", title: "Code", usedPercent: 15)]
        return [codex, claude, grok]
    }

    private func week() -> UsageWeek {
        let today = calendar.startOfDay(for: now)
        let tokens: [Double] = [8.9e6, 10.7e6, 9.6e6, 11.2e6, 6.3e6, 4.1e6, 7.6e6]
        let days = tokens.enumerated().map { index, value in
            UsageWeek.Day(date: calendar.date(byAdding: .day, value: index - 6, to: today) ?? today, tokens: value, apiValue: value / 1e6 * 9.2)
        }
        let models = [
            UsageWeek.Model(provider: .claude, model: "claude-opus-5-5", tokens: 4.4e6, apiValue: 41),
            UsageWeek.Model(provider: .claude, model: "claude-fable-5-2", tokens: 1.9e6, apiValue: 22),
            UsageWeek.Model(provider: .codex, model: "gpt-5.5", tokens: 1.3e6, apiValue: nil),
        ]
        return UsageWeek(days: days, todayModels: models, records: 4210, pricedRecords: 3980, partial: false, scannedAt: now)
    }

    private func extras() -> UsagePageExtras {
        let rows = UsageBreakdown.projects([("focustown", 4.1e6, 38), ("burro", 2.0e6, 19), ("support-console", 1.2e6, 11)],
                                           total: 7.6e6, totalValue: 70)
        let budget = UsageBudget(triageRuns: 9, cap: 150, autoTriage: true, paused: nil, runsToday: 12, costToday: 1.84,
                                 triageModel: "Haiku 5.5", askModel: "Fable 5.2")
        return UsagePageExtras(projects: rows, projectsPartial: false, budget: budget)
    }

    private func store() throws -> UsageStore {
        let suite = "burro.usage.snapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        // History off so the store never reads the real quota history file.
        var preferences = UsagePreferences(); preferences.history = false
        defaults.set(try JSONEncoder().encode(preferences), forKey: "usagePreferences")
        let usage = UsageStore(defaults: defaults) { provider, _, _ in .failure(provider, .unavailable) }
        return usage
    }

    /// Local history state on its own defaults suite; `open` providers start expanded.
    private func localHistory(open: [UsageProvider] = []) throws -> UsageLocalHistoryState {
        let suite = "burro.usage.localhistory.snapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        for provider in open { defaults.set(true, forKey: UsageLocalHistoryState.expandedKey(provider)) }
        return UsageLocalHistoryState(defaults: defaults)
    }

    /// An invented 30-day scan: quieter weekends, today partway through.
    private func localCost() -> LocalUsageCost {
        let today = calendar.startOfDay(for: now)
        let days = (0..<30).map { index -> LocalUsageDay in
            let date = calendar.date(byAdding: .day, value: index - 29, to: today) ?? today
            let weekend = calendar.isDateInWeekend(date)
            let tokens: Double = index == 29 ? 4.4e6 : (weekend ? 1.2e6 : 6.0e6) + Double(index % 7) * 0.7e6
            return LocalUsageDay(date: date, tokens: tokens, apiValue: tokens / 1e6 * 8.6, pricedRecords: 120)
        }
        return LocalUsageCost(days: days, models: ["claude-opus-5-5": 118e6, "claude-fable-5-2": 41e6, "claude-haiku-5-5": 6.2e6],
                              recordCount: 3720, pricedCount: 3604, partial: false, scannedAt: now)
    }

    func testLocalHistoryRemembersWhichProvidersAreOpen() throws {
        let suite = "burro.usage.localhistory.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: UsageLocalHistoryState.expandedKey(.codex))
        let state = UsageLocalHistoryState(defaults: defaults)
        XCTAssertEqual(state.expanded, [.codex])
        // Seeded so the toggle doesn't start a real scan.
        state.seed(localCost(), provider: .claude, profile: nil)
        state.toggle(.claude, profile: nil)
        state.toggle(.codex, profile: nil)
        XCTAssertTrue(state.scanning.isEmpty)
        XCTAssertEqual(UsageLocalHistoryState(defaults: defaults).expanded, [.claude])
        XCTAssertNil(state.result(.claude, profile: "/tmp/other-profile"))
    }

    /// The page as UsagePageContent lays it out inside its scroll view, at a content width.
    private func page(_ usage: UsageStore, extras: UsagePageExtras, history: UsageLocalHistoryState) -> some View {
        UsagePage(usage: usage, extras: extras, now: now, localHistory: history) {}
            .padding(.horizontal, 36).padding(.vertical, 28)
            .modifier(AppTheme())
    }

    func testRenderUsageSnapshots() throws {
        guard ProcessInfo.processInfo.environment["BURRO_USAGE_SNAPSHOTS"] == "1" else { throw XCTSkip("set BURRO_USAGE_SNAPSHOTS=1") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = ProcessInfo.processInfo.environment["BURRO_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("dist/screenshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // One low limit: Claude's Fable weekly at 6%.
        let low = try store()
        low.snapshot = ProviderUsageSnapshot(availability: .available, providers: providers())
        low.week = week()
        let alerts = UsageAlert.alerts(low.snapshot.providers, now: now)
        XCTAssertEqual(alerts.map(\.title), ["Claude Fable weekly"])

        // Every provider healthy: the same accounts with Fable comfortably inside its window and Grok read just now.
        let healthy = try store()
        healthy.snapshot = ProviderUsageSnapshot(availability: .available, providers: providers().map { provider in
            var provider = provider
            provider.updatedAt = now.addingTimeInterval(-60)
            provider.windows = provider.windows.map { window in
                var window = window
                if window.model != nil { window.remainingPercent = 64 }
                return window
            }
            return provider
        })
        healthy.week = week()
        XCTAssertTrue(UsageAlert.alerts(healthy.snapshot.providers, now: now).isEmpty)

        // Problems: Claude needs Keychain access, Codex signed out, Grok's reading stale; a message; no local figures yet.
        let states = try store()
        var stale = ProviderUsage(id: .grok, updatedAt: now.addingTimeInterval(-40 * 60), windows: [window("grok", "Weekly credits", left: 52, resetIn: 2 * day, duration: 7 * day)])
        stale.identity = UsageIdentity(account: "sample-grok", plan: "SuperGrok", owner: "sample-grok")
        states.snapshot = ProviderUsageSnapshot(availability: .available, providers: [.failure(.codex, .signInRequired), .failure(.claude, .permissionRequired), stale])
        states.message = "Finish Claude sign-in in Terminal, then refresh here."

        let off = try store()
        off.enabled = false

        let full = extras()
        for width in [935, 1015, 1215] {
            for dark in [true, false] {
                let suffix = "\(width)-\(dark ? "dark" : "light")"
                try render(page(healthy, extras: full, history: try localHistory()), width: CGFloat(width), dark: dark, to: out.appendingPathComponent("usage-healthy-\(suffix).png"))
                try render(page(low, extras: full, history: try localHistory()), width: CGFloat(width), dark: dark, to: out.appendingPathComponent("usage-low-\(suffix).png"))
                try render(page(states, extras: UsagePageExtras(), history: try localHistory()), width: CGFloat(width), dark: dark, to: out.appendingPathComponent("usage-signedout-\(suffix).png"))
                try render(page(off, extras: UsagePageExtras(), history: try localHistory()), width: CGFloat(width), dark: dark, to: out.appendingPathComponent("usage-off-\(suffix).png"))
            }
        }

        // Claude's local history open with an invented scan; Codex's open but not read yet this launch.
        let history = try localHistory(open: [.claude, .codex])
        history.seed(localCost(), provider: .claude, profile: nil)
        try render(page(low, extras: full, history: history), width: 1215, dark: true, to: out.appendingPathComponent("usage-history-1215-dark.png"))
        try render(page(low, extras: full, history: history), width: 935, dark: false, to: out.appendingPathComponent("usage-history-935-light.png"))

        // One provider: its second window fills the strip.
        let single = try store()
        single.snapshot = ProviderUsageSnapshot(availability: .available, providers: [providers()[0]])
        single.week = week()
        try render(page(single, extras: full, history: try localHistory()), width: 1015, dark: true, to: out.appendingPathComponent("usage-single-1015-dark.png"))
    }

    private func render<V: View>(_ view: V, width: CGFloat, dark: Bool, to url: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: width).background(AppAppearance.background))
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame.size = host.fittingSize
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.frame.size = host.fittingSize
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let bounds = host.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
