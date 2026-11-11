import AppKit
import SwiftUI
import XCTest
@testable import Burro
@testable import BurroCore

/// Renders the activity views with a synthetic day to PNGs for a visual check. Skipped unless
/// BURRO_ACTIVITY_SNAPSHOTS=1; writes to dist/screenshots (gitignored) or BURRO_SNAPSHOT_DIR.
/// Draws views offscreen; never captures the screen and never reads real activity.
@MainActor final class ActivitySnapshotTests: XCTestCase {
    private let calendar = Calendar.current
    private var dayStart: Date { calendar.startOfDay(for: Date()) }
    private func at(_ hour: Int, _ minute: Double) -> Date { dayStart.addingTimeInterval(Double(hour) * 3600 + minute * 60) }

    private static let names = [
        "com.apple.mail": "Mail", "com.tinyspeck.slackmacgap": "Slack", "com.apple.dt.Xcode": "Xcode", "company.thebrowser.Browser": "Arc",
        "com.anthropic.claudefordesktop": "Claude", "com.figma.Desktop": "Figma", "com.apple.Terminal": "Terminal", "notion.id": "Notion",
        "com.apple.MobileSMS": "Messages", "com.spotify.client": "Spotify", "com.apple.loginwindow": "loginwindow",
    ]
    private func span(_ bundle: String, _ from: Date, _ to: Date, _ title: String? = nil, _ address: String? = nil) -> ActivitySpan {
        ActivitySpan(ActivityPrivacy.key(bundleID: bundle, app: Self.names[bundle] ?? bundle, title: title, address: address), start: from, end: to)
    }

    /// A full working day: mail and Slack, a long Xcode stretch with flicks, breaks, lunch away, a bank visit (Private),
    /// design, a stretch of switching apps, analytics, docs, and Xcode still running at "now" (18:42).
    private func workingDay() -> [ActivitySpan] {
        let mail = "com.apple.mail", slack = "com.tinyspeck.slackmacgap", xcode = "com.apple.dt.Xcode", arc = "company.thebrowser.Browser"
        var spans = [
            span(mail, at(8, 32), at(8, 50), "Inbox"),
            span(slack, at(8, 50), at(9, 5), "burro — Slack"),
            span(xcode, at(9, 5), at(9, 50), "ActivityTimeline.swift"),
            span(arc, at(9, 50), at(9, 51), "Pull request #48 · burro", "https://github.com/acme/burro/pull/48"),
            span(xcode, at(9, 51), at(10, 30), "ActivityTimeline.swift"),
            span(slack, at(10, 30), at(10, 31.5), "burro — Slack"),
            span(xcode, at(10, 31.5), at(11, 0), "ActivitySummary.swift"),
            span(xcode, at(11, 0), at(11, 20), "ActivityTimelineTests.swift"),
            span(arc, at(11, 20), at(11, 35), "Lo-fi beats", "https://www.youtube.com/watch?v=x"),
            span(arc, at(11, 35), at(12, 5), "Pull request #48 · burro", "https://github.com/acme/burro/pull/48"),
            span("com.anthropic.claudefordesktop", at(12, 5), at(12, 40), "Activity day view"),
            // Lunch: away, nothing recorded.
            span(arc, at(13, 30), at(13, 34), "Accounts", "https://www.chase.com/accounts"),
            span("com.figma.Desktop", at(13, 34), at(14, 10), "Burro — Today"),
        ]
        // Half an hour of flicking between Slack, Mail and Xcode: one "Switching between" block.
        let flick = [slack, mail, xcode]
        for i in 0..<20 {
            let from = at(14, 10 + Double(i) * 1.5)
            spans.append(span(flick[i % 3], from, from.addingTimeInterval(90), i % 3 == 2 ? "TodayDayView.swift" : nil))
        }
        spans += [
            span(xcode, at(14, 40), at(15, 20), "TodayDayView.swift"),
            span("com.apple.Terminal", at(15, 20), at(15, 50), "swift test"),
            span(xcode, at(15, 50), at(16, 10), "TodayDayView.swift"),
            span(arc, at(16, 10), at(16, 25), "r/swift", "https://www.reddit.com/r/swift"),
            span(arc, at(16, 25), at(17, 10), "Retention · Mixpanel", "https://mixpanel.com/project/1/view/2"),
            span("notion.id", at(17, 10), at(17, 40), "Activity plan"),
            span("com.apple.MobileSMS", at(17, 40), at(17, 42)),
            span(xcode, at(17, 42), at(18, 41.5), "HomeActivity.swift"),
        ]
        return spans
    }

    private var now: Date { at(18, 42) }

