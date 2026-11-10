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
        "com.apple.MobileSMS": "Messages", "com.spotify.client": "Spotify",
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
    private func store(spans: [ActivitySpan]) async throws -> TodayStore {
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
        return today
    }

    private func render<V: View>(_ view: V, width: CGFloat, dark: Bool, to url: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.padding(24).frame(width: width).background(AppAppearance.background))
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
