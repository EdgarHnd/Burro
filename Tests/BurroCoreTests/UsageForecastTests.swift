import XCTest
@testable import BurroCore

final class UsageForecastTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }
    /// Monday 16 November 2026, 08:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_794_816_000)
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86400

    private func forecast(left: Double?, elapsed: TimeInterval?, duration: TimeInterval?, stale: Bool = false) -> UsageForecast {
        let resetsAt = duration.flatMap { duration in elapsed.map { now.addingTimeInterval(duration - $0) } }
        return UsageForecast(left: left, resetsAt: resetsAt, duration: duration, now: now, stale: stale)
    }

    func testTheDateIsAMondayMorning() {
        XCTAssertEqual(calendar.component(.weekday, from: now), 2)
        XCTAssertEqual(calendar.component(.hour, from: now), 8)
    }

    // MARK: Forecast

    func testEvenPaceTickIsTheShareOfTimeStillToGo() {
        let session = forecast(left: 58, elapsed: 3 * hour, duration: 5 * hour)
        XCTAssertEqual(try XCTUnwrap(session.evenPaceLeft), 40, accuracy: 0.001)
        let weekly = forecast(left: 41, elapsed: 5 * day, duration: 7 * day)
        XCTAssertEqual(try XCTUnwrap(weekly.evenPaceLeft), 100.0 * 2.0 / 7.0, accuracy: 0.001)
    }

    func testRunOutTimeExtendsTheRateSoFar() {
        // 40% used in 2 days is 20% a day; 60% left lasts 3 more days, the reset is 5 days away.
        let weekly = forecast(left: 60, elapsed: 2 * day, duration: 7 * day)
        XCTAssertEqual(weekly.outcome, .runsOut(now.addingTimeInterval(3 * day)))
        XCTAssertTrue(weekly.isShort)
        XCTAssertEqual(UsageClock.forecast(weekly, now: now, calendar: calendar), "At this pace: runs out Thu 08:00")
    }

    func testFineUntilResetWhenThePaceLastsPastTheReset() {
        // 30% in 2 hours is 15% an hour; 70% lasts 4h 40m, the reset is 3 hours away.
        let session = forecast(left: 70, elapsed: 2 * hour, duration: 5 * hour)
        XCTAssertEqual(session.outcome, .fineUntilReset)
        XCTAssertFalse(session.isShort)
        XCTAssertEqual(UsageClock.forecast(session, now: now, calendar: calendar), "At this pace: fine until reset")
        // Nothing used at all also lasts.
        XCTAssertEqual(forecast(left: 100, elapsed: 4 * hour, duration: 5 * hour).outcome, .fineUntilReset)
    }

    func testUnknownWindowStartGivesNoGuess() {
        let noLength = UsageForecast(left: 50, resetsAt: now.addingTimeInterval(hour), duration: nil, now: now)
        XCTAssertEqual(noLength.outcome, .unknown)
        XCTAssertNil(noLength.evenPaceLeft)
        XCTAssertEqual(UsageClock.forecast(noLength, now: now, calendar: calendar), "—")
        let noReset = UsageForecast(left: 50, resetsAt: nil, duration: 5 * hour, now: now)
        XCTAssertEqual(noReset.outcome, .unknown)
        XCTAssertNil(noReset.evenPaceLeft)
        let noPercent = forecast(left: nil, elapsed: hour, duration: 5 * hour)
        XCTAssertEqual(noPercent.outcome, .unknown)
        XCTAssertNil(noPercent.left)
        // A reset further away than the window is long doesn't fit together.
        let inconsistent = UsageForecast(left: 50, resetsAt: now.addingTimeInterval(9 * hour), duration: 5 * hour, now: now)
        XCTAssertEqual(inconsistent.outcome, .unknown)
        XCTAssertNil(inconsistent.evenPaceLeft)
    }

    func testAWindowAlreadyUsedUp() {
        let weekly = forecast(left: 0, elapsed: 6 * day, duration: 7 * day)
        XCTAssertEqual(weekly.outcome, .usedUp)
        XCTAssertNotNil(weekly.evenPaceLeft)
        XCTAssertEqual(UsageClock.forecast(weekly, now: now, calendar: calendar), "Used up until reset")
        // Used up even when the window's start is unknown, and below-zero readings clamp.
        let unknownStart = UsageForecast(left: -3, resetsAt: nil, duration: nil, now: now)
        XCTAssertEqual(unknownStart.outcome, .usedUp)
        XCTAssertEqual(unknownStart.left, 0)
    }

    func testJustResetWindowsDoNotExtendANaiveRate() {
        // 5% in the first 5 minutes would "run out" in 95 minutes; it's too early to tell.
        let session = forecast(left: 95, elapsed: 5 * 60, duration: 5 * hour)
        XCTAssertEqual(session.outcome, .tooEarly)
        XCTAssertEqual(UsageClock.forecast(session, now: now, calendar: calendar), "Just reset: too early to tell")
        // A weekly window three hours in (under 5% of a week) is still too early.
        XCTAssertEqual(forecast(left: 96, elapsed: 3 * hour, duration: 7 * day).outcome, .tooEarly)
        // Nine hours in, the same 4% reads as a pace that lasts.
        XCTAssertEqual(forecast(left: 96, elapsed: 9 * hour, duration: 7 * day).outcome, .fineUntilReset)
        // The short window's floor is 30 minutes.
        XCTAssertEqual(forecast(left: 95, elapsed: 29 * 60, duration: 5 * hour).outcome, .tooEarly)
        XCTAssertEqual(forecast(left: 95, elapsed: 31 * 60, duration: 5 * hour).outcome, .fineUntilReset)
    }

    func testStaleAndAwaitingResetGiveNoGuess() {
        let stale = forecast(left: 5, elapsed: 4 * hour, duration: 5 * hour, stale: true)
        XCTAssertEqual(stale.outcome, .stale)
        XCTAssertNil(stale.evenPaceLeft)
        let past = UsageForecast(left: 0, resetsAt: now.addingTimeInterval(-60), duration: 5 * hour, now: now)
        XCTAssertEqual(past.outcome, .awaitingReset)
        XCTAssertEqual(UsageClock.forecast(past, now: now, calendar: calendar), "—")
    }

    // MARK: Alert rule

    func testLowWindowRule() {
        XCTAssertTrue(UsageAlert.isLow(forecast(left: 0, elapsed: day, duration: 7 * day), now: now), "used up")
        // 12% left half a day into a week, burning 7% an hour: runs out within three hours.
        XCTAssertTrue(UsageAlert.isLow(forecast(left: 12, elapsed: 12 * hour, duration: 7 * day), now: now), "runs out within 3h")
        // Codex weekly 33% running out in days is shown on its meter but doesn't lead the page.
        let days = forecast(left: 33, elapsed: 4 * day, duration: 7 * day)
        guard case .runsOut = days.outcome else { return XCTFail("expected a run-out, got \(days.outcome)") }
        XCTAssertFalse(UsageAlert.isLow(days, now: now))
        XCTAssertTrue(UsageAlert.isLow(forecast(left: 9, elapsed: 4 * day, duration: 7 * day), now: now), "10% or less and running out")
        XCTAssertFalse(UsageAlert.isLow(forecast(left: 8, elapsed: 6.95 * day, duration: 7 * day), now: now), "8% that lasts to the reset")
        XCTAssertTrue(UsageAlert.isLow(forecast(left: 8, elapsed: 10 * 60, duration: 5 * hour), now: now), "low and just reset")
        XCTAssertTrue(UsageAlert.isLow(UsageForecast(left: 8, resetsAt: nil, duration: nil, now: now), now: now), "low, start unknown")
        XCTAssertFalse(UsageAlert.isLow(forecast(left: 2, elapsed: 4 * hour, duration: 5 * hour, stale: true), now: now), "stale")
        XCTAssertFalse(UsageAlert.isLow(UsageForecast(left: 0, resetsAt: now.addingTimeInterval(-60), duration: hour, now: now), now: now),
                       "awaiting the refill")
        XCTAssertFalse(UsageAlert.isLow(UsageForecast(left: nil, resetsAt: nil, duration: nil, now: now), now: now), "unknown percentage")
    }

    private func window(_ id: String, _ title: String, left: Double, elapsed: TimeInterval, duration: TimeInterval, model: String? = nil) -> UsageWindow {
        UsageWindow(id: id, title: title, remainingPercent: left, resetsAt: now.addingTimeInterval(duration - elapsed), duration: duration, model: model)
    }

    func testAlertsAreOrderedByUrgencyAndSkipStaleOrLoadingProviders() {
        let claude = ProviderUsage(id: .claude, updatedAt: now, windows: [
            window("session", "Session", left: 58, elapsed: 3 * hour, duration: 5 * hour),
            window("weekly-model:fable", "Fable weekly", left: 6, elapsed: 3 * day, duration: 7 * day, model: "Fable"),
            window("weekly", "Weekly", left: 9, elapsed: 2 * day, duration: 7 * day),
        ])
        let codex = ProviderUsage(id: .codex, updatedAt: now, windows: [window("codex:primary", "5 hours", left: 0, elapsed: hour, duration: 5 * hour)])
        let staleGrok = ProviderUsage(id: .grok, updatedAt: now.addingTimeInterval(-3600), windows: [
            window("grok", "Weekly credits", left: 1, elapsed: day, duration: 7 * day)])
        var loading = ProviderUsage.loading(.codex); loading.windows = codex.windows

        let alerts = UsageAlert.alerts([claude, codex, staleGrok], now: now)
        XCTAssertEqual(alerts.map(\.title), ["Codex 5 hours", "Claude Fable weekly", "Claude weekly"])
        XCTAssertEqual(alerts[1].model, "Fable")
        XCTAssertEqual(UsageAlert.alerts([claude], now: now, modelLimits: false).map(\.windowID), ["weekly"])
        XCTAssertTrue(UsageAlert.alerts([loading], now: now).isEmpty)
    }

    // MARK: Words

    func testMomentsSpansAndResets() {
        XCTAssertEqual(UsageClock.moment(now.addingTimeInterval(2 * hour + 40 * 60), now: now, calendar: calendar), "today 10:40")
        XCTAssertEqual(UsageClock.moment(now.addingTimeInterval(day + hour), now: now, calendar: calendar), "tomorrow 09:00")
        XCTAssertEqual(UsageClock.moment(now.addingTimeInterval(3 * day + 6 * hour), now: now, calendar: calendar), "Thu 14:00")
        XCTAssertEqual(UsageClock.moment(now.addingTimeInterval(10 * day), now: now, calendar: calendar), "26 Nov 08:00")
        XCTAssertEqual(UsageClock.span(45 * 60), "45m")
        XCTAssertEqual(UsageClock.span(2 * hour + 5 * 60), "2h 05m")
        XCTAssertEqual(UsageClock.span(day + 4 * hour), "1d 4h")
        XCTAssertEqual(UsageClock.span(5 * day + hour), "5d")
        XCTAssertEqual(UsageClock.reset(now.addingTimeInterval(2 * hour + 10 * 60), duration: 5 * hour, now: now, calendar: calendar),
                       "Resets in 2h 10m")
        XCTAssertEqual(UsageClock.reset(now.addingTimeInterval(day + hour), duration: 7 * day, now: now, calendar: calendar),
                       "Resets tomorrow 09:00 · 1d 1h")
        XCTAssertEqual(UsageClock.reset(nil, duration: 7 * day, now: now, calendar: calendar), "Reset time unavailable")
        XCTAssertEqual(UsageClock.reset(now.addingTimeInterval(-1), duration: 7 * day, now: now, calendar: calendar), "Awaiting reset update")
    }

    func testHeadlineHedgesEveryGuess() {
        let runs = forecast(left: 6, elapsed: 3 * day, duration: 7 * day)
        let fine = forecast(left: 70, elapsed: 2 * hour, duration: 5 * hour)
        let later = forecast(left: 33, elapsed: 4 * day, duration: 7 * day)
        let used = forecast(left: 0, elapsed: hour, duration: 5 * hour)
        let unknown = UsageForecast(left: 50, resetsAt: nil, duration: nil, now: now)
        guard case .runsOut(let first) = runs.outcome, case .runsOut(let second) = later.outcome else { return XCTFail("expected run-outs") }
        XCTAssertLessThan(first, second)
        let sentence = UsageClock.headline([("Codex weekly", later), ("Claude session", fine), ("Claude Fable weekly", runs)], now: now, calendar: calendar)
        XCTAssertEqual(sentence, "At this pace Claude Fable weekly runs out \(UsageClock.moment(first, now: now, calendar: calendar)) and Codex weekly runs out \(UsageClock.moment(second, now: now, calendar: calendar)).")
        XCTAssertEqual(UsageClock.headline([("Claude session", fine)], now: now, calendar: calendar), "At this pace every limit lasts until it resets.")
        XCTAssertEqual(UsageClock.headline([("Claude session", fine), ("Codex 5 hours", fine)], now: now, calendar: calendar),
                       "At this pace every limit lasts until it resets.")
        // One window known to be fine, the others unknown, too early or stale: only the known one is named.
        let early = forecast(left: 99, elapsed: 60, duration: 5 * hour)
        let stale = UsageForecast(left: 50, resetsAt: now.addingTimeInterval(hour), duration: 5 * hour, now: now, stale: true)
        XCTAssertEqual(early.outcome, .tooEarly)
        XCTAssertEqual(UsageClock.headline([("Claude session", fine), ("Grok", unknown), ("Codex 5 hours", early), ("Codex weekly", stale)],
                                           now: now, calendar: calendar),
                       "At this pace Claude session lasts until it resets.")
        XCTAssertEqual(UsageClock.headline([("Claude session", fine), ("Codex 5 hours", fine), ("Grok", unknown)], now: now, calendar: calendar),
                       "At this pace Claude session and Codex 5 hours last until they reset.")
        XCTAssertEqual(UsageClock.headline([("Codex 5 hours", used)], now: now, calendar: calendar), "Codex 5 hours is used up.")
        XCTAssertNil(UsageClock.headline([("Grok", unknown)], now: now, calendar: calendar))
        XCTAssertEqual(UsageAlert.title(.claude, "Fable weekly"), "Claude Fable weekly")
        XCTAssertEqual(UsageAlert.title(.codex, "Weekly"), "Codex weekly")
        XCTAssertEqual(UsageAlert.title(.codex, "5 hours"), "Codex 5 hours")
    }

    // MARK: Week and breakdown

    private func bucket(_ date: Date, _ model: String, input: Double, output: Double = 0, records: Int = 1) -> UsageLogBucket {
        UsageLogBucket(date: date.timeIntervalSince1970, model: model, input: input, cached: 0, cacheWrite: 0, cacheWriteHour: 0,
                       output: output, recordCount: records)
    }

    func testWeekFillsEmptyDaysAndSplitsTodayByModel() throws {
        let today = calendar.startOfDay(for: now)
        let twoDaysAgo = today.addingTimeInterval(-2 * day)
        let claude: [UsageLogBucket] = [
            bucket(today, "claude-opus-5-5", input: 2_000_000, records: 3),
            bucket(today, "mystery-model", input: 500_000),
            bucket(twoDaysAgo, "claude-opus-5-5", input: 2_000_000),
            bucket(today.addingTimeInterval(-20 * day), "claude-opus-5-5", input: 9_000_000),
        ]
        let codex = [bucket(today, "gpt-5.3-codex", input: 1_000_000, output: 100_000, records: 2)]
        let week = try XCTUnwrap(UsageWeekScanner.build([.init(provider: .claude, batch: (claude, false)), .init(provider: .codex, batch: (codex, false))], now: now, calendar: calendar))
        XCTAssertEqual(week.days.count, 7)
        XCTAssertEqual(week.days.last?.date, today)
        XCTAssertEqual(week.days.first?.date, today.addingTimeInterval(-6 * day))
        XCTAssertEqual(week.days[4].tokens, 2_000_000)
        XCTAssertEqual(week.days[5].tokens, 0)
        XCTAssertEqual(week.today?.tokens, 3_600_000)
        XCTAssertEqual(week.tokens, 5_600_000)
        XCTAssertEqual(week.todayModels.map(\.title), ["Claude · Opus 5.5", "Codex · GPT-5.3-codex", "Claude · mystery-model"])
        XCTAssertEqual(try XCTUnwrap(week.todayModels[0].apiValue), 8, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(week.todayModels[1].apiValue), 1.75 + 1.4, accuracy: 0.0001)
        XCTAssertNil(week.todayModels[2].apiValue)
        XCTAssertEqual(week.records, 7)
        XCTAssertEqual(week.pricedRecords, 6)
        XCTAssertFalse(week.partial)
    }

    func testWeekIsPartialWhenAProviderDoesNotAnswerAndNilWhenNoneDoes() throws {
        let week = try XCTUnwrap(UsageWeekScanner.build([.init(provider: .claude, batch: ([], false)), .init(provider: .codex, batch: nil)], now: now, calendar: calendar))
        XCTAssertTrue(week.partial)
        XCTAssertEqual(week.tokens, 0)
        XCTAssertNil(UsageWeekScanner.build([.init(provider: .claude, batch: nil), .init(provider: .codex, batch: nil)], now: now, calendar: calendar))
    }

    func testModelTitles() {
        XCTAssertEqual(UsageWeek.modelTitle("claude-fable-5-2"), "Fable 5.2")
        XCTAssertEqual(UsageWeek.modelTitle("claude-sonnet-4-5-20250929"), "Sonnet 4.5")
        XCTAssertEqual(UsageWeek.modelTitle("gpt-5.5"), "GPT-5.5")
        XCTAssertEqual(UsageWeek.modelTitle("Unknown model"), "Unknown model")
    }

    func testProjectBreakdownFoldsTheRestIntoOtherFolders() {
        let rows = UsageBreakdown.projects([("burro", 2_000_000, 19), ("focus", 4_100_000, 38), ("tiny", 0.5, 0), ("ops", 300_000, 2)],
                                           total: 7_000_000, totalValue: 65, limit: 2)
        XCTAssertEqual(rows.map(\.title), ["focus", "burro", "Other folders"])
        XCTAssertEqual(rows[2].tokens, 900_000)
        XCTAssertEqual(try XCTUnwrap(rows[2].apiValue), 8, accuracy: 0.0001)
        XCTAssertTrue(rows[2].isRest)
        XCTAssertEqual(UsageBreakdown.projects([("a", 10, 1)], total: 10, totalValue: 1).map(\.title), ["a"])
    }
}