    /// The day the owner's screenshots showed: the lock screen at 06:12, 10:58 and 11:03 (zero-length
    /// spans), a first real activity at 10:58, half an hour of Claude and Arc in 3 to 6 minute turns
    /// (Arc's page titles naming "Arc"), a 20-second site, a long idle gap after lunch, and work
    /// until "now" (17:20).
    private func messyDay() -> [ActivitySpan] {
        let claude = "com.anthropic.claudefordesktop", arc = "company.thebrowser.Browser", login = "com.apple.loginwindow"
        var spans = [
            span(login, at(6, 12), at(6, 12.1)),
            span(login, at(10, 58), at(10, 58)),
            span(claude, at(10, 58), at(11, 3), "Claude"),
            span(login, at(11, 3), at(11, 3)),
        ]
        var minute = 3.0
        for (index, length) in [4.0, 3, 6, 5, 3, 4, 6, 3, 5, 4].enumerated() {
            spans.append(index % 2 == 0
                ? span(claude, at(11, minute), at(11, minute + length), "Claude")
                : span(arc, at(11, minute), at(11, minute + length), "Overview - Focus town: Pomodoro Keeper - Arc", "https://x.com/home"))
            minute += length
        }
        spans += [
            span(arc, at(11, 46), at(11, 46.33), "Charming", "https://usecharming.com"),
            span("com.apple.dt.Xcode", at(11, 46.33), at(12, 40), "TodayView.swift — Xcode"),
            span(arc, at(12, 40), at(12, 58), "Pull request #52 · burro", "https://github.com/acme/burro/pull/52"),
            // Away 12:58 to 15:10.
            span(login, at(15, 9), at(15, 10)),
            span("com.apple.Terminal", at(15, 10), at(15, 40), "swift test"),
            span("com.apple.dt.Xcode", at(15, 40), at(16, 50), "TodayDayView.swift"),
            span("com.spotify.client", at(16, 50), at(17, 5), "Spotify"),
            span(claude, at(17, 5), at(17, 19.5), "Claude"),
        ]
        return spans
    }

    /// Agent activity for the messy day: first message 0:07, last 12:16.
    private var messyChats: DailyActivity {
        var turns = Array(repeating: 0, count: 24), replies = Array(repeating: 0, count: 24)
        for (hour, count) in [0: 3, 9: 2, 10: 6, 11: 14, 12: 9] { turns[hour] = count; replies[hour] = count * 7 }
        return DailyActivity(day: dayStart, turnsByHour: turns, repliesByHour: replies, questions: 5, firstTurn: at(0, 7), lastTurn: at(12, 16),
                             chats: [], partial: false)
    }

    private var messyRows: [TodayRow] {
        [("Reorganise the Today page", "burro", TodayRow.Status.working, at(17, 18), AgentProvider.claude),
         ("Fix Arc site detection", "burro", .toRead, at(16, 40), .codex),
         ("Store prices test", "focus", .needsYou, at(12, 16), .claude),
         ("Weekly report", "notes", .idle, at(9, 30), .codex)].enumerated().map { index, row in
            TodayRow(id: "row\(index)", title: row.0, provider: row.4, status: row.2, project: row.1, breadcrumb: row.1, lastAt: row.3,
                     preview: nil, turns: 3, session: nil)
        }
    }

    private var messyNow: Date { at(17, 20) }

