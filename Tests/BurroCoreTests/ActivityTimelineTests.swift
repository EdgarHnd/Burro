import XCTest
@testable import BurroCore

/// The Today timeline's blocks and focus stretches (ActivityTimeline).
final class ActivityTimelineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_150_000)
    private let xcode = "com.apple.dt.Xcode", arc = "company.thebrowser.Browser", slack = "com.tinyspeck.slackmacgap"
    private let mail = "com.apple.mail", spotify = "com.spotify.client", notes = "com.apple.Notes"
    private let claude = "com.anthropic.claudefordesktop"
    private let names = ["com.anthropic.claudefordesktop": "Claude", "com.apple.loginwindow": "loginwindow", "com.apple.dt.Xcode": "Xcode", "company.thebrowser.Browser": "Arc", "com.tinyspeck.slackmacgap": "Slack",
                         "com.apple.mail": "Mail", "com.spotify.client": "Spotify", "com.apple.Notes": "Notes", "com.apple.MobileSMS": "Messages"]

    /// (bundle, from minute, to minute, title, address)
    private typealias Item = (String, Double, Double, String?, String?)
    private func categorized(_ items: [Item]) -> [(span: ActivitySpan, category: ActivityCategory)] {
        items.map { bundle, from, to, title, address in
            let key = ActivityPrivacy.key(bundleID: bundle, app: names[bundle] ?? bundle, title: title, address: address)
            let span = ActivitySpan(key, start: t0.addingTimeInterval(from * 60), end: t0.addingTimeInterval(to * 60))
            return (span, ActivityRules().category(bundleID: span.bundleID, host: span.host, title: span.title, isPrivate: span.isPrivate))
        }
    }
    private func blocks(_ items: [Item]) -> [ActivityBlock] { ActivityTimeline.blocks(categorized(items)) }
    private func minutes(_ block: ActivityBlock) -> [Double] {
        [block.start.timeIntervalSince(t0) / 60, block.end.timeIntervalSince(t0) / 60]
    }

    func testOneCategoryJoinsAcrossShortGapsAndIdleStaysEmpty() {
        let result = blocks([
            (xcode, 0, 30, "ActivityLog.swift", nil),
            (xcode, 34, 50, "ActivityLog.swift", nil),          // 4-minute gap: same block
            (xcode, 50, 60, "ActivitySummary.swift", nil),
            (xcode, 66, 90, "ActivitySummary.swift", nil),      // 6-minute gap: idle, a new block
        ])
        XCTAssertEqual(result.map(minutes), [[0, 60], [66, 90]])
        XCTAssertEqual(result[0].title, "Xcode · ActivityLog.swift", "the most-seen title names the block")
        XCTAssertEqual(result[0].seconds, 56 * 60, "the short idle gap isn't counted as time")
        XCTAssertEqual(result[0].main?.bundleID, xcode)
        XCTAssertEqual(result[1].title, "Xcode · ActivitySummary.swift")
    }

    func testBrowserBlocksNameTheSiteAndKeepThePageTitleAsDetail() {
        let result = blocks([
            (arc, 0, 20, "Pull request #12 · burro", "https://github.com/acme/burro/pull/12"),
            (arc, 20, 25, "Issues", "https://github.com/acme/burro/issues"),
            (arc, 25, 30, "Some answer", "https://stackoverflow.com/q/1"),
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].category, .build)
        XCTAssertEqual(result[0].title, "Arc · github.com")
        XCTAssertEqual(result[0].host, "github.com")
        XCTAssertEqual(result[0].detail, "Pull request #12 · burro")
        let www = blocks([(arc, 0, 10, nil, "https://www.youtube.com/watch?v=1")])[0]
        XCTAssertEqual(www.title, "Arc · youtube.com", "the title drops www.")
        XCTAssertEqual(www.host, "www.youtube.com", "the host stays as stored for right-click rules")
    }

    func testNoMainAppReadsAsSwitching() {
        // Three comms apps, none above 60%.
        let comms = blocks([(slack, 0, 10, "general", nil), (mail, 10, 18, "Inbox", nil), ("com.apple.MobileSMS", 18, 25, nil, nil)])
        XCTAssertEqual(comms.count, 1)
        XCTAssertEqual(comms[0].title, "Switching between Slack, Mail and Messages")
        XCTAssertNil(comms[0].main)
        XCTAssertNil(comms[0].host)
        // Flicking between apps of different categories, each run under two minutes, folds into one switching block.
        var flicks: [Item] = []
        for i in 0..<9 { flicks.append(([xcode, arc, slack][i % 3], Double(i) * 1.5, Double(i + 1) * 1.5, nil, nil)) }
        let switching = blocks(flicks)
        XCTAssertEqual(switching.count, 1)
        XCTAssertEqual(minutes(switching[0]), [0, 13.5])
        XCTAssertTrue(switching[0].title.hasPrefix("Switching between "), switching[0].title)
        XCTAssertEqual(Set(switching[0].apps.map(\.name)), ["Xcode", "Arc", "Slack"])
        XCTAssertEqual(switching[0].category, .build, "equal time: the earlier category in ActivityCategory wins")
        // Two apps read "A and B".
        XCTAssertEqual(blocks([(slack, 0, 10, nil, nil), (mail, 10, 18, nil, nil)])[0].title, "Switching between Slack and Mail")
    }

    func testShortRunsFoldIntoTheLongerNeighbour() {
        // A one-minute Slack check inside Xcode work disappears into one Build block.
        let inside = blocks([(xcode, 0, 20, "A.swift", nil), (slack, 20, 21, nil, nil), (xcode, 21, 41, "A.swift", nil)])
        XCTAssertEqual(inside.map(minutes), [[0, 41]])
        XCTAssertEqual(inside[0].category, .build)
        XCTAssertEqual(inside[0].title, "Xcode · A.swift")
        // Between two categories it joins the longer one.
        let between = blocks([(xcode, 0, 20, nil, nil), (slack, 20, 21, nil, nil), (notes, 21, 31, nil, nil)])
        XCTAssertEqual(between.map(minutes), [[0, 21], [21, 31]])
        XCTAssertEqual(between.map(\.category), [.build, .docs])
        // Alone between idle gaps it stays: there's nothing to fold into.
        let alone = blocks([(xcode, 0, 20, nil, nil), (slack, 30, 31, nil, nil), (xcode, 40, 60, nil, nil)])
        XCTAssertEqual(alone.map(\.category), [.build, .comms, .build])
    }

    func testPrivateBlocksNeverShowTitlesOrSitesAndNeverFold() {
        let result = blocks([
            (xcode, 0, 20, "A.swift", nil),
            (arc, 20, 21, "Account overview", "https://www.chase.com/accounts"),   // one minute on a bank
            (xcode, 21, 40, "A.swift", nil),
        ])
        XCTAssertEqual(result.map(\.category), [.build, .private, .build], "private time is never absorbed")
        XCTAssertEqual(result[1].title, "Private · Arc")
        XCTAssertNil(result[1].detail)
        XCTAssertNil(result[1].host)
        for block in result { XCTAssertFalse(block.title.contains("chase") || block.title.contains("Account"), block.title) }
        // A short run next to a Private block doesn't fold into it either.
        let next = blocks([(arc, 0, 20, nil, "https://chase.com"), (slack, 20, 21, nil, nil)])
        XCTAssertEqual(next.map(\.category), [.private, .comms])
    }

    func testFocusStretchesAllowShortInterruptions() {
        let focus = ActivityTimeline.focus(categorized([
            (xcode, 0, 50, nil, nil),
            (spotify, 50, 51.5, nil, nil),          // 90 s of Break: same stretch
            (xcode, 51.5, 90, nil, nil),
            (xcode, 91, 120, nil, nil),             // 60 s idle: same stretch
            (spotify, 120, 135, nil, nil),          // 15 min Break: ends it
            (slack, 135, 150, nil, nil),
            (arc, 153, 170, nil, "https://chase.com"), // 3 min idle: a new stretch; Private counts as focus
        ]))
        let at = { (minute: Double) in self.t0.addingTimeInterval(minute * 60) }
        XCTAssertEqual(focus.stretches, [DateInterval(start: at(0), end: at(120)), DateInterval(start: at(135), end: at(150)),
                                         DateInterval(start: at(153), end: at(170))])
        XCTAssertEqual(focus.longest, DateInterval(start: at(0), end: at(120)))
        XCTAssertNil(ActivityTimeline.focus(categorized([(spotify, 0, 30, nil, nil)])).longest, "Break alone is no focus")
    }

    func testDayCarriesBlocksAndFocus() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let spans = categorized([(xcode, 60, 120, "A.swift", nil), (spotify, 120, 130, nil, nil)]).map(\.span)
        let day = ActivityDay.build(spans: spans, rules: ActivityRules(), day: t0, calendar: calendar)
        XCTAssertEqual(day.blocks.map(\.category), [.build, .break])
        XCTAssertEqual(day.focus.longest?.duration, 3600)
    }

    // MARK: Readability

    func testShortAlternatingRunsReadAsOneSwitchingBlock() {
        // Claude and Arc, 3 to 6 minutes each, for half an hour: one block, not eight.
        var items: [Item] = [], minute = 0.0
        for (index, length) in [4.0, 3, 6, 5, 3, 4, 6, 3].enumerated() {
            items.append(index % 2 == 0 ? (claude, minute, minute + length, "Claude", nil)
                                        : (arc, minute, minute + length, "Overview - Focus town", "https://example.org/pomodoro"))
            minute += length
        }
        let result = blocks(items)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].title, "Switching between Claude and Arc")
        XCTAssertEqual(minutes(result[0]), [0, 34])
        // A long run of one app stays its own block beside it.
        let withWork = blocks(items + [(xcode, 34, 80, "A.swift", nil)])
        XCTAssertEqual(withWork.map(\.title), ["Switching between Claude and Arc", "Xcode · A.swift"])
        // Two short runs aren't a switching stretch; the shorter one folds into the other.
        let pair = blocks([(claude, 0, 7, nil, nil), (arc, 7, 11, nil, "https://example.org")])
        XCTAssertEqual(pair.count, 1)
        XCTAssertEqual(pair[0].title, "Claude")
    }

    func testRunsUnderFiveMinutesFold() {
        let result = blocks([(xcode, 0, 20, "A.swift", nil), (slack, 20, 24.5, nil, nil), (xcode, 24.5, 50, "A.swift", nil)])
        XCTAssertEqual(result.map(minutes), [[0, 50]])
        XCTAssertEqual(result[0].title, "Xcode · A.swift")
    }

    func testTitlesNeverRepeatTheApp() {
        XCTAssertEqual(blocks([(claude, 0, 20, "Claude", nil)])[0].title, "Claude")
        XCTAssertEqual(blocks([(slack, 0, 20, "burro - Slack", nil)])[0].title, "Slack · burro")
        XCTAssertEqual(blocks([(slack, 0, 20, "burro — Slack", nil)])[0].title, "Slack · burro")
        XCTAssertEqual(blocks([(xcode, 0, 20, "Slack - notes.swift", nil)])[0].title, "Xcode · Slack - notes.swift", "only the app's own name")
        XCTAssertEqual(ActivityTimeline.displayTitle("Claude - Claude", app: "Claude"), nil)
        XCTAssertEqual(ActivityTimeline.displayTitle("  ", app: "Claude"), nil)
    }

    func testSubMinuteBlocksAndRowsAreHidden() throws {
        // A 40-second Private blip between idle gaps is no block, but its time still counts.
        let result = blocks([(xcode, 0, 20, nil, nil), (arc, 30, 30 + 40 / 60, nil, "https://chase.com"), (xcode, 40, 60, nil, nil)])
        XCTAssertEqual(result.map(\.category), [.build, .build])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let spans = categorized([(xcode, 60, 120, nil, nil), (arc, 125, 125.5, nil, "https://usecharming.com"),
                                 (spotify, 130, 130.4, nil, nil)]).map(\.span)
        let day = ActivityDay.build(spans: spans, rules: ActivityRules(), day: t0, calendar: calendar)
        XCTAssertEqual(day.apps.map(\.name), ["Xcode"], "apps under a minute aren't listed")
        XCTAssertEqual(day.sites, [], "no 0m site rows")
        XCTAssertEqual(day.total, 3600 + 30 + 24, "but their time counts")
        let legend = day.legend(limit: 6)
        XCTAssertEqual(legend.shown.map(\.category), [.build])
        XCTAssertNil(legend.more, "no N more line for under a minute")
        XCTAssertEqual(day.legend(limit: 0).more?.count, 3)
    }

    func testLockScreenIsNotActivity() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let loginwindow = "com.apple.loginwindow"
        let spans = categorized([(loginwindow, 0, 0, nil, nil), (loginwindow, 10, 12, nil, nil), (xcode, 60, 120, "A.swift", nil),
                                 ("com.apple.ScreenSaver.Engine", 120, 150, nil, nil)]).map(\.span)
        let day = ActivityDay.build(spans: spans, rules: ActivityRules(), day: t0, calendar: calendar)
        XCTAssertEqual(day.blocks.map(\.title), ["Xcode · A.swift"])
        XCTAssertEqual(day.total, 3600)
        XCTAssertEqual(day.apps.map(\.name), ["Xcode"])
        XCTAssertFalse(day.categories.contains { $0.category == .private })
        XCTAssertTrue(ActivityPrivacy.isSystemScreen(loginwindow))
        XCTAssertFalse(ActivityPrivacy.isSystemScreen(xcode))
    }

    func testLayoutStartsAtTheFirstHourAndCollapsesLongIdle() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        // The first block starts at :58, like a day that begins at 10:58.
        let hour = calendar.dateInterval(of: .hour, for: t0)!.start
        let base = hour.addingTimeInterval(3600 * 2)            // a whole hour
        let rel = { (minute: Double) in base.timeIntervalSince(self.t0) / 60 + minute }
        let day = blocks([(xcode, rel(58), rel(118), nil, nil), (xcode, rel(130), rel(160), nil, nil),     // 12-minute gap: drawn to scale
                          (slack, rel(290), rel(320), nil, nil)])                                       // 2h10m idle: collapsed
        XCTAssertEqual(day.count, 3)
        let now = base.addingTimeInterval(330 * 60)
        let layout = ActivityTimelineLayout(blocks: day, now: now, hourHeight: 60, minHeight: 20, idleHeight: 30, calendar: calendar)
        XCTAssertEqual(layout.marks.first?.date, base, "starts at the first block's hour, not earlier")
        XCTAssertEqual(layout.placed[0].y, 58, accuracy: 0.01)
        XCTAssertEqual(layout.placed[1].y - (layout.placed[0].y + layout.placed[0].height), 12, accuracy: 0.01, "short gaps keep their length")
        XCTAssertEqual(layout.idle.count, 1)
        XCTAssertEqual(layout.idle[0].duration, 130 * 60)
        XCTAssertEqual(layout.placed[2].y, layout.idle[0].y + 30, accuracy: 0.01, "the idle gap is one thin divider")
        XCTAssertFalse(layout.marks.contains { $0.date > layout.idle[0].start && $0.date < layout.idle[0].end }, "no hour lines inside it")
        XCTAssertEqual(layout.height, layout.placed[2].y + layout.placed[2].height + 10, accuracy: 0.01, "ends at now, not the next hour")
        XCTAssertEqual(try XCTUnwrap(layout.nowY), layout.height, accuracy: 0.01)
        // An hour idle since the last block collapses too.
        let late = ActivityTimelineLayout(blocks: day, now: base.addingTimeInterval(420 * 60), hourHeight: 60, minHeight: 20, calendar: calendar)
        XCTAssertEqual(late.idle.count, 2)
        XCTAssertEqual(late.height, late.placed[2].y + late.placed[2].height + 30, accuracy: 0.01)
    }
}
