import AppKit
import SwiftUI
import XCTest
@testable import Burro
@testable import BurroCore

/// Renders the Today page (lanes and list) with an invented day to PNGs for a visual check, at the
/// content widths of a 1000, 1240 and 1440 pt window beside the sidebar (935, 1015, 1215), in dark
/// and light: tracking on and off, a past day, no chats, more than eight chats, chats whose activity
/// is unknown, and with and without a chat waiting. Skipped unless BURRO_TODAY_SNAPSHOTS=1; writes to dist/screenshots (gitignored) or
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

    private func chat(_ id: String, _ title: String, _ active: [DateInterval]?, preview: String? = nil, turns: Int = 3) -> DailyActivity.Chat {
        DailyActivity.Chat(id: id, provider: id.hasPrefix("codex") ? .codex : .claude, folder: "/work/focustown", turns: turns, replies: 9, questions: 0,
                           lastAt: active?.last?.end ?? at(12, 30), title: title, preview: preview, active: active)
    }

    private var activity: DailyActivity {
        let chats = [
            chat("codex:ios", "iOS hang on resume", [span(at(13, 10), at(15, 20)), span(at(21, 22), now)]),
            chat("claude:godot", "Godot shader warm-up", [span(at(14), at(16, 10)), span(at(20, 59), now)]),
            chat("claude:shots", "Store screenshots refresh", [span(at(13, 35), at(14, 55))], preview: "Rendered 42 screenshots for 7 locales; two need a caption fix."),
            chat("codex:coin", "Coin double-count fix", [span(at(11), at(11, 40)), span(at(19, 50), at(21, 15))]),
            chat("claude:alerts", "Support dashboard alerts", [span(at(19, 40), at(20, 20)), span(at(21, 36), at(21, 39))]),
            chat("claude:streak", "Streak ladder config", [span(at(21), at(21, 36))]),
            // An older helper's answer: this chat's stretches are unknown.
            chat("codex:refund", "Refund alert routing", nil, turns: 5),
        ]
        var turns = Array(repeating: 0, count: 24)
        for hour in [10, 11, 12, 16, 17, 19, 20, 21] { turns[hour] = 3 }
        return DailyActivity(day: dayStart, turnsByHour: turns, repliesByHour: turns.map { $0 * 6 }, questions: 2, firstTurn: at(10, 5),
                             lastTurn: at(21, 30), chats: chats, partial: false)
    }

    /// More than eight chats: the lanes cap at eight with "Show all N".
    private var busyActivity: DailyActivity {
        var day = activity
        for index in 0..<6 {
            let start = at(9 + index, 10)
            day.chats.append(chat("codex:extra\(index)", "Translation batch \(index + 1)", [span(start, start.addingTimeInterval(2400))]))
        }
        return day
    }
    private var busyRows: [TodayRow] {
        rows + (0..<6).map { index in
            TodayRow(id: "codex:extra\(index)", title: "Translation batch \(index + 1)", provider: .codex, status: .idle, project: "focustown-web",
                     breadcrumb: "focustown-web", lastAt: at(9 + index, 50), preview: nil, turns: 3, session: session("codex:extra\(index)", "x", .idle))
        }
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
            var live = session(id, title, .working)
            // Android runs on another machine: no stretches, state on the right only.
            if id == "codex:android" { live.remote = RemoteOrigin(hostID: UUID(), hostName: "mini", sampledAt: now, stale: false) }
            return TodayRow(id: id, title: title, provider: id.hasPrefix("codex") ? .codex : .claude, status: status, project: "focustown",
                            breadcrumb: id == "codex:android" ? "mini / focustown" : "focustown", lastAt: last, preview: nil, turns: 3,
                            session: live, activeSince: since)
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

    /// The queue's cards, as HomeNeedsBuilder makes them: one with triage's draft, one waiting on an approval.
    private var queue: TodayQueue {
        let cards = [
            HomeNeedsCardData(id: "claude:streak", title: "Streak ladder config", tags: ["This Mac · focustown", "Claude · Opus 5.5"], when: "4 min",
                              message: "Should the 7-day rung pay 40 or 50 coins?",
                              draft: HomeDraftData(text: "Go with 50, and keep the 30-day rung at 200.", label: "Draft", sendHelp: "Send this reply"),
                              handOff: nil, dismissable: true),
            HomeNeedsCardData(id: "claude:alerts", title: "Support dashboard alerts", tags: ["This Mac · focustown", "Claude · Sonnet 5"], when: "1 min",
                              message: "Waiting for your approval", draft: nil, handOff: "Open in Claude", dismissable: false),
        ]
        return TodayQueue(cards: cards, total: 2, needsSince: ["claude:streak": at(21, 36), "claude:alerts": at(21, 39)], oldest: at(21, 36),
                          avatars: [("claude:streak", .claude), ("claude:alerts", .claude)])
    }

    private var briefItems: [BriefItem] {
        [BriefItem(chatID: "claude:streak", kind: .decision, headline: "Asks about the 7-day rung", question: "Should the 7-day rung pay 40 or 50 coins?",
                   sourceHash: "h", createdAt: at(21, 37)),
         BriefItem(chatID: "codex:coin", kind: .blocked, headline: "Which save slot to migrate?", sourceHash: "h", createdAt: at(11, 20)),
         BriefItem(chatID: "codex:android", kind: .stuck, headline: "No new output for 45 min", sourceHash: "h", chatUpdatedAt: at(20, 50), createdAt: at(21, 35))]
    }

    private enum Variant { case normal, busy, empty, quiet }

    private func page(_ today: TodayStore, mode: TodayDayMode = .ribbon, tracking: Bool = true, partial: Bool = false, variant: Variant = .normal,
                      shown: TodayPage<EmptyView>.Shown? = nil) -> some View {
        var activity = variant == .busy ? busyActivity : self.activity
        activity.partial = partial
        if variant == .empty { activity.chats = []; activity.firstTurn = nil; activity.lastTurn = nil; activity.turnsByHour = Array(repeating: 0, count: 24); activity.repliesByHour = activity.turnsByHour; activity.questions = 0 }
        var rows = variant == .busy ? busyRows : variant == .empty ? [] : self.rows
        var queue = self.queue
        if variant == .quiet || variant == .empty {
            rows = rows.map { row in var row = row; if row.status == .needsYou { row.status = .toRead }; return row }
            queue = TodayQueue()
        }
        var dayActivity = activity
        if let shown {
            // The same day, a week earlier: every chat done, no queue.
            let shift = shown.day.timeIntervalSince(dayStart)
            dayActivity = shifted(activity, by: shift)
            rows = rows.map { row in var row = row; row.status = .idle; row.lastAt = row.lastAt.addingTimeInterval(shift); row.activeSince = nil; return row }
            queue = TodayQueue()
        }
        let tracked = shown?.tracked ?? readAtNow(today.tracked)
        let away = tracking && variant != .empty ? AgentAwayTime.summary(chats: dayActivity.chats, tracked: tracked, day: shown?.day ?? dayStart,
                                                                         now: shown == nil ? now : (shown?.day ?? dayStart).addingTimeInterval(86_399),
                                                                         partial: dayActivity.partial) : nil
        return TodayPage(today: today, activity: dayActivity, away: away, rows: rows, todos: shown == nil ? .init(done: 3, open: 5, added: 2) : nil,
                         waitingNow: queue.total, shippedState: .loaded(shipped), outcomes: outcomes, grouping: .constant(TodayGrouping.status.rawValue),
                         mode: .constant(mode.rawValue), shippedDetails: .constant(false), now: shown == nil ? now : nil, open: { _ in },
                         queue: queue, brief: shown == nil ? briefItems : [], yesterdayMerged: 3, shown: shown) { EmptyView() }
            .padding(.horizontal, 36).padding(.vertical, 28)
            .frame(maxWidth: 1240).frame(maxWidth: .infinity)
    }

    private func shifted(_ activity: DailyActivity, by shift: TimeInterval) -> DailyActivity {
        var day = activity
        day.day = activity.day.addingTimeInterval(shift)
        day.firstTurn = activity.firstTurn?.addingTimeInterval(shift)
        day.lastTurn = activity.lastTurn?.addingTimeInterval(shift)
        day.chats = activity.chats.map { chat in
            var chat = chat
            chat.lastAt = chat.lastAt.addingTimeInterval(shift)
            chat.active = chat.active?.map { DateInterval(start: $0.start.addingTimeInterval(shift), end: $0.end.addingTimeInterval(shift)) }
            return chat
        }
        return day
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

        for width in [935, 1015, 1215] {
            for dark in [true, false] {
                try render(page(today), width: CGFloat(width), dark: dark, to: out.appendingPathComponent("today-on-\(width)-\(dark ? "dark" : "light").png"))
            }
        }
        // Nothing waiting: the queue says so and the KPI has no amber dot.
        try render(page(today, variant: .quiet), width: 1015, dark: false, to: out.appendingPathComponent("today-quiet-1015-light.png"))
        try render(page(today, variant: .busy), width: 1215, dark: true, to: out.appendingPathComponent("today-busy-1215-dark.png"))
        try render(page(today, variant: .empty), width: 1015, dark: true, to: out.appendingPathComponent("today-empty-1015-dark.png"))
        try render(page(today, mode: .list), width: 1215, dark: true, to: out.appendingPathComponent("today-list-1215-dark.png"))
        // A partial scan: the totals read "about".
        try render(page(today, partial: true), width: 1215, dark: true, to: out.appendingPathComponent("today-partial-1215-dark.png"))
        // A past day: a week ago, its tracked day read from the same log.
        let pastDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: dayStart))
        let pastTracked = await today.tracker.day(pastDay)
        for (width, dark) in [(1015, true), (935, false)] {
            try render(page(today, shown: .init(day: pastDay, tracked: pastTracked)), width: CGFloat(width), dark: dark,
                       to: out.appendingPathComponent("today-past-\(width)-\(dark ? "dark" : "light").png"))
        }
        let off = try await store(spans: spans(), coverage: [span(at(10), now)], enabled: false)
        try render(page(off, tracking: false), width: 1015, dark: true, to: out.appendingPathComponent("today-off-1015-dark.png"))
        try render(page(off, tracking: false), width: 1215, dark: false, to: out.appendingPathComponent("today-off-1215-light.png"))
    }

    // MARK: A day like the owner's real one

    /// 15:45 on a day with 59 chats: short bursts (10 s to 5 min) between 10:18 and 15:44, one tracked
    /// block just after midnight, Brief questions answered earlier, nothing waiting now.
    func testRenderRealisticDaySnapshots() async throws {
        guard ProcessInfo.processInfo.environment["BURRO_TODAY_SNAPSHOTS"] == "1" else { throw XCTSkip("set BURRO_TODAY_SNAPSHOTS=1") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = ProcessInfo.processInfo.environment["BURRO_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("dist/screenshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let realNow = at(15, 45)
        let terminal = "com.apple.Terminal", xcode = "com.apple.dt.Xcode", arc = "company.thebrowser.Browser"
        let spans = [tracked(arc, at(0, 2), at(0, 30), "Late reading", "https://news.ycombinator.com"),
                     tracked(terminal, at(10, 15), at(11, 40), "claude"), tracked(xcode, at(11, 40), at(12, 30), "LanesView.swift"),
                     tracked(arc, at(12, 50), at(13, 20), "PR #88", "https://github.com/acme/burro/pull/88"),
                     tracked(terminal, at(13, 25), at(15, 44), "codex")]
        let today = try await store(spans: spans, coverage: [span(at(0), at(0, 35)), span(at(10, 10), realNow)])
        var tracked = today.tracked
        tracked?.coveredUntil = realNow

        // Deterministic bursts: chat i works in a few clusters of 10 s – 5 min bursts.
        var seed: UInt64 = 42
        func next(_ range: ClosedRange<Double>) -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return range.lowerBound + Double(seed >> 33) / Double(1 << 31) * (range.upperBound - range.lowerBound)
        }
        let titles = ["Lanes readability", "iOS resume hang", "Coin ledger audit", "Store screenshots", "Godot shader cache", "Refund alerts",
                      "Release notes 2.3", "Streak ladder", "Friends layout", "Support macros", "Onboarding copy", "Crash triage"]
        var chats: [DailyActivity.Chat] = [], rows: [TodayRow] = [], brief: [BriefItem] = []
        for index in 0..<59 {
            let id = String(format: "%@:real%02d", index % 3 == 0 ? "codex" : "claude", index)
            let untitled = index >= 44
            var active: [DateInterval] = []
            if untitled {
                let start = at(15, 43).addingTimeInterval(-next(0...4000))
                active = [DateInterval(start: start, duration: next(10...40))]
            } else {
                var cursor = at(10, 18).addingTimeInterval(next(0...(4 * 3600)))
                for _ in 0..<Int(next(1...3)) {
                    for _ in 0..<Int(next(3...18)) {
                        let length = next(10...300)
                        guard cursor.addingTimeInterval(length) < at(15, 44) else { break }
                        active.append(DateInterval(start: cursor, duration: length))
                        cursor = cursor.addingTimeInterval(length + next(20...200))
                    }
                    cursor = cursor.addingTimeInterval(next(900...3600))
                }
            }
            let title = untitled ? "Chat in focustown-release" : titles[index % titles.count] + (index >= titles.count ? " \(index / titles.count + 1)" : "")
            chats.append(DailyActivity.Chat(id: id, provider: id.hasPrefix("codex") ? .codex : .claude, folder: "/work/focustown", turns: untitled ? 1 : Int(next(2...14)),
                                            replies: 6, questions: 0, lastAt: active.last?.end ?? at(15, 44), title: untitled ? nil : title, active: active.isEmpty ? nil : active))
            let status: TodayRow.Status = index < 3 ? .working : index < 6 ? .toRead : .idle
            rows.append(TodayRow(id: id, title: title, provider: id.hasPrefix("codex") ? .codex : .claude, status: status,
                                 project: index % 4 == 0 ? "burro" : "focustown", breadcrumb: index % 4 == 0 ? "burro" : "focustown",
                                 lastAt: active.last?.end ?? at(15, 44), preview: nil, turns: 3, session: session(id, title, .working),
                                 activeSince: status == .working ? active.last?.start : nil))
            if index < 5 {
                var item = BriefItem(chatID: id, kind: .decision, headline: "Asked which branch", sourceHash: "h", createdAt: at(11 + index, 10))
                item.resolvedAt = at(11 + index, 30)
                brief.append(item)
            }
        }
        var turns = Array(repeating: 0, count: 24), replies = Array(repeating: 0, count: 24)
        for hour in 10...15 { turns[hour] = 12; replies[hour] = 40 }
        let activity = DailyActivity(day: dayStart, turnsByHour: turns, repliesByHour: replies, questions: 4, firstTurn: at(10, 18), lastTurn: at(15, 44),
                                     chats: chats, partial: false)
        let away = AgentAwayTime.summary(chats: chats, tracked: tracked, day: dayStart, now: realNow, partial: false)
        func page() -> some View {
            TodayPage(today: today, activity: activity, away: away, rows: rows, todos: .init(done: 1, open: 4, added: 1), waitingNow: 0,
                      shippedState: .loaded(shipped), grouping: .constant(TodayGrouping.status.rawValue), mode: .constant(TodayDayMode.ribbon.rawValue),
                      shippedDetails: .constant(false), now: realNow, open: { _ in }, brief: brief, yesterdayMerged: 2,
                      shown: .init(day: dayStart, tracked: tracked)) { EmptyView() }
                .padding(.horizontal, 36).padding(.vertical, 28)
                .frame(maxWidth: 1240).frame(maxWidth: .infinity)
        }
        for width in [1015, 1215] {
            for dark in [true, false] {
                try render(page(), width: CGFloat(width), dark: dark, to: out.appendingPathComponent("today-real-\(width)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func store(spans: [ActivitySpan], coverage: [DateInterval], enabled: Bool = true) async throws -> TodayStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-today-snapshot-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let log = ActivityLog(folder: folder)
        try log.append(spans)
        for interval in coverage { try log.recordCoverage(interval) }
        // The same day a week earlier, for the past-day render.
        let week = (calendar.date(byAdding: .day, value: -7, to: dayStart) ?? dayStart).timeIntervalSince(dayStart)
        try log.append(spans.map { span in var copy = span; copy.start = span.start.addingTimeInterval(week); copy.end = span.end.addingTimeInterval(week); return copy })
        for interval in coverage { try log.recordCoverage(DateInterval(start: interval.start.addingTimeInterval(week), end: interval.end.addingTimeInterval(week))) }
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