    /// The whole page with a stand-in for Shipped (it reads GitHub, which snapshots never do).
    private func page(_ today: TodayStore) -> some View {
        TodayPage(today: today, activity: messyChats, rows: messyRows, todos: .init(done: 3, open: 5, added: 2), waitingNow: 1,
                  grouping: .constant(TodayGrouping.status.rawValue), now: messyNow, open: { _ in }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("SHIPPED").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
                HomeEmptyCard(symbol: "shippingbox", title: "Shipped", detail: "Stand-in: the real section reads GitHub, which snapshots don't.") { EmptyView() }
            }
        }
        .padding(.horizontal, 36).padding(.vertical, 28)
        .frame(maxWidth: 1240).frame(maxWidth: .infinity)
    }

    /// A day imported from Dayflow: one block per card, a Private card, then live tracking from 17:30.
    private func importedDay() -> [ActivitySpan] {
        let day = TodoDay.key(dayStart, calendar: calendar)
        let cards: [(Double, Double, String, String?, String?)] = [
            (9, 10.5, "Engineering / Product", "Wiring the importer into burro-inspect", "Xcode"),
            (10.5, 10.6, "Communication", "Replied to the team thread", "Slack"),
            (10.6, 11.5, "Research & Strategy", "Reading about SQLite immutable mode", "sqlite.org"),
            (11.5, 12, "Distraction", "Watching a talk", "youtube.com"),
            (13, 13.5, "Personal", "Hidden", "Messages"),
            (13.5, 15, "Data & Insights", "Retention by cohort", "mixpanel.com"),
            (15, 16, "Engineering / Product", "Fixing timeline blocks", "Claude"),
            (16, 17.5, "Engineering / Product", "Snapshot tests", "Ghostty"),
        ]
        var spans: [ActivitySpan] = cards.enumerated().compactMap { index, card in
            let item = DayflowImport.Card(id: Int64(index), start: Int64(at(0, card.0 * 60).timeIntervalSince1970),
                                          end: Int64(at(0, card.1 * 60).timeIntervalSince1970), day: day, title: card.3, category: card.2,
                                          metadata: card.4.map { #"{"appSites":{"primary":"\#($0)"}}"# }, deleted: false)
            if case .span(let span) = DayflowImport.span(for: item, calendar: calendar) { return span }
            return nil
        }
        spans += [span("com.apple.dt.Xcode", at(17, 30), at(18, 41.5), "ActivityImport.swift")]
        return spans
    }

    func testRenderActivitySnapshots() async throws {
        guard ProcessInfo.processInfo.environment["BURRO_ACTIVITY_SNAPSHOTS"] == "1" else { throw XCTSkip("set BURRO_ACTIVITY_SNAPSHOTS=1") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = ProcessInfo.processInfo.environment["BURRO_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("dist/screenshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let full = try await store(spans: workingDay())
        let empty = try await store(spans: [])
        let day = try XCTUnwrap(full.tracked)
        XCTAssertGreaterThan(day.blocks.count, 8)

        let messy = try await store(spans: messyDay())
        let messyTracked = try XCTUnwrap(messy.tracked)
        XCTAssertFalse(messyTracked.blocks.contains { $0.title.contains("loginwindow") || $0.seconds < 60 })
        XCTAssertEqual(messyTracked.blocks.first?.start, at(10, 58))
        XCTAssertTrue(messyTracked.blocks.contains { $0.title == "Switching between Claude and Arc" }, messyTracked.blocks.map(\.title).description)
        XCTAssertFalse(messyTracked.sites.contains { $0.name == "usecharming.com" })
        for width in [1400, 1000, 700] {
            try render(page(messy), width: CGFloat(width), dark: true, padding: 0, to: out.appendingPathComponent("today-page-\(width)-dark.png"))
        }
        try render(page(messy), width: 1400, dark: false, padding: 0, to: out.appendingPathComponent("today-page-1400-light.png"))
        let off = try await store(spans: messyDay(), enabled: false)
        try render(page(off), width: 1000, dark: true, padding: 0, to: out.appendingPathComponent("today-page-off-1000-dark.png"))

        let imported = try await store(spans: importedDay())
        XCTAssertEqual(try XCTUnwrap(imported.tracked).blocks.count, 9)
        try render(TodayDaySection(today: imported, now: now), width: 868, dark: true, to: out.appendingPathComponent("today-imported-dark.png"))

        for dark in [true, false] {
            let suffix = dark ? "dark" : "light"
            try render(TodayDaySection(today: full, now: now), width: 868, dark: dark, to: out.appendingPathComponent("today-wide-\(suffix).png"))
            try render(TodayDaySection(today: full, now: now), width: 600, dark: dark, to: out.appendingPathComponent("today-narrow-\(suffix).png"))
            try render(TodayDaySection(today: empty, now: now), width: 868, dark: dark, to: out.appendingPathComponent("today-empty-\(suffix).png"))
            try render(HomeActivityCard(tracker: full.tracker, active: false, day: day, now: now) {}, width: 368, dark: dark,
                       to: out.appendingPathComponent("home-card-\(suffix).png"))
            try render(HomeActivityCard(tracker: empty.tracker, active: false, day: try XCTUnwrap(empty.tracked), now: now) {}, width: 368,
                       dark: dark, to: out.appendingPathComponent("home-card-empty-\(suffix).png"))
        }
    }

    /// A tracker on a temporary folder holding `spans`, and a Today store that has read today through it.
    private func store(spans: [ActivitySpan], enabled: Bool = true) async throws -> TodayStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-snapshot-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let log = ActivityLog(folder: folder)
        try log.append(spans)
        let suite = "burro.snapshot.\(UUID().uuidString)"
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

    private func render<V: View>(_ view: V, width: CGFloat, dark: Bool, padding: CGFloat = 24, to url: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.padding(padding).frame(width: width).background(AppAppearance.background))
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame.size = host.fittingSize
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
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
