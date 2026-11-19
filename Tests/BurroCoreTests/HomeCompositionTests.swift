// Home's pure rules in the dashboard layout: the toned sentence, the KPI cells (tracking on, off and
// unknown), lane selection from Home's board (live chats only, needs-you marks, the cap, unknown
// activity), the queue's tabs and counts, the bottom row's fallback without limits, and the limits rows.
import XCTest
@testable import BurroCore

final class HomeCompositionTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private var dayStart: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)) }
    private func at(_ hour: Int, _ minute: Int = 0) -> Date { dayStart.addingTimeInterval(Double(hour * 3600 + minute * 60)) }
    private var day: DateInterval { DateInterval(start: dayStart, duration: 86_400) }

    private func session(_ n: Int, _ state: AgentState, unread: Bool = false, updated: Date? = nil, subagent: Bool = false,
                         remote: Bool = false) -> AgentSession {
        let id = String(format: "codex:00000000-0000-0000-0000-%012d", n)
        var session = AgentSession(id: remote ? "remote:\(UUID().uuidString):" + id : id, provider: .codex, title: "Chat \(n)", cwd: "/dev/app",
                                   state: state, updatedAt: updated ?? at(15), evidence: "Fixture")
        session.hasUnreadResult = unread
        session.isSubagent = subagent
        if remote { session.remote = RemoteOrigin(hostID: UUID(), hostName: "Studio", sampledAt: at(15), stale: false) }
        return session
    }

    // MARK: Sentence

    func testSentenceTonesOnlyTheNeedsYouClause() {
        let runs = HomeBoard.sentenceRuns(needsYou: 2, working: 3, toRead: 1)
        XCTAssertEqual(runs.plainText, HomeBoard.sentence(needsYou: 2, working: 3, toRead: 1))
        XCTAssertEqual(runs.first, TextRun("2 chats need you", .needsYou))
        XCTAssertEqual(runs.count, 2)
        let one = HomeBoard.sentenceRuns(needsYou: 1, working: 0, toRead: 0)
        XCTAssertEqual(one.first, TextRun("1 chat needs you", .needsYou))
        let quiet = HomeBoard.sentenceRuns(needsYou: 0, working: 2, toRead: 0)
        XCTAssertEqual(quiet, [TextRun("2 chats are working.")])
    }

    // MARK: KPI cells

    func testCellsWithTrackingOnShowFocusedAndTheAwayFigure() throws {
        let spans = [ActivitySpan(ActivityPrivacy.key(bundleID: "com.apple.dt.Xcode", app: "Xcode", title: "A.swift", address: nil), start: at(9), end: at(11)),
                     ActivitySpan(ActivityPrivacy.key(bundleID: "com.apple.dt.Xcode", app: "Xcode", title: "B.swift", address: nil), start: at(13), end: at(14))]
        let tracked = ActivityDay.build(spans: spans, rules: ActivityRules(), day: dayStart, calendar: calendar)
        let cells = HomeStats.cells(working: 3, longestTurn: 3900, machines: ["This Mac"], waiting: 2, oldestWaiting: at(14, 5), activity: nil,
                                    toRead: 4, stuck: 0, newestToRead: at(14, 2), day: .tracked(tracked, away: 32 * 60, awayPartial: false),
                                    calendar: calendar)
        XCTAssertEqual(cells.map(\.key), [.working, .waiting, .toRead, .focus])
        XCTAssertEqual(cells[0].value, "3")
        XCTAssertEqual(cells[0].sub.plainText, "longest turn 1h 05m")
        XCTAssertEqual(cells[1].label, "Waiting on you")
        XCTAssertTrue(cells[1].dot)
        XCTAssertEqual(cells[1].value, "2")
        XCTAssertTrue(cells[1].sub.plainText.hasPrefix("oldest since 14:05"))
        XCTAssertEqual(cells[2].sub.plainText, "newest 14:02")
        XCTAssertEqual(cells[3].label, "Focused today")
        XCTAssertEqual(cells[3].value, TodaySummary.duration(tracked.focused))
        XCTAssertEqual(cells[3].sub.plainText, "agents 32m while away")
        XCTAssertFalse(cells.contains { $0.label.contains("Spent") })
    }

    func testCellsWithTrackingOffShowAPIValueAndDashWhileUnknown() {
        func cell(_ day: HomeStats.Day) -> TodayStat {
            HomeStats.cells(working: 0, longestTurn: nil, machines: [], waiting: 0, oldestWaiting: nil, activity: nil, toRead: 0, stuck: 0,
                            newestToRead: nil, day: day, calendar: calendar)[3]
        }
        let known = cell(.value(dollars: 1234.4, tokens: 2_400_000))
        XCTAssertEqual(known.key, .value)
        XCTAssertEqual(known.label, "API value today")
        XCTAssertEqual(known.value, "$1,234")
        XCTAssertEqual(known.sub.plainText, "2.4M tokens on this Mac")
        let unknown = cell(.value(dollars: nil, tokens: nil))
        XCTAssertEqual(unknown.value, "—")
        XCTAssertTrue(unknown.unknown)
        XCTAssertEqual(unknown.sub.plainText, "reading…")
        XCTAssertEqual(cell(.value(dollars: 0.4, tokens: 900)).value, "<$1")
        let unread = cell(.tracked(nil, away: nil, awayPartial: false))
        XCTAssertEqual(unread.value, "—")
        XCTAssertEqual(unread.sub.plainText, "reading…")
    }

    func testWorkingFallsBackToMachinesAndReadyToReadToStuck() {
        let cells = HomeStats.cells(working: 2, longestTurn: nil, machines: ["This Mac", "Studio"], waiting: 0, oldestWaiting: nil, activity: nil,
                                    toRead: 1, stuck: 1, newestToRead: at(9), day: .value(dollars: nil, tokens: nil), calendar: calendar)
        XCTAssertEqual(cells[0].sub.plainText, "on 2 machines")
        XCTAssertEqual(cells[2].sub, [TextRun("1 looks stuck", .stuck)])
        XCTAssertEqual(cells[1].sub.plainText, "nothing waiting")
        let idle = HomeStats.cells(working: 0, longestTurn: 60, machines: [], waiting: 0, oldestWaiting: nil, activity: nil, toRead: 0, stuck: 0,
                                   newestToRead: nil, day: .value(dollars: nil, tokens: nil), calendar: calendar)
        XCTAssertEqual(idle[0].sub.plainText, "nothing running")
        XCTAssertEqual(idle[2].sub.plainText, "nothing to read")
        XCTAssertEqual(HomeStats.cells(working: 1, longestTurn: nil, machines: ["This Mac"], waiting: 0, oldestWaiting: nil, activity: nil, toRead: 0,
                                       stuck: 0, newestToRead: nil, day: .value(dollars: nil, tokens: nil), calendar: calendar)[0].sub.plainText,
                       "on This Mac")
    }

    // MARK: Lanes

    func testLanesTakeLiveChatsOnceWithNeedsYouMarksAndUnknownActivity() {
        let waiting = session(1, .waiting, updated: at(14))
        let asked = session(2, .idle, unread: true, updated: at(13))
        let working = session(3, .working, updated: at(15))
        let read = session(4, .idle, unread: true, updated: at(12))
        let remote = session(5, .working, remote: true)
        var briefItem = BriefItem(chatID: asked.id, chatTitle: "Asked", kind: .decision, headline: "Which branch?", question: "Which branch?",
                                  sourceHash: "h", createdAt: at(13, 1))
        briefItem.updatedAt = at(13, 1)
        let closed = BriefItem(chatID: "codex:gone", chatTitle: "Gone", kind: .decision, headline: "Closed chat", sourceHash: "h2", createdAt: at(11))
        let board = HomeBoard.build(waiting: [waiting], running: [working, remote, session(6, .working, subagent: true)], unread: [asked, read],
                                    briefNeeds: [briefItem, closed])
        let inputs = HomeLanes.inputs(board, place: { _ in "This Mac · app" }, turnStart: { $0 == working.id ? self.at(14, 30) : nil })
        XCTAssertEqual(inputs.map(\.id), [waiting.id, asked.id, working.id, remote.id, read.id])
        XCTAssertEqual(inputs.map(\.state), [.needsYou, .needsYou, .working, .working, .toRead])
        XCTAssertEqual(inputs[2].turnStart, at(14, 30))
        XCTAssertTrue(inputs[3].remote)

        let activity = DailyActivity(day: dayStart, turnsByHour: Array(repeating: 0, count: 24), repliesByHour: Array(repeating: 0, count: 24),
                                     questions: 0, firstTurn: at(9), lastTurn: at(15),
                                     chats: [DailyActivity.Chat(id: working.id, provider: .codex, folder: "/dev/app", turns: 3, replies: 5, questions: 0,
                                                                lastAt: at(15), title: "Chat 3", active: [DateInterval(start: at(14, 30), end: at(15))])],
                                     partial: false)
        let lanes = TodayLanes.build(inputs, activity: activity, needsSince: HomeLanes.needsSince(board), brief: [briefItem], window: day,
                                     isToday: true, now: at(15, 10), calendar: calendar)
        let byID = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, $0) })
        // Waiting now: one filled amber mark at when it began waiting.
        XCTAssertEqual(byID[waiting.id]?.marks.map(\.kind), [.asked])
        XCTAssertEqual(byID[waiting.id]?.marks.first?.at, at(14))
        // Triage's question for a chat that needs you now is that same amber mark, not an earlier ring.
        XCTAssertEqual(byID[asked.id]?.marks.map(\.kind), [.asked])
        // Unknown stays unknown: no stretches for chats the scan didn't report, never idle.
        XCTAssertNil(byID[read.id]?.intervals)
        XCTAssertNil(byID[remote.id]?.intervals)
        XCTAssertEqual(byID[working.id]?.intervals?.count, 1)
        XCTAssertEqual(byID[working.id]?.outcome, "Working · turn 40 min")
        // Before the first scan answers every lane is unknown.
        let unscanned = TodayLanes.build(inputs, activity: nil, needsSince: HomeLanes.needsSince(board), brief: [], window: day, isToday: true,
                                         now: at(15, 10), calendar: calendar)
        XCTAssertTrue(unscanned.allSatisfy { $0.intervals == nil })
        // The window covers what is drawn.
        let window = DayRibbonLayout.laneWindow(day: day, pieces: HomeLanes.pieces(lanes), now: at(15, 10), calendar: calendar)
        XCTAssertLessThanOrEqual(window.window.start, at(13))
        XCTAssertEqual(window.window.end, at(15, 10))
    }

    func testLanesCapIsSixAndEveryLiveChatIsKept() {
        let running = (1...9).map { session($0, .working, updated: at(10 + $0 % 5)) }
        let inputs = HomeLanes.inputs(HomeBoard.build(waiting: [], running: running, unread: []), place: { _ in "" }, turnStart: { _ in nil })
        XCTAssertEqual(inputs.count, 9)
        XCTAssertEqual(HomeLanes.cap, 6)
        XCTAssertEqual(Array(inputs.prefix(HomeLanes.cap)).count, 6)
    }

    // MARK: Queue tabs

    func testQueueTabsCountEachSectionAndOpenOnWhatNeedsYou() {
        let tabs = HomeQueueTabs.tabs(needsYou: 2, working: 4, toRead: 3)
        XCTAssertEqual(tabs.map(\.kind), [.waiting, .working, .toRead])
        XCTAssertEqual(tabs.map(\.count), [2, 4, 3])
        XCTAssertEqual(tabs.map(\.title), ["Waiting on you", "Working", "Ready to read"])
        XCTAssertEqual(HomeQueueTabs.initial(needsYou: 2, working: 4, toRead: 3), .waiting)
        XCTAssertEqual(HomeQueueTabs.initial(needsYou: 0, working: 4, toRead: 3), .working)
        XCTAssertEqual(HomeQueueTabs.initial(needsYou: 0, working: 0, toRead: 3), .toRead)
        XCTAssertEqual(HomeQueueTabs.initial(needsYou: 0, working: 0, toRead: 0), .waiting)
    }

    // MARK: Bottom row and limits

    func testBottomRowFallsBackToTodosAndNotesWithoutLimits() {
        XCTAssertEqual(HomeBottomRow.slots(limitsShown: true), [.machines, .limits, .todos])
        XCTAssertEqual(HomeBottomRow.slots(limitsShown: false), [.machines, .todos, .notes])
    }

    func testLimitsKeepHiddenProvidersHiddenAndSayAccountProblems() {
        let now = at(12)
        let claude = ProviderUsage(id: .claude, updatedAt: now, windows: [
            UsageWindow(id: "session", title: "5-hour", remainingPercent: 62, resetsAt: now.addingTimeInterval(3 * 3600 + 12 * 60)),
            UsageWindow(id: "week", title: "Weekly", remainingPercent: 120, resetsAt: nil),
            UsageWindow(id: "none", title: "Unknown", remainingPercent: nil, resetsAt: nil)])
        let codex = ProviderUsage.failure(.codex, .signInRequired)
        let rows = HomeLimits.rows([claude, codex], shown: [.claude, .codex], now: now)
        XCTAssertEqual(rows.map(\.window), ["5-hour", "Weekly", nil])
        XCTAssertEqual(rows[0].remaining, 62)
        XCTAssertEqual(rows[0].detail, "Resets in 3h 12m")
        XCTAssertEqual(rows[1].remaining, 100)
        XCTAssertEqual(rows[2].detail, UsageIssue.signInRequired.accountLabel)
        XCTAssertFalse(rows[0].stale)
        XCTAssertEqual(HomeLimits.rows([claude, codex], shown: [.claude], now: now).map(\.provider), ["Claude", "Claude"])
        XCTAssertTrue(HomeLimits.rows([claude], shown: [], now: now).isEmpty)
    }

    func testMoneyIsWholeDollarsInEveryLocale() {
        XCTAssertEqual(HomeStats.money(0), "$0")
        XCTAssertEqual(HomeStats.money(12.6), "$13")
        XCTAssertEqual(HomeStats.money(1_234_567), "$1,234,567")
    }
}
