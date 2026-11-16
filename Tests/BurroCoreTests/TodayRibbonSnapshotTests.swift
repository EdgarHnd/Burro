import AppKit
import SwiftUI
import XCTest
@testable import Burro
@testable import BurroCore

/// Renders the Today page (ribbon and list) with an invented day to PNGs for a visual check.
/// Skipped unless BURRO_TODAY_SNAPSHOTS=1; writes to dist/screenshots (gitignored) or
/// BURRO_SNAPSHOT_DIR. Draws views offscreen; never captures the screen, never reads real activity,
/// agent logs or GitHub.
@MainActor final class TodayRibbonSnapshotTests: XCTestCase {
    private let calendar = Calendar.current
    private var dayStart: Date { calendar.startOfDay(for: Date()) }
    private func at(_ hour: Int, _ minute: Double = 0) -> Date { dayStart.addingTimeInterval(Double(hour) * 3600 + minute * 60) }
    private func span(_ from: Date, _ to: Date) -> DateInterval { DateInterval(start: from, end: to) }
    private var now: Date { at(21, 40) }

    private static let names = [
        "com.apple.dt.Xcode": "Xcode", "com.tinyspeck.slackmacgap": "Slack", "com.apple.Terminal": "Terminal", "org.godotengine.godot": "Godot",
        "company.thebrowser.Browser": "Arc", "com.apple.mail": "Mail", "com.apple.Music": "Music",
    ]
    private func tracked(_ bundle: String, _ from: Date, _ to: Date, _ title: String? = nil, _ address: String? = nil) -> ActivitySpan {
        ActivitySpan(ActivityPrivacy.key(bundleID: bundle, app: Self.names[bundle] ?? bundle, title: title, address: address), start: from, end: to)
    }

    /// Recording from 10:00; away 13:30–16:10 and a few shorter gaps; still at it at 21:40.
    private func spans() -> [ActivitySpan] {
        let xcode = "com.apple.dt.Xcode", slack = "com.tinyspeck.slackmacgap", terminal = "com.apple.Terminal", arc = "company.thebrowser.Browser"
        return [
            tracked(xcode, at(10), at(10, 40), "ResumeController.swift"),
            tracked(slack, at(10, 40), at(10, 55), "focustown — Slack"),
            tracked(terminal, at(10, 55), at(11, 35), "claude"),
            tracked(arc, at(12), at(12, 35), "Lo-fi beats", "https://www.youtube.com/watch?v=x"),
            tracked("org.godotengine.godot", at(12, 45), at(13, 20), "autumn.tscn"),
            tracked("com.apple.Music", at(13, 20), at(13, 30)),
            // Away 13:30–16:10.
            tracked("com.apple.mail", at(16, 10), at(16, 25), "Inbox"),
            tracked(terminal, at(16, 25), at(17, 10), "codex"),
            tracked(arc, at(18, 40), at(19, 4), "r/godot", "https://www.reddit.com/r/godot"),
            tracked(arc, at(19, 4), at(19, 30), "Pull request #212", "https://github.com/acme/burro/pull/212"),
            tracked(terminal, at(20, 30), at(20, 50), "claude"),
            tracked(xcode, at(20, 50), at(21, 39.5), "HomeView.swift"),
        ]
    }

    private func chat(_ id: String, _ title: String, _ active: [DateInterval], preview: String? = nil) -> DailyActivity.Chat {
        DailyActivity.Chat(id: id, provider: id.hasPrefix("codex") ? .codex : .claude, folder: "/work/focustown", turns: 3, replies: 9, questions: 0,
                           lastAt: active.last?.end ?? now, title: title, preview: preview, active: active)
    }

