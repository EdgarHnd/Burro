import XCTest
@testable import BurroCore

/// The Today timeline's blocks and focus stretches (ActivityTimeline).
final class ActivityTimelineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_150_000)
    private let xcode = "com.apple.dt.Xcode", arc = "company.thebrowser.Browser", slack = "com.tinyspeck.slackmacgap"
    private let mail = "com.apple.mail", spotify = "com.spotify.client", notes = "com.apple.Notes"
    private let names = ["com.apple.dt.Xcode": "Xcode", "company.thebrowser.Browser": "Arc", "com.tinyspeck.slackmacgap": "Slack",
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
}
