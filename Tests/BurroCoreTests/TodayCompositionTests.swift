// The Today page's pure rules: merged agent time, the header sentence, the KPI cells (today vs a
// past day, tracking on vs off), lane building (unknown activity, marks, outcomes, the cap), the
// lanes' summary sentence, the lanes' window and hit-testing, and the per-project rollup.
import XCTest
@testable import BurroCore

final class TodayCompositionTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private var dayStart: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)) }
    private func at(_ hour: Int, _ minute: Int = 0) -> Date { dayStart.addingTimeInterval(Double(hour * 3600 + minute * 60)) }
    private func span(_ a: Date, _ b: Date) -> DateInterval { DateInterval(start: a, end: b) }
    private var day: DateInterval { DateInterval(start: dayStart, duration: 86_400) }

    private func chat(_ id: String, _ active: [DateInterval]?, turns: Int = 4) -> DailyActivity.Chat {
        DailyActivity.Chat(id: id, provider: .claude, folder: "/w", turns: turns, replies: 9, questions: 0, lastAt: at(17), title: id, active: active)
    }
    private func activity(_ chats: [DailyActivity.Chat], partial: Bool = false, first: Date? = nil, last: Date? = nil) -> DailyActivity {
        var turns = Array(repeating: 0, count: 24); turns[9] = 30; turns[15] = 11
        var replies = Array(repeating: 0, count: 24); replies[9] = 40; replies[15] = 23
        return DailyActivity(day: dayStart, turnsByHour: turns, repliesByHour: replies, questions: 6, firstTurn: first ?? at(8, 12),
                             lastTurn: last ?? at(17, 40), chats: chats, partial: partial)
    }

    // MARK: Merged time

    func testMergedTimeCountsOverlapsOnceAndUnknownMakesItApproximate() throws {
        XCTAssertEqual(ActivityCoverage.mergedDuration([span(at(9), at(11)), span(at(10), at(12)), span(at(14), at(15))]), 4 * 3600)
        let known = try XCTUnwrap(TodayAgentTime.make(activity([chat("a", [span(at(9), at(11))]), chat("b", [span(at(10), at(12))])])))
        XCTAssertEqual(known.total, 3 * 3600)
        XCTAssertFalse(known.approximate)
        XCTAssertEqual(known.text, "3h 0m")
        let some = try XCTUnwrap(TodayAgentTime.make(activity([chat("a", [span(at(9), at(11))]), chat("b", nil)])))
        XCTAssertEqual(some.total, 2 * 3600)
        XCTAssertTrue(some.approximate)
        XCTAssertEqual(some.text, "about 2h 0m")
        let partial = try XCTUnwrap(TodayAgentTime.make(activity([chat("a", [span(at(9), at(10))])], partial: true)))
        XCTAssertTrue(partial.approximate)
        // Nothing known: unknown, never zero.
        let none = try XCTUnwrap(TodayAgentTime.make(activity([chat("a", nil), chat("b", nil)])))
        XCTAssertNil(none.total)
        XCTAssertNil(none.text)
        XCTAssertNil(TodayAgentTime.make(nil))
    }

    // MARK: Header

    func testHeaderSentenceStatesOnlyFacts() {
        let day = activity([chat("a", [span(at(9), at(12))]), chat("b", [span(at(11), at(15, 10))])])
        let away = AgentAwayTime.Summary(total: 2 * 3600 + 40 * 60, chats: [], span: nil, away: [])
        XCTAssertEqual(TodayHeadline.sentence(activity: day, agentTime: .make(day), away: away, isToday: true, todos: (3, 8), calendar: calendar).plainText,
                       "First message 08:12, last 17:40. 2 chats worked 6h 10m; 2h 40m of it while you were away. 3 of 8 to-dos done.")
        XCTAssertEqual(TodayHeadline.sentence(activity: day, agentTime: .make(day), away: nil, isToday: true, calendar: calendar).plainText,
                       "First message 08:12, last 17:40. 2 chats worked 6h 10m.")
        let unknown = activity([chat("a", nil)])
        XCTAssertEqual(TodayHeadline.sentence(activity: unknown, agentTime: .make(unknown), away: nil, isToday: false, calendar: calendar).plainText,
                       "First message 08:12, last 17:40. 1 chat; Burro can't tell for how long.")
        var empty = activity([])
        empty.firstTurn = nil; empty.lastTurn = nil
        XCTAssertEqual(TodayHeadline.sentence(activity: empty, agentTime: .make(empty), away: nil, isToday: true, calendar: calendar).plainText,
                       "No messages to an agent yet today.")
        XCTAssertEqual(TodayHeadline.sentence(activity: nil, agentTime: nil, away: nil, isToday: true, calendar: calendar).plainText,
                       "Reading your agent logs…")
    }

    // MARK: KPI cells

    func testKPICellsForTodayWithTrackingOff() {
        let day = activity([chat("a", [span(at(9), at(12))]), chat("b", nil)], partial: false)
        let cells = TodayStats.cells(activity: day, tracked: nil, tracking: false, isToday: true, agentTime: .make(day), waiting: 2,
                                     oldestWaiting: at(17, 5), shipped: .loaded(merged: 4, deploys: 1, dayBefore: 2), calendar: calendar)
        XCTAssertEqual(cells.map(\.label), ["With agents", "Agents worked", "Waiting on you", "Shipped"])
        XCTAssertEqual(cells[0].value, "9h 28m")
        XCTAssertEqual(cells[0].sub.plainText, "08:12–17:40")
        XCTAssertEqual(cells[1].value, "3h 0m")
        XCTAssertEqual(cells[1].valuePrefix, "about", "one chat's stretches are unknown")
        XCTAssertEqual(cells[1].sub.plainText, "2 chats · 41 sent · 63 replies")
        XCTAssertTrue(cells[2].dot)
        XCTAssertEqual(cells[2].value, "2")
        XCTAssertEqual(cells[2].sub.plainText, "oldest since 17:05")
        XCTAssertEqual(cells[3].value, "4")
        XCTAssertEqual(cells[3].sub.plainText, "merged · 1 production deploy")
    }

    func testKPICellsForAPastDayWithTrackingOn() {
        let day = activity([chat("a", nil)])
        let cells = TodayStats.cells(activity: day, tracked: nil, tracking: true, isToday: false, agentTime: .make(day), waiting: 3,
                                     oldestWaiting: nil, shipped: .loaded(merged: 0, deploys: 0, dayBefore: 5), calendar: calendar)
        XCTAssertEqual(cells.map(\.label), ["Focused", "Agents worked", "Questions asked", "Shipped"])
        XCTAssertEqual(cells[0].value, "—")
        XCTAssertEqual(cells[0].sub.plainText, "reading…")
        XCTAssertEqual(cells[1].value, "—", "no stretches known: unknown, not 0m")
        XCTAssertNil(cells[1].valuePrefix)
        XCTAssertEqual(cells[1].sub.plainText, "time unknown · 1 chat · 41 sent · 63 replies")
        XCTAssertFalse(cells[2].dot, "only today has the amber dot")
        XCTAssertEqual(cells[2].value, "6")
        XCTAssertEqual(cells[3].sub.plainText, "merged · day before: 5")
        let loading = TodayStats.cells(activity: nil, tracked: nil, tracking: false, isToday: true, agentTime: nil, waiting: 0,
                                       oldestWaiting: nil, shipped: .loading, calendar: calendar)
        XCTAssertEqual(loading.map(\.value), ["—", "—", "0", "—"])
        XCTAssertEqual(loading[2].sub.plainText, "nothing waiting")
        XCTAssertEqual(loading[3].sub.plainText, "reading GitHub…")
    }

    // MARK: Lanes

    private func input(_ id: String, _ state: TodayLaneInput.State, last: Date, turn: Date? = nil, remote: Bool = false) -> TodayLaneInput {
        TodayLaneInput(id: id, title: "Chat \(id)", provider: .codex, state: state, place: "focustown", lastAt: last, turnStart: turn, remote: remote)
    }
    private func item(_ chat: String, _ kind: BriefItem.Kind, _ created: Date, headline: String = "Headline", chatUpdatedAt: Date? = nil) -> BriefItem {
        BriefItem(chatID: chat, kind: kind, headline: headline, sourceHash: "h", chatUpdatedAt: chatUpdatedAt, createdAt: created)
    }

    func testLanesKeepUnknownActivityUnknownAndMarkWhatTheBriefSaw() throws {
        let now = at(18)
        let day = activity([chat("wait", [span(at(9), at(10, 30))], turns: 14), chat("work", [span(at(16), now)]),
                            chat("read", [span(at(11), at(12))]), chat("unknown", nil)])
        let inputs = [input("read", .toRead, last: at(12)), input("unknown", .idle, last: at(13)), input("work", .working, last: now, turn: at(17, 42)),
                      input("wait", .needsYou, last: at(17, 54)), input("remote", .working, last: now, remote: true),
                      input("old", .idle, last: at(8))]
        let window = DayRibbonLayout.laneWindow(day: self.day, earliest: at(9, 10), now: now, calendar: calendar)
        let lanes = TodayLanes.build(inputs, activity: day, needsSince: ["WAIT": at(17, 54)],
                                     brief: [item("wait", .decision, at(10, 20), headline: "Merge it?"), item("remote", .stuck, at(17), chatUpdatedAt: at(17, 8)),
                                             item("read", .done, at(12, 1), headline: "Opened PR #12, tests pass.")],
                                     window: window, isToday: true, now: now, calendar: calendar)
        XCTAssertEqual(lanes.map(\.id), ["wait", "remote", "work", "read", "unknown", "old"], "needs you, working, ready, then the rest newest first")
        let wait = lanes[0]
        XCTAssertEqual(wait.outcome, "Waiting · 6 min")
        XCTAssertEqual(wait.detail, "active 1h 30m · 14 sent")
        XCTAssertEqual(wait.marks.map(\.kind), [.askedEarlier, .asked], "only the current wait is amber; the morning's question is a grey ring")
        XCTAssertEqual(wait.marks.map(\.at), [at(10, 20), at(17, 54)])
        let remote = lanes[1]
        XCTAssertNil(remote.intervals, "another machine has no stretches: unknown, never idle")
        XCTAssertTrue(remote.stuck)
        XCTAssertEqual(remote.outcome, "Stuck · quiet 52 min")
        XCTAssertEqual(remote.marks.map(\.kind), [.stuck])
        XCTAssertEqual(lanes[2].outcome, "Working · turn 18 min")
        XCTAssertEqual(lanes[3].outcome, "Ready to read")
        XCTAssertEqual(lanes[3].detail, "Opened PR #12, tests pass.")
        let unknown = lanes[4]
        XCTAssertNil(unknown.intervals)
        XCTAssertNil(unknown.activeSeconds)
        XCTAssertEqual(unknown.outcome, "Done · 13:00")
        XCTAssertEqual(unknown.detail, "4 sent")
        XCTAssertNil(lanes[5].detail)

        XCTAssertEqual(TodayLanes.summary(lanes, isToday: true).plainText, "1 chat waits on you and 1 looks stuck. 1 still working, 1 ready to read and the rest done.")
        XCTAssertEqual(TodayLanes.summary(lanes, isToday: true).filter { $0.tone == .needsYou }.map(\.text), ["1 chat waits on you"])
        XCTAssertEqual(TodayLanes.summary(lanes, isToday: true).filter { $0.tone == .stuck }.map(\.text), ["1 looks stuck"])
        XCTAssertEqual(TodayLanes.earliest(lanes), at(9))
    }

    func testAPastDayHasNoWaitingAndAWholeDayWindow() {
        let past = TodayLanes.build([input("a", .needsYou, last: at(15)), input("b", .idle, last: at(16))],
                                    activity: activity([chat("a", [span(at(9), at(12, 5))]), chat("b", [span(at(14), at(15))])]),
                                    needsSince: [:], brief: [], window: day, isToday: false, now: at(23), calendar: calendar)
        XCTAssertEqual(past.map(\.outcome), ["Done · 15:00", "Done · 16:00"])
        XCTAssertTrue(past.allSatisfy { $0.marks.isEmpty })
        XCTAssertEqual(TodayLanes.summary(past, isToday: false).plainText, "2 chats that day. The longest, Chat a, was active 3h 5m.")
        XCTAssertEqual(TodayLanes.summary([], isToday: true).plainText, "No chats yet today.")
        XCTAssertEqual(DayRibbonLayout.laneWindow(day: day, earliest: at(9), now: nil, calendar: calendar), day)
    }

    func testCapAndQuietSummary() {
        let inputs = (0..<11).map { input("c\($0)", .idle, last: at(9, $0)) }
        let lanes = TodayLanes.build(inputs, activity: nil, needsSince: [:], brief: [], window: day, isToday: true, now: at(18), calendar: calendar)
        XCTAssertEqual(lanes.count, 11, "all lanes are built; the view shows the first TodayLanes.cap")
        XCTAssertEqual(TodayLanes.cap, 8)
        XCTAssertEqual(Array(lanes.prefix(TodayLanes.cap)).first?.id, "c10")
        XCTAssertEqual(TodayLanes.summary(lanes, isToday: true).plainText, "Nothing waits on you. All 11 done.")
    }

    // MARK: Window and hit-testing

    func testLaneWindowAndHitTesting() {
        let window = DayRibbonLayout.laneWindow(day: day, earliest: at(9, 40), now: at(17, 30), calendar: calendar)
        XCTAssertEqual(window, span(at(9), at(17, 30)))
        // Something just now still gets an hour of axis.
        XCTAssertEqual(DayRibbonLayout.laneWindow(day: day, earliest: at(17, 20), now: at(17, 30), calendar: calendar), span(at(16), at(17, 30)))
        XCTAssertEqual(DayRibbonLayout.laneWindow(day: day, earliest: nil, now: at(0, 20), calendar: calendar), span(at(0), at(0, 20)))
        let layout = DayRibbonLayout(window: span(at(9), at(17)), width: 800)
        XCTAssertEqual(layout.stretch(atX: 150, in: [span(at(10), at(11)), span(at(13), at(14))]), span(at(10), at(11)))
        XCTAssertEqual(layout.stretch(atX: 202, in: [span(at(10), at(11))]), span(at(10), at(11)), "a little tolerance past the end")
        XCTAssertNil(layout.stretch(atX: 300, in: [span(at(10), at(11))]))
        XCTAssertEqual(layout.date(atX: 400), at(13))
        XCTAssertEqual(DayRibbonLayout.lane(atY: 85, height: 40, count: 3), 2)
        XCTAssertNil(DayRibbonLayout.lane(atY: 125, height: 40, count: 3))
        XCTAssertNil(DayRibbonLayout.lane(atY: -1, height: 40, count: 3))
    }

    // MARK: Projects

    func testProjectsMergeTheirChatsTime() {
        let rows = TodayProjects.rows([("burro", [span(at(9), at(11))]), ("burro", [span(at(10), at(12))]), ("focus", nil),
                                       ("notes", [span(at(9), at(9, 30))]), ("notes", nil)])
        XCTAssertEqual(rows.map(\.name), ["burro", "notes", "focus"])
        XCTAssertEqual(rows[0].chats, 2)
        XCTAssertEqual(rows[0].active, 3 * 3600)
        XCTAssertFalse(rows[0].approximate)
        XCTAssertTrue(rows[1].approximate)
        XCTAssertNil(rows[2].active)
    }

    // MARK: Readability on a real day

    func testLaneWindowLeavesOutANightBlockBeforeALongGap() {
        let now = at(15, 45)
        // One tracked block just after midnight, nothing until 10:18, then the working day.
        let night = TodayCompositionTests.pieces([(0, 0, 0, 28)], at: at) + TodayCompositionTests.pieces([(10, 18, 11, 40), (12, 5, 15, 44)], at: at)
        let trimmed = DayRibbonLayout.laneWindow(day: day, pieces: night, now: now, calendar: calendar)
        XCTAssertEqual(trimmed.window, span(at(10), now))
        XCTAssertEqual(trimmed.cut, 28 * 60)
        // No long gap: from the first piece's hour, nothing cut.
        let steady = DayRibbonLayout.laneWindow(day: day, pieces: TodayCompositionTests.pieces([(8, 40, 11, 0), (12, 0, 15, 0)], at: at), now: now, calendar: calendar)
        XCTAssertEqual(steady.window, span(at(8), now))
        XCTAssertEqual(steady.cut, 0)
        // Real work before noon then nothing until now is never cut (the gap is to now, and the lead is long).
        let morning = DayRibbonLayout.laneWindow(day: day, pieces: TodayCompositionTests.pieces([(7, 0, 9, 30), (13, 0, 13, 10)], at: at), now: now, calendar: calendar)
        XCTAssertEqual(morning.window, span(at(7), now))
        XCTAssertEqual(morning.cut, 0)
        // A zero-length mark counts as drawn.
        let marked = DayRibbonLayout.laneWindow(day: day, pieces: [DateInterval(start: at(9, 5), duration: 0)] + TodayCompositionTests.pieces([(9, 30, 10, 0)], at: at),
                                                now: now, calendar: calendar)
        XCTAssertEqual(marked.window.start, at(9))
        // Empty day: an hour before now; a past empty day: 00–24.
        XCTAssertEqual(DayRibbonLayout.laneWindow(day: day, pieces: [], now: now, calendar: calendar).window, span(at(14), now))
        XCTAssertEqual(DayRibbonLayout.laneWindow(day: day, pieces: [], now: nil, calendar: calendar).window, day)
        // A past day: the same cut at the start, and it ends at the hour after its last piece.
        let past = DayRibbonLayout.laneWindow(day: day, pieces: night, now: nil, calendar: calendar)
        XCTAssertEqual(past.window, span(at(10), at(16)))
        XCTAssertEqual(past.cut, 28 * 60)
    }

    private static func pieces(_ spans: [(Int, Int, Int, Int)], at: (Int, Int) -> Date) -> [DateInterval] {
        spans.map { DateInterval(start: at($0.0, $0.1), end: at($0.2, $0.3)) }
    }

    func testDrawnPiecesJoinShortBurstsAndKeepAMinimumWidth() {
        // 8 hours over 800 pt: 100 pt an hour, a minute is 1.67 pt.
        let layout = DayRibbonLayout(window: span(at(9), at(17)), width: 800)
        let bursts = [span(at(10, 0), at(10, 0).addingTimeInterval(20)), span(at(10, 1), at(10, 3)),   // 1 min apart: joined
                      span(at(10, 4), at(10, 4).addingTimeInterval(10)),                                // 1 min later: joined
                      span(at(11, 0), at(11, 0).addingTimeInterval(15))]                                // an hour later: its own
        let drawn = layout.drawn(bursts)
        XCTAssertEqual(drawn.count, 2)
        XCTAssertEqual(drawn[0].interval, span(at(10, 0), at(10, 4).addingTimeInterval(10)))
        XCTAssertEqual(drawn[0].active, 20 + 120 + 10, "the totals stay the stretches' own")
        XCTAssertEqual(drawn[1].width, 3, accuracy: 0.001, "a 15-second burst is still 3 pt wide")
        XCTAssertEqual(layout.piece(atX: 101, in: bursts)?.active, 150)
        XCTAssertEqual(layout.stretch(atX: 202, in: bursts), bursts[3])
        XCTAssertNil(layout.piece(atX: 150, in: bursts))
        XCTAssertTrue(layout.drawn([]).isEmpty)
    }

    func testTheRestIsSortedByActiveTimeSoTheCapShowsSubstantialChats() {
        let day = activity([chat("big", [span(at(9), at(11))]), chat("small", [span(at(12), at(12, 5))]), chat("tiny", [span(at(15, 40), at(15, 41))])])
        let lanes = TodayLanes.build([input("tiny", .idle, last: at(15, 44)), input("noise", .idle, last: at(15, 44)), input("small", .idle, last: at(12, 5)),
                                      input("big", .idle, last: at(11)), input("work", .working, last: at(15, 40))],
                                     activity: day, needsSince: [:], brief: [], window: self.day, isToday: true, now: at(15, 45), calendar: calendar)
        XCTAssertEqual(lanes.map(\.id), ["work", "big", "small", "tiny", "noise"], "working first; then longest active, unknown last")
    }
}