    private var activity: DailyActivity {
        let chats = [
            chat("codex:ios", "iOS hang on resume", [span(at(13, 10), at(15, 20)), span(at(21, 22), now)]),
            chat("claude:godot", "Godot shader warm-up", [span(at(14), at(16, 10)), span(at(20, 59), now)]),
            chat("claude:shots", "Store screenshots refresh", [span(at(13, 35), at(14, 55))], preview: "Rendered 42 screenshots for 7 locales; two need a caption fix."),
            chat("codex:coin", "Coin double-count fix", [span(at(11), at(11, 40)), span(at(19, 50), at(21, 15))]),
            chat("claude:alerts", "Support dashboard alerts", [span(at(19, 40), at(20, 20)), span(at(21, 36), at(21, 39))]),
            chat("claude:streak", "Streak ladder config", [span(at(21), at(21, 36))]),
        ]
        var turns = Array(repeating: 0, count: 24)
        for hour in [10, 11, 12, 16, 17, 19, 20, 21] { turns[hour] = 3 }
        return DailyActivity(day: dayStart, turnsByHour: turns, repliesByHour: turns.map { $0 * 6 }, questions: 2, firstTurn: at(10, 5),
                             lastTurn: at(21, 30), chats: chats, partial: false)
    }

    private func session(_ id: String, _ title: String, _ state: AgentState) -> AgentSession {
        AgentSession(id: id, provider: id.hasPrefix("codex") ? .codex : .claude, title: title, cwd: "/work/focustown", state: state, updatedAt: now,
                     evidence: "Fixture")
    }

    private var rows: [TodayRow] {
        let items: [(String, String, TodayRow.Status, Date, Date?)] = [
            ("claude:streak", "Streak ladder config", .needsYou, at(21, 36), nil),
            ("claude:alerts", "Support dashboard alerts", .needsYou, at(21, 39), nil),
            ("codex:ios", "iOS hang on resume", .working, now, at(21, 22)),
            ("codex:android", "Android 2.2.24 release notes", .working, now, at(21, 37)),
            ("claude:godot", "Godot shader warm-up", .working, now, at(20, 59)),
            ("claude:twitter", "Twitter link setup", .toRead, at(21, 17), nil),
            ("claude:friends", "Study with friends layout", .toRead, at(20, 20), nil),
            ("claude:shots", "Store screenshots refresh", .toRead, at(14, 55), nil),
            ("codex:machine", "Machine health on Home", .idle, at(19, 30), nil),
            ("codex:audit", "Audit repository security", .idle, at(18, 42), nil),
            ("codex:refund", "Refund alert routing", .idle, at(16, 48), nil),
            ("codex:coin", "Coin double-count fix", .idle, at(11, 42), nil),
        ]
        return items.map { id, title, status, last, since in
            TodayRow(id: id, title: title, provider: id.hasPrefix("codex") ? .codex : .claude, status: status, project: "focustown",
                     breadcrumb: "focustown", lastAt: last, preview: nil, turns: 3, session: session(id, title, .working), activeSince: since)
        }
    }

    private var shipped: ShippedDay {
        func pull(_ number: Int, _ title: String, _ time: Date) -> ShippedDay.PullRequest {
            ShippedDay.PullRequest(number: number, title: title, url: URL(string: "https://github.com/acme/focustown/pull/\(number)"), author: "you",
                                   mergedAt: time, base: "main", head: "fix", additions: 40, deletions: 12, mergeCommit: nil)
        }
        return ShippedDay(day: dayStart, repository: "acme/focustown", defaultBranch: "main", you: "you", people: [:],
                          production: [ShippedDay.Release(id: "d1", kind: .deployment, title: "Production deploy", detail: "", actor: "you", at: at(17, 20),
                                                          status: .live, url: nil, target: "production")],
                          merged: [pull(1401, "Fix coin double-count on resume", at(11, 42)), pull(1403, "Warm shaders before the autumn scene", at(15, 5)),
                                   pull(1405, "Route refund alerts to the queue", at(16, 48)), pull(1412, "Show machine health on Home", at(19, 30))],
                          branches: [], partial: false, fetchedAt: now)
    }

    private let outcomes = [
        "codex:ios": "Found the resume deadlock; fix on a branch, UI tests still running.",
        "claude:godot": "Cut first-frame stutter in the autumn scene from 380 ms to 40 ms.",
    ]

