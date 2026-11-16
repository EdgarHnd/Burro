import XCTest
@testable import BurroCore

/// The agents' active stretches from the day scan, the time they worked while you were away, and
/// the day ribbon's geometry.
final class TodayAwayTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let since = 1_794_096_000.0 // 2026-11-13T00:00:00Z
    private var day: Date { Date(timeIntervalSince1970: since) }
    private func at(_ hour: Double, _ minute: Double = 0) -> Date { Date(timeIntervalSince1970: since + hour * 3600 + minute * 60) }
    private func span(_ from: Date, _ to: Date) -> DateInterval { DateInterval(start: from, end: to) }

    // MARK: The scan's answer

    private func request() -> DailyActivityRequest {
        DailyActivityRequest(codexRoots: ["/c"], claudeRoots: [], since: since, until: since + 86_400, now: since + 86_400, previews: false)
    }
    private func batch(active: String?) -> DailyActivityBatch? {
        let zeros = Array(repeating: "0", count: 24).joined(separator: ",")
        let field = active.map { #","active":\#($0)"# } ?? ""
        let json = """
        {"turnsByHour":[\(zeros)],"repliesByHour":[\(zeros)],"questions":0,"firstTurn":null,"lastTurn":null,
         "sessions":[{"provider":"codex","id":"01a1be01-5798-7cc1-9a11-57d9fc33c0da","cwd":"/work","turns":0,"replies":0,"questions":0,
                      "lastAt":\(Int(since) + 7200)\(field)}],"partial":false,"reads":1,"cacheHits":0,"visited":3}
        """
        return try? JSONDecoder().decode(DailyActivityBatch.self, from: Data(json.utf8))
    }

    func testActiveStretchesAreValidatedAndAbsentMeansUnknown() throws {
        let s = Int(since)
        let old = try XCTUnwrap(batch(active: nil))
        XCTAssertTrue(old.valid(for: request()))
        XCTAssertNil(old.sessions[0].active, "an older worker leaves the field out: unknown, not idle")
        XCTAssertTrue(try XCTUnwrap(batch(active: "[[\(s),\(s + 600)],[\(s + 1200),\(s + 1200)]]")).valid(for: request()))
        XCTAssertTrue(try XCTUnwrap(batch(active: "[]")).valid(for: request()))
        for bad in ["[[\(s - 1),\(s + 10)]]", "[[\(s),\(s + 86_401)]]", "[[\(s + 600),\(s)]]", "[[\(s),\(s + 600)],[\(s + 500),\(s + 900)]]",
                    "[[\(s)]]", "[[\(s + 900),\(s + 950)],[\(s),\(s + 10)]]"] {
            XCTAssertFalse(try XCTUnwrap(batch(active: bad)).valid(for: request()), bad)
        }
        let many = (0..<301).map { "[\(s + $0 * 10),\(s + $0 * 10 + 1)]" }.joined(separator: ",")
        XCTAssertFalse(try XCTUnwrap(batch(active: "[\(many)]")).valid(for: request()), "bounded like the worker")
    }

    // MARK: Away time

    func testAwayAgentTimeIsWallClockAgentTimeInsideAwayPeriods() {
        let away = [span(at(13, 30), at(16, 10)), span(at(20), at(21))]
        let agents = [
            [span(at(13), at(14)), span(at(15), at(15, 30))],   // 30 min + 30 min away
            [span(at(13, 45), at(14, 15)), span(at(20, 30), at(22))], // overlaps the first chat; 30 min more at 20:30
            [span(at(9), at(10))],                                 // while you were here
        ]
        let expected: TimeInterval = 105 * 60
        XCTAssertEqual(AgentAwayTime.awayAgentTime(agents: agents, away: away), expected, "13:30–14:15 once, 15:00–15:30, 20:30–21:00")
        XCTAssertEqual(AgentAwayTime.awayAgentTime(agents: [], away: away), 0)
        XCTAssertEqual(AgentAwayTime.awayAgentTime(agents: agents, away: []), 0)
    }

    private func tracked(_ spans: [(Date, Date)], coverage: [DateInterval]? = nil, now: Date? = nil) -> ActivityDay {
        let items = spans.map { ActivitySpan(ActivityPrivacy.key(bundleID: "com.apple.dt.Xcode", app: "Xcode", title: "Code", address: nil), start: $0.0, end: $0.1) }
        return ActivityDay.build(spans: items, rules: ActivityRules(), day: day, coverage: coverage, now: now, calendar: calendar)
    }

    func testPresenceBridgesShortGapsAndAwayIsEverythingElseOfFiveMinutesOrMore() {
        let day = tracked([(at(10), at(11)), (at(11, 4), at(12)), (at(12, 20), at(13))])
        XCTAssertEqual(AgentAwayTime.present(day), [span(at(10), at(12)), span(at(12, 20), at(13))], "a 4-minute gap is still you")
        let away = AgentAwayTime.away(present: AgentAwayTime.present(day), within: span(at(0), at(14)))
        XCTAssertEqual(away, [span(at(0), at(10)), span(at(12), at(12, 20)), span(at(13), at(14))])
        XCTAssertEqual(AgentAwayTime.away(present: [span(at(1), at(1, 58)), span(at(2, 2), at(3))], within: span(at(1), at(3))), [],
                       "under five minutes isn't away")
    }

    private func chat(_ id: String, _ active: [DateInterval]?) -> DailyActivity.Chat {
        DailyActivity.Chat(id: id, provider: id.hasPrefix("codex") ? .codex : .claude, folder: nil, turns: 1, replies: 1, questions: 0,
                           lastAt: at(10), active: active)
    }

    func testSummaryCountsOnlyRecordedTimeAwayUpToNowPerChat() throws {
        // Recording 9–14 and 15–18; you were there 9–12 and 16–18; now is 19.
        let day = tracked([(at(9), at(12)), (at(16), at(18))], coverage: [span(at(9), at(14)), span(at(15), at(18))], now: at(19))
        XCTAssertEqual(day.notRecorded, [span(at(0), at(9)), span(at(14), at(15)), span(at(18), at(19))])
        let chats = [chat("codex:a", [span(at(11), at(13)), span(at(18, 30), at(23))]), chat("claude:b", [span(at(12, 30), at(15))]),
                     chat("claude:c", nil)]
        let summary = try XCTUnwrap(AgentAwayTime.summary(chats: chats, tracked: day, day: day.day, now: at(19), calendar: calendar))
        // Away is 12–14 and 15–16: before 9, 14–15 and after 18 Burro wasn't recording, so nobody can say.
        XCTAssertEqual(summary.away, [span(at(12), at(14)), span(at(15), at(16))])
        // a: 12–13; b: 12:30–14. Wall clock: 12–14.
        XCTAssertEqual(summary.total, 2 * 3600)
        XCTAssertEqual(summary.chats.map(\.id), ["claude:b", "codex:a"], "longest first; a chat with unknown stretches is left out")
        XCTAssertEqual(summary.chats.map(\.seconds), [1.5 * 3600, 3600])
        XCTAssertEqual(summary.span, span(at(12), at(14)))
        XCTAssertTrue(summary.partial, "a chat's stretches are unknown, so the total is approximate")
        XCTAssertEqual(summary.totalText, "about 2h 0m")
        // Recording to the end of a past day: the evening after you left is away.
        let past = tracked([(at(9), at(12)), (at(16), at(18))], coverage: [span(at(9), at(14)), span(at(15), at(24))])
        let whole = try XCTUnwrap(AgentAwayTime.summary(chats: Array(chats.prefix(2)), tracked: past, day: past.day, now: at(30), calendar: calendar))
        XCTAssertEqual(whole.away, [span(at(12), at(14)), span(at(15), at(16)), span(at(18), at(24))])
        XCTAssertFalse(whole.partial)
        XCTAssertEqual(whole.totalText, "6h 30m")
        XCTAssertTrue(try XCTUnwrap(AgentAwayTime.summary(chats: Array(chats.prefix(2)), tracked: past, day: past.day, now: at(30), partial: true,
                                                          calendar: calendar)).partial, "a partial scan is carried")
    }

    func testANotRecordedStretchIsNeverAway() throws {
        // Recording all day but paused 13–15; you were there 9–12 and 16–17.
        let day = tracked([(at(9), at(12)), (at(16), at(17))], coverage: [span(at(0), at(13)), span(at(15), at(24))])
        let summary = try XCTUnwrap(AgentAwayTime.summary(chats: [chat("codex:a", [span(at(12), at(16))])], tracked: day, day: day.day,
                                                          now: at(30), calendar: calendar))
        XCTAssertEqual(summary.away, [span(at(0), at(9)), span(at(12), at(13)), span(at(15), at(16)), span(at(17), at(24))])
        XCTAssertEqual(summary.total, 2 * 3600, "12–13 and 15–16; the paused 13–15 isn't counted")
    }

    func testWithoutCoverageOnlyGapsBetweenTheFirstAndLastEntryCount() throws {
        let day = tracked([(at(9), at(10)), (at(11), at(12)), (at(14), at(15))])
        XCTAssertFalse(day.coverageKnown)
        let agents = chat("codex:a", [span(at(6), at(8)), span(at(10, 30), at(13)), span(at(16), at(20))])
        let summary = try XCTUnwrap(AgentAwayTime.summary(chats: [agents], tracked: day, day: day.day, now: at(22), calendar: calendar))
        XCTAssertEqual(summary.away, [span(at(10), at(11)), span(at(12), at(14))], "nothing before 9 or after 15")
        XCTAssertEqual(summary.total, 30 * 60 + 3600)
        XCTAssertEqual(AgentAwayTime.away(tracked: tracked([]), within: span(at(0), at(24))), [])
    }

    func testTrackingTurnedOnMidDayDoesntMakeTheMorningAway() throws {
        // Tracking turned on at 13:00 today (coverage starts then, no earlier spans); now is 18.
        let day = tracked([(at(13), at(14)), (at(16), at(17))], coverage: [span(at(13), at(18))], now: at(18))
        XCTAssertEqual(day.notRecorded, [span(at(0), at(13))])
        let summary = try XCTUnwrap(AgentAwayTime.summary(chats: [chat("claude:a", [span(at(8), at(15))])], tracked: day, day: day.day,
                                                          now: at(18), calendar: calendar))
        XCTAssertEqual(summary.away, [span(at(14), at(16)), span(at(17), at(18))])
        XCTAssertEqual(summary.total, 3600, "only 14–15; the agent's morning wasn't while you were away")
    }

    func testOnTheFirstDayWithCoverageTheEarlierPartCountsOnlyBetweenItsEntries() throws {
        // Spans from 6:00, but coverage only began at 10:00 that day.
        let day = tracked([(at(6), at(7)), (at(8), at(9)), (at(11), at(12))], coverage: [span(at(10), at(24))])
        XCTAssertEqual(day.coverageFrom, at(10))
        XCTAssertEqual(day.notRecorded, [])
        XCTAssertEqual(AgentAwayTime.away(tracked: day, within: span(at(0), at(24))), [span(at(7), at(8)), span(at(10), at(11)), span(at(12), at(24))],
                       "before 6 and 9–10 are unknown; 7–8 sits between two entries")
        XCTAssertNil(tracked([(at(11), at(12))], coverage: [span(at(10), at(24))]).coverageFrom, "no earlier spans: an ordinary day")
    }

    func testAwayEndsWhenTheTrackedDayWasRead() throws {
        let day = tracked([(at(9), at(12))], coverage: [span(at(0), at(15))], now: at(15))
        XCTAssertEqual(day.coveredUntil, at(15))
        let summary = try XCTUnwrap(AgentAwayTime.summary(chats: [chat("codex:a", [span(at(13), at(17))])], tracked: day, day: day.day,
                                                          now: at(17), calendar: calendar))
        XCTAssertEqual(summary.away, [span(at(0), at(9)), span(at(12), at(15))], "not up to the later now")
        XCTAssertEqual(summary.total, 2 * 3600)
    }

    func testSummaryMakesNoClaimWithoutTrackingOrStretches() {
        let chat = DailyActivity.Chat(id: "codex:a", provider: .codex, folder: nil, turns: 1, replies: 1, questions: 0, lastAt: at(10),
                                      active: [span(at(10), at(11))])
        var unknown = chat; unknown.active = nil
        let day = tracked([(at(9), at(10))])
        XCTAssertNil(AgentAwayTime.summary(chats: [chat], tracked: nil, day: day.day, now: at(12), calendar: calendar), "tracking off")
        XCTAssertNil(AgentAwayTime.summary(chats: [chat], tracked: tracked([]), day: day.day, now: at(12), calendar: calendar),
                     "nothing recorded and no coverage record")
        XCTAssertNil(AgentAwayTime.summary(chats: [unknown], tracked: day, day: day.day, now: at(12), calendar: calendar), "an older worker")
        XCTAssertEqual(AgentAwayTime.summary(chats: [], tracked: day, day: day.day, now: at(12), calendar: calendar)?.total, 0)
        let idleDay = tracked([], coverage: [span(at(0), at(12))], now: at(12))
        XCTAssertEqual(AgentAwayTime.summary(chats: [chat], tracked: idleDay, day: day.day, now: at(12), calendar: calendar)?.total, 3600,
                       "recording all morning with nothing tracked: all away")
    }

    func testRibbonTicksFollowTheWallClockOnDSTDays() throws {
        var paris = Calendar(identifier: .gregorian)
        paris.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        for (date, hours) in [(DateComponents(year: 2026, month: 3, day: 29), 23.0), (DateComponents(year: 2026, month: 10, day: 25), 25.0)] {
            let start = try XCTUnwrap(paris.date(from: date))
            let end = try XCTUnwrap(paris.date(byAdding: .day, value: 1, to: start))
            XCTAssertEqual(end.timeIntervalSince(start), hours * 3600)
            let layout = DayRibbonLayout(window: span(start, end), width: hours * 40)
            let ticks = layout.ticks(calendar: paris)
            XCTAssertEqual(ticks.compactMap(\.label), ["00", "03", "06", "09", "12", "15", "18", "21", "24"], "\(hours)-hour day")
            for tick in ticks.dropFirst().dropLast() {
                XCTAssertEqual(paris.component(.hour, from: tick.date) % 3, 0)
                XCTAssertEqual(tick.x, tick.date.timeIntervalSince(start) / 3600 * 40, accuracy: 0.001, "placed by elapsed time")
            }
        }
    }

    // MARK: Ribbon geometry

    func testRibbonPlacesTimeAcrossTheWidthWithAMinimumAndClamps() throws {
        let layout = DayRibbonLayout(window: span(at(0), at(24)), width: 960)
        XCTAssertEqual(layout.x(at(6)), 240)
        XCTAssertEqual(layout.x(at(-1)), 0)
        XCTAssertEqual(layout.x(at(25)), 960)
        XCTAssertEqual(layout.segment(span(at(12), at(13))), .init(x: 480, width: 40))
        XCTAssertEqual(layout.segment(span(at(12), at(12, 1))), .init(x: 480, width: 3), "a minute is still visible")
        XCTAssertEqual(layout.segment(span(at(23, 59.9), at(24)))?.maxX, 960, "kept inside at the right edge")
        XCTAssertEqual(layout.segment(span(at(-2), at(1))), .init(x: 0, width: 40), "clipped at the left")
        XCTAssertNil(layout.segment(span(at(25), at(26))))
        XCTAssertEqual(try XCTUnwrap(layout.nowX(at(21, 40))), 866.667, accuracy: 0.001)
        XCTAssertNil(layout.nowX(at(25)))
        XCTAssertNil(layout.nowX(nil))
    }

    func testRibbonTicksEveryThreeHoursForADayAndTenMinutesForAnHour() {
        let dayLayout = DayRibbonLayout(window: span(at(0), at(24)), width: 960)
        XCTAssertEqual(dayLayout.ticks(calendar: calendar).compactMap(\.label), ["00", "03", "06", "09", "12", "15", "18", "21", "24"])
        let nearNow = dayLayout.ticks(calendar: calendar, nowX: 850, clearance: 44)
        XCTAssertEqual(nearNow.first { $0.x == 840 }?.label, nil, "21 hides behind the now label")
        XCTAssertEqual(nearNow.filter { $0.label != nil }.count, 8)
        let zoom = DayRibbonLayout.zoomWindow(around: at(14, 25), day: span(at(0), at(24)), calendar: calendar)
        XCTAssertEqual(zoom, span(at(14), at(15)))
        let hour = DayRibbonLayout(window: zoom, width: 600)
        XCTAssertEqual(hour.ticks(calendar: calendar).compactMap(\.label), ["14:00", "14:10", "14:20", "14:30", "14:40", "14:50", "15:00"])
        XCTAssertEqual(DayRibbonLayout.zoomWindow(around: at(23, 30), day: span(at(0), at(24)), calendar: calendar), span(at(23), at(24)))
    }

    func testAgentRowsPackOnlyWhenTheyDontFit() {
        let layout = DayRibbonLayout(window: span(at(0), at(24)), width: 960)
        let chats = [[span(at(1), at(2))], [span(at(1, 30), at(3))], [span(at(5), at(6))], [span(at(1), at(1, 10))]]
        XCTAssertEqual(layout.rows(chats, maxRows: 8), [0, 1, 2, 3], "one row per chat while they fit")
        XCTAssertEqual(layout.rows(chats, maxRows: 2), [0, 1, 0, 1], "first row where it touches nothing, else the last")
    }

    func testAgentStretchSplitsWhereYouWereAway() {
        let pieces = DayRibbonLayout.split(span(at(13), at(17)), by: [span(at(13, 30), at(14)), span(at(16), at(20))])
        XCTAssertEqual(pieces.map(\.interval), [span(at(13), at(13, 30)), span(at(13, 30), at(14)), span(at(14), at(16)), span(at(16), at(17))])
        XCTAssertEqual(pieces.map(\.away), [false, true, false, true])
        XCTAssertEqual(DayRibbonLayout.split(span(at(9), at(9)), by: []).map(\.away), [false], "a lone event still draws")
    }

    // MARK: Day caches

    func testAPastDayScannedBeforeItEndedIsScannedAgain() {
        let due = { (taken: Date, now: Date) in DayScanCache.due(takenAt: taken, day: self.day, now: now, maxAge: 60, calendar: self.calendar) }
        XCTAssertFalse(due(at(10), at(10, 0.5)), "today: fresh")
        XCTAssertTrue(due(at(10), at(10, 2)), "today: over a minute old")
        XCTAssertTrue(due(at(23, 58), at(30)), "yesterday scanned at 23:58 is redone")
        XCTAssertTrue(due(at(24, 3), at(30)), "scanned 3 minutes after midnight: still settling")
        XCTAssertFalse(due(at(24, 6), at(30)), "scanned after the day ended plus 5 minutes: final")
        XCTAssertFalse(due(at(23, 58), at(23, 58.5)), "not redone on every refresh")
    }

    func testCachesKeepTodayTheShownDayAndFiveMoreRecentlyUsed() {
        let days = (0..<9).map { at(Double($0) * -24) }
        let used = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($1, $0) }) // later index: used more recently
        let drop = DayScanCache.evictions(used: used, keep: [days[0], days[1]])
        XCTAssertEqual(Set(drop), [days[2], days[3]], "today and the shown day stay whatever their use; then the five most recent")
        XCTAssertEqual(DayScanCache.evictions(used: Dictionary(uniqueKeysWithValues: days.prefix(6).map { ($0, 1) }), keep: [days[0]]), [])
    }
}
