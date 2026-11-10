import XCTest
@testable import BurroCore

final class TodayTests: XCTestCase {
    private let since = 1_794_150_000.0
    private func request(previews: Bool = true) -> DailyActivityRequest {
        DailyActivityRequest(codexRoots: ["/c"], claudeRoots: ["/p"], since: since, until: since + 86_400, now: since + 3600, previews: previews)
    }
    private func batch(_ sessions: String = "[]", first: String = "null") -> Data {
        let zeros = Array(repeating: "0", count: 24).joined(separator: ",")
        return Data("""
        {"turnsByHour":[\(zeros)],"repliesByHour":[\(zeros)],"questions":0,"firstTurn":\(first),"lastTurn":null,
         "sessions":\(sessions),"partial":false,"reads":1,"cacheHits":0,"visited":3}
        """.utf8)
    }

    func testActivityBatchValidation() throws {
        let ok = #"[{"provider":"codex","id":"01a1be01-5798-7cc1-9a11-57d9fc33c0da","cwd":"/work","turns":2,"replies":3,"questions":0,"lastAt":1794153600,"preview":"Done"}]"#
        XCTAssertTrue(try JSONDecoder().decode(DailyActivityBatch.self, from: batch(ok)).valid(for: request()))
        XCTAssertFalse(try JSONDecoder().decode(DailyActivityBatch.self, from: batch(ok)).valid(for: request(previews: false)),
                       "previews must not arrive unless asked for")
        let outside = ok.replacingOccurrences(of: "1794153600", with: "1794000000")
        XCTAssertFalse(try JSONDecoder().decode(DailyActivityBatch.self, from: batch(outside)).valid(for: request()))
        let badID = ok.replacingOccurrences(of: "01a1be01-5798-7cc1-9a11-57d9fc33c0da", with: "../etc")
        XCTAssertFalse(try JSONDecoder().decode(DailyActivityBatch.self, from: batch(badID)).valid(for: request()))
        XCTAssertFalse(try JSONDecoder().decode(DailyActivityBatch.self, from: batch(first: "1")).valid(for: request()))
    }

    func testHoursCombineTurnsWithTrackedCategories() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let day = Date(timeIntervalSince1970: since) // midnight in Seoul
        var turns = Array(repeating: 0, count: 24); turns[10] = 4
        let activity = DailyActivity(day: day, turnsByHour: turns, repliesByHour: Array(repeating: 0, count: 24), questions: 0,
                                     firstTurn: nil, lastTurn: nil, chats: [], partial: false)
        let at = { (h: Double) in Date(timeIntervalSince1970: self.since + h * 3600) }
        let key = { (bundle: String) in ActivityPrivacy.key(bundleID: bundle, app: bundle, title: nil) }
        let tracked = ActivityDay.build(spans: [
            ActivitySpan(key("com.apple.dt.Xcode"), start: at(10.0), end: at(10.4)),
            ActivitySpan(key("com.tinyspeck.slackmacgap"), start: at(10.4), end: at(11.2)),
        ], rules: ActivityRules(), day: day, calendar: calendar)
        let hours = TodaySummary.hours(activity: activity, tracked: tracked)
        XCTAssertEqual(hours.count, 24)
        XCTAssertEqual(hours[10].turns, 4)
        XCTAssertEqual(hours[10].category, .comms, "36 of the hour's minutes beat 24")
        XCTAssertEqual(hours[11].category, .comms)
        XCTAssertNil(hours[12].category)
        XCTAssertEqual(TodaySummary.hours(activity: nil, tracked: nil).count, 24)
    }

    func testDecisionsAndDurations() {
        XCTAssertEqual(TodaySummary.decisions(asked: 10, waitingNow: 3).answered, 7)
        XCTAssertEqual(TodaySummary.decisions(asked: 1, waitingNow: 3).asked, 3, "waiting chats count as asked")
        XCTAssertNil(TodaySummary.decisions(asked: 0, waitingNow: 0).share)
        XCTAssertEqual(TodaySummary.duration(8 * 3600 + 27 * 60), "8h 27m")
        XCTAssertEqual(TodaySummary.duration(59 * 60), "59m")
    }

    /// BURRO_LIVE_ACTIVITY=1: scan today's real logs (read-only; prints counts only).
    func testLiveTodayScan() throws {
        guard ProcessInfo.processInfo.environment["BURRO_LIVE_ACTIVITY"] == "1" else { throw XCTSkip("set BURRO_LIVE_ACTIVITY=1") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let worker = AgentLogWorker(executable: root.appendingPathComponent(".build/rust/release/burro-log-worker"))
        defer { worker.stop() }
        let started = Date()
        let activity = try XCTUnwrap(DailyActivityScanner.scan(day: Date(), previews: true, profiles: [:], now: Date(), calendar: .current, worker: worker))
        print("today: turns \(activity.turns) replies \(activity.replies) questions \(activity.questions) chats \(activity.chats.count) previews \(activity.chats.filter { $0.preview != nil }.count) titles \(activity.chats.filter { $0.title != nil }.count) partial \(activity.partial) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        XCTAssertGreaterThan(activity.turns, 0, "this session alone has sent messages today")
        let warmStart = Date()
        _ = DailyActivityScanner.scan(day: Date(), previews: false, profiles: [:], now: Date(), calendar: .current, worker: worker)
        print("warm rescan in \(Int(Date().timeIntervalSince(warmStart) * 1000)) ms")
    }
}