    /// The store read the invented day at the real clock; the fixture's day was read at its own now.
    private func readAtNow(_ day: ActivityDay?) -> ActivityDay? {
        guard var day else { return nil }
        day.coveredUntil = now
        return day
    }

    private func page(_ today: TodayStore, mode: TodayDayMode, tracking: Bool = true, partial: Bool = false) -> some View {
        var activity = self.activity
        activity.partial = partial
        let away = tracking ? AgentAwayTime.summary(chats: activity.chats, tracked: readAtNow(today.tracked), day: dayStart, now: now, partial: activity.partial) : nil
        return TodayPage(today: today, activity: activity, away: away, rows: rows, todos: .init(done: 3, open: 5, added: 2), waitingNow: 2,
                         shippedState: .loaded(shipped), outcomes: outcomes, grouping: .constant(TodayGrouping.status.rawValue),
                         mode: .constant(mode.rawValue), shippedDetails: .constant(false), now: now, open: { _ in }) { EmptyView() }
            .padding(.horizontal, 36).padding(.vertical, 28)
            .frame(maxWidth: 1240).frame(maxWidth: .infinity)
    }

    func testRenderTodaySnapshots() async throws {
        guard ProcessInfo.processInfo.environment["BURRO_TODAY_SNAPSHOTS"] == "1" else { throw XCTSkip("set BURRO_TODAY_SNAPSHOTS=1") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = ProcessInfo.processInfo.environment["BURRO_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("dist/screenshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let today = try await store(spans: spans(), coverage: [span(at(10), now)])
        let away = try XCTUnwrap(AgentAwayTime.summary(chats: activity.chats, tracked: readAtNow(today.tracked), day: dayStart, now: now))
        XCTAssertGreaterThan(away.total, 2 * 3600)

        try render(page(today, mode: .ribbon), width: 1440, dark: true, to: out.appendingPathComponent("today-ribbon-1440-dark.png"))
        try render(page(today, mode: .ribbon), width: 1440, dark: false, to: out.appendingPathComponent("today-ribbon-1440-light.png"))
        try render(page(today, mode: .ribbon), width: 1000, dark: true, to: out.appendingPathComponent("today-ribbon-1000-dark.png"))
        try render(page(today, mode: .ribbon), width: 760, dark: true, to: out.appendingPathComponent("today-ribbon-760-dark.png"))
        try render(page(today, mode: .list), width: 1440, dark: true, to: out.appendingPathComponent("today-list-1440-dark.png"))
        // A partial scan: the totals read "about".
        try render(page(today, mode: .ribbon, partial: true), width: 1440, dark: true, to: out.appendingPathComponent("today-ribbon-partial-1440-dark.png"))
        let off = try await store(spans: spans(), coverage: [span(at(10), now)], enabled: false)
        try render(page(off, mode: .ribbon, tracking: false), width: 1440, dark: true, to: out.appendingPathComponent("today-ribbon-off-1440-dark.png"))
    }

    private func store(spans: [ActivitySpan], coverage: [DateInterval], enabled: Bool = true) async throws -> TodayStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-today-snapshot-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let log = ActivityLog(folder: folder)
        try log.append(spans)
        for interval in coverage { try log.recordCoverage(interval) }
        let suite = "burro.today.snapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let tracker = ActivityTracker(defaults: defaults, log: log)
        tracker.enabled = true
        let today = TodayStore(defaults: defaults, tracker: tracker)
        today.refreshTracked()
        for _ in 0..<200 where today.tracked == nil { try await Task.sleep(for: .milliseconds(10)) }
        _ = try XCTUnwrap(today.tracked)
        tracker.enabled = enabled
        return today
    }

    private func render<V: View>(_ view: V, width: CGFloat, dark: Bool, to url: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: width).background(AppAppearance.background))
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame.size = host.fittingSize
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let bounds = host.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
