import AppKit
import SwiftUI
import XCTest
@testable import Burro
@testable import BurroCore

/// Renders Home's dashboard layout (`HomePage`) over a still aquarium with invented chats, a
/// realistic day of short agent bursts, to-dos, machines and limits, to PNGs for a visual check, at
/// the content widths of a 1000, 1240 and 1440 pt window beside the sidebar (935, 1015, 1215), dark
/// and light: needs you + working + ready, nothing happening, more than the caps, tracking off,
/// usage off, today's scan not answered yet (lanes without bars), and a stuck chat with an
/// unreachable machine. Skipped unless BURRO_HOME_SNAPSHOTS=1; writes to dist/screenshots
/// (gitignored) or BURRO_SNAPSHOT_DIR. Draws plain-value views offscreen; never reads the owner's
/// chats, Brief, to-dos, notes or activity.
@MainActor final class HomeSnapshotTests: XCTestCase {
    func testRenderHomeSnapshots() async throws {
        guard ProcessInfo.processInfo.environment["BURRO_HOME_SNAPSHOTS"] == "1" else { throw XCTSkip("set BURRO_HOME_SNAPSHOTS=1") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = ProcessInfo.processInfo.environment["BURRO_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("dist/screenshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let fixture = try await HomeSnapshotFixture.make(self)

        func shot(_ name: String, _ state: HomeSnapshotFixture.State, widths: [CGFloat], modes: [Bool] = [true, false]) throws {
            for width in widths {
                for dark in modes {
                    let view = fixture.page(state, width: width)
                    try HomeSnapshotFixture.render(view, width: width, dark: dark,
                                                   to: out.appendingPathComponent("home-\(name)-\(Int(width))-\(dark ? "dark" : "light").png"))
                }
            }
        }
        try shot("busy", .busy, widths: [935, 1015, 1215])
        try shot("empty", .empty, widths: [935, 1015, 1215], modes: [false])
        try shot("many", .many, widths: [1015, 1215])
        try shot("tracking-off", .trackingOff, widths: [1015])
        try shot("usage-off", .usageOff, widths: [1015, 1215], modes: [true])
        try shot("not-loaded", .notLoaded, widths: [1015], modes: [false])
        try shot("stuck", .stuck, widths: [935, 1215], modes: [true, false])
    }
}

/// Invented Home states over a still aquarium, shared with ChromeSnapshotTests' Home stand-in.
@MainActor struct HomeSnapshotFixture {
    enum State { case busy, empty, many, trackingOff, usageOff, notLoaded, stuck }

    var tracked: ActivityDay
    var tracker: ActivityTracker
    var todos: TodoStore
    var notes: NotesStore
    let calendar = Calendar.current
    var dayStart: Date { calendar.startOfDay(for: Date()) }
    func at(_ hour: Int, _ minute: Double = 0) -> Date { dayStart.addingTimeInterval(Double(hour) * 3600 + minute * 60) }
    var now: Date { at(15, 45) }
    var day: DateInterval { DateInterval(start: dayStart, duration: 86_400) }

    static func make(_ test: XCTestCase) async throws -> HomeSnapshotFixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-home-snapshot-\(UUID().uuidString)")
        test.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let calendar = Calendar.current, start = calendar.startOfDay(for: Date())
        func at(_ hour: Int, _ minute: Double = 0) -> Date { start.addingTimeInterval(Double(hour) * 3600 + minute * 60) }
        let log = ActivityLog(folder: folder)
        func span(_ bundle: String, _ app: String, _ from: Date, _ to: Date, _ title: String) -> ActivitySpan {
            ActivitySpan(ActivityPrivacy.key(bundleID: bundle, app: app, title: title, address: nil), start: from, end: to)
        }
        try log.append([
            span("com.apple.mail", "Mail", at(8, 30), at(9, 0), "Inbox"),
            span("com.apple.dt.Xcode", "Xcode", at(9, 0), at(11, 40), "HomeView.swift"),
            span("com.tinyspeck.slackmacgap", "Slack", at(11, 40), at(12, 10), "general — Slack"),
            span("com.figma.Desktop", "Figma", at(13, 30), at(14, 30), "Home"),
            span("com.apple.dt.Xcode", "Xcode", at(14, 30), at(15, 40), "HomeQueue.swift"),
        ])
        let suite = "burro.home.snapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        test.addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let tracker = ActivityTracker(defaults: defaults, log: log)
        tracker.enabled = true
        let today = TodayStore(defaults: defaults, tracker: tracker)
        today.refreshTracked()
        for _ in 0..<200 where today.tracked == nil { try await Task.sleep(for: .milliseconds(10)) }
        let tracked = try XCTUnwrap(today.tracked)
        let todos = TodoStore(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent("burro-home-todos-\(UUID().uuidString).json"), config: nil)
        for text in ["New consumer support dashboard", "Upgrade Godot and the bridge", "Design the study-with-friends feature"] { todos.add(text) }
        let notesFolder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-home-notes-\(UUID().uuidString)")
        test.addTeardownBlock { try? FileManager.default.removeItem(at: notesFolder) }
        return HomeSnapshotFixture(tracked: tracked, tracker: tracker, todos: todos, notes: NotesStore(folder: notesFolder))
    }

    // MARK: Chats

    private static let titles = ["Streak ladder config", "Support dashboard alerts", "Weekly leftovers check", "iOS hang on resume",
                                 "Godot shader warm-up", "Android 2.2.24 release notes", "Refactor the save format", "Twitter link setup",
                                 "Study with friends layout", "Audit repository security", "Coin ledger audit", "Store screenshots",
                                 "Refund alerts", "Onboarding copy", "Crash triage", "Release notes 2.3", "Friends layout", "Support macros"]

    private func session(_ index: Int, _ state: AgentState, unread: Bool = false, minutesAgo: Double, remote: Bool = false) -> AgentSession {
        let provider: AgentProvider = index % 3 == 0 ? .codex : .claude
        let id = String(format: "%@:00000000-0000-4000-8000-%012d", provider == .codex ? "codex" : "claude", index)
        var session = AgentSession(id: remote ? "remote:00000000-0000-4000-8000-00000000beef:" + id : id, provider: provider,
                                   title: Self.titles[index % Self.titles.count] + (index >= Self.titles.count ? " \(index / Self.titles.count + 1)" : ""),
                                   cwd: index % 4 == 0 ? "/work/burro" : "/work/focustown", state: state,
                                   updatedAt: now.addingTimeInterval(-minutesAgo * 60), evidence: "Fixture")
        session.hasUnreadResult = unread
        session.model = provider == .codex ? "gpt-5.5" : "claude-opus-5-5"
        if remote { session.remote = RemoteOrigin(hostID: UUID(uuidString: "00000000-0000-4000-8000-00000000beef")!, hostName: "Studio", sampledAt: now, stale: false) }
        return session
    }

    private func sessions(_ state: State) -> (waiting: [AgentSession], running: [AgentSession], unread: [AgentSession]) {
        switch state {
        case .empty: return ([], [], [])
        case .many:
            return ((0..<7).map { session($0, .waiting, minutesAgo: Double(4 + $0 * 9)) },
                    (7..<16).map { session($0, .working, minutesAgo: Double($0 % 4), remote: $0 == 12) },
                    (16..<25).map { session($0, .idle, unread: true, minutesAgo: Double(30 + $0 * 7)) })
        default:
            return ([session(0, .waiting, minutesAgo: 4), session(1, .waiting, minutesAgo: 1)],
                    [session(3, .working, minutesAgo: 0), session(4, .working, minutesAgo: 1), session(5, .working, minutesAgo: 0, remote: true),
                     session(6, .working, minutesAgo: 50)],
                    [session(7, .idle, unread: true, minutesAgo: 28), session(8, .idle, unread: true, minutesAgo: 85),
                     session(9, .idle, unread: true, minutesAgo: 183)])
        }
    }

    private func brief(_ state: State, board running: [AgentSession]) -> (stuck: [BriefItem], all: [BriefItem]) {
        guard state == .stuck, let quiet = running.last else { return ([], []) }
        let item = BriefItem(chatID: quiet.id, chatTitle: quiet.title, kind: .stuck, headline: "No new output for 50 min", sourceHash: "s",
                             chatUpdatedAt: at(14, 55), createdAt: at(15, 30))
        return ([item], [item])
    }

    /// A day of many short bursts (10 s – 5 min, in a few clusters), as real agent logs look.
    private func activity(for ids: [String]) -> DailyActivity {
        var seed: UInt64 = 7
        func next(_ range: ClosedRange<Double>) -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return range.lowerBound + Double(seed >> 33) / Double(1 << 31) * (range.upperBound - range.lowerBound)
        }
        var chats: [DailyActivity.Chat] = []
        for (index, id) in ids.enumerated() where !id.hasPrefix("remote:") {
            var active: [DateInterval] = []
            var cursor = at(9, 40).addingTimeInterval(next(0...(4.5 * 3600)))
            for _ in 0..<Int(next(1...3)) {
                for _ in 0..<Int(next(3...16)) {
                    let length = next(10...300)
                    guard cursor.addingTimeInterval(length) < now else { break }
                    active.append(DateInterval(start: cursor, duration: length))
                    cursor = cursor.addingTimeInterval(length + next(20...200))
                }
                cursor = cursor.addingTimeInterval(next(900...3000))
            }
            // Chats working now: a burst running up to now.
            if index >= 2 && index < 6 { active.append(DateInterval(start: now.addingTimeInterval(-next(60...600)), end: now)) }
            active.sort { $0.start < $1.start }
            var merged: [DateInterval] = []
            for piece in active {
                if let last = merged.last, piece.start <= last.end { merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, piece.end)) }
                else { merged.append(piece) }
            }
            chats.append(DailyActivity.Chat(id: id, provider: id.hasPrefix("codex") ? .codex : .claude, folder: "/work/focustown",
                                            turns: Int(next(2...14)), replies: 6, questions: index == 0 ? 1 : 0, lastAt: merged.last?.end ?? now,
                                            title: nil, active: merged.isEmpty ? nil : merged))
        }
        var turns = Array(repeating: 0, count: 24), replies = Array(repeating: 0, count: 24)
        for hour in 9...15 { turns[hour] = 10; replies[hour] = 30 }
        return DailyActivity(day: dayStart, turnsByHour: turns, repliesByHour: replies, questions: 3, firstTurn: at(9, 40), lastTurn: now,
                             chats: chats, partial: false)
    }

    // MARK: Page

    private func place(_ session: AgentSession) -> String {
        [session.remote?.hostName ?? "This Mac", URL(fileURLWithPath: session.cwd).lastPathComponent].joined(separator: " · ")
    }

    func data(_ state: State) -> (data: HomePageData, board: HomeBoard) {
        let lists = sessions(state)
        let notes = brief(state, board: lists.running)
        let board = HomeBoard.build(waiting: lists.waiting, running: lists.running, unread: lists.unread, briefStuck: notes.stuck)
        let tracking = state != .trackingOff
        let activity: DailyActivity? = state == .notLoaded ? nil : activity(for: board.needsYou.compactMap(\.session?.id) + board.working.map(\.id) + board.toRead.map(\.id))
        let turns: [String: Date] = Dictionary(uniqueKeysWithValues: board.working.prefix(3).enumerated().map { ($1.id, now.addingTimeInterval(-Double(18 + $0 * 47) * 60)) })
        let lanes = TodayLanes.build(HomeLanes.inputs(board, place: place, turnStart: { turns[$0] }), activity: activity,
                                     needsSince: HomeLanes.needsSince(board), brief: notes.all, window: day, isToday: true, now: now, calendar: calendar)
        let window = DayRibbonLayout.laneWindow(day: day, pieces: HomeLanes.pieces(Array(lanes.prefix(HomeLanes.cap))), now: now, calendar: calendar)
        let stats = HomeStats.cells(working: board.working.count, longestTurn: turns.values.map { now.timeIntervalSince($0) }.max(),
                                    machines: board.working.map { $0.session.remote?.hostName ?? "This Mac" }, waiting: board.needsYou.count,
                                    oldestWaiting: board.needsYou.map(\.since).min(), activity: activity, toRead: board.toRead.count,
                                    stuck: notes.stuck.count, newestToRead: board.toRead.map(\.session.updatedAt).max(),
                                    day: tracking ? .tracked(tracked, away: 32 * 60, awayPartial: false) : .value(dollars: 41.7, tokens: 3_250_000),
                                    calendar: calendar)
        let cells = HomePage<EmptyView, EmptyView>.statCells(stats, waiting: board.needsYou.count,
                                                             avatars: board.needsYou.compactMap { $0.session.map { ($0.id, $0.provider) } },
                                                             tracked: tracked, tracking: tracking, paused: false, openToday: {})
        let usage = [ProviderUsage(id: .claude, updatedAt: now, windows: [
                        UsageWindow(id: "session", title: "5-hour", remainingPercent: 62, resetsAt: now.addingTimeInterval(3 * 3600 + 12 * 60)),
                        UsageWindow(id: "week", title: "Weekly", remainingPercent: 41, resetsAt: now.addingTimeInterval(3 * 86_400 + 5 * 3600))]),
                     ProviderUsage(id: .codex, updatedAt: now, windows: [
                        UsageWindow(id: "session", title: "5-hour", remainingPercent: 88, resetsAt: now.addingTimeInterval(4 * 3600)),
                        UsageWindow(id: "week", title: "Weekly", remainingPercent: 17, resetsAt: now.addingTimeInterval(86_400))])]
        let machines = state == .empty ? [HomeMachineRowData(id: "local", name: "This Mac", reachable: true, line: "Quiet", local: true)]
            : [HomeMachineRowData(id: "local", name: "This Mac", reachable: true, line: "\(board.working.count - 1) working · \(board.needsYou.count) need you", local: true),
               HomeMachineRowData(id: "studio", name: "Studio", reachable: true, line: "1 working · checked 8 s ago", local: false),
               HomeMachineRowData(id: "nas", name: "Basement server", reachable: state != .stuck && state != .busy ? true : false,
                                  line: state == .stuck || state == .busy ? "Unreachable since 14:02 · retrying in 30 s" : "Quiet · checked 1 min ago", local: false)]
        let data = HomePageData(now: now, sentence: HomeBoard.sentenceRuns(needsYou: board.needsYou.count, working: board.working.count,
                                                                            toRead: board.toRead.count, shipped: state == .empty ? nil : 4),
                                stats: cells, lanes: lanes, laneWindow: window.window, day: day, scanned: activity != nil,
                                board: boardData(board, stuck: !notes.stuck.isEmpty), machines: machines,
                                limits: state == .usageOff ? nil : HomeLimits.rows(usage, shown: [.claude, .codex], now: now))
        return (data, board)
    }

    private func boardData(_ board: HomeBoard, stuck: Bool) -> HomeBoardData {
        let needs = board.needsYou.prefix(HomeChatSections.needsCap).enumerated().map { index, entry in
            HomeNeedsCardData(id: entry.id, title: entry.title, tags: [entry.session.map(place) ?? "This Mac", entry.session?.provider == .codex ? "Codex · gpt-5.5" : "Claude · Opus 5.5"],
                              when: HomeBoard.waitText(entry.since, waiting: entry.waiting, now: now),
                              message: index == 0 ? "Asks whether to merge #412 into staging now that CI is green, or wait for the device check." : "Waiting for your approval",
                              draft: index == 0 ? HomeDraftData(text: "Merge it now, then run the device check on staging.", label: "Draft", sendHelp: "Send this reply to the chat") : nil,
                              handOff: index == 0 ? nil : (entry.session?.provider == .codex ? "Open in Codex" : "Open in Claude"), dismissable: index == 0)
        }
        let stops: [HomeBoard.StopOffer] = [.stop, .openInProvider, .stop, .elsewhere]
        let working = board.working.prefix(HomeChatSections.workingCap).enumerated().map { index, entry in
            HomeWorkingCardData(id: entry.id, title: entry.session.title,
                                state: entry.stuck?.headline ?? "Working in \(URL(fileURLWithPath: entry.session.cwd).lastPathComponent)",
                                machine: entry.session.remote?.hostName ?? "This Mac", time: ["turn 18 min", "turn 1 h 05 min", "active just now", "turn 6 min"][index % 4],
                                stop: stops[index % stops.count], handOff: "Open in Claude", stuck: entry.stuck != nil)
        }
        let outcomes = ["Opened PR #1412, tests pass, one flaky test noted.", "Three layout options written up; nothing committed.", nil]
        let read = board.toRead.prefix(HomeChatSections.readCap).enumerated().map { index, entry in
            HomeReadRowData(id: entry.id, title: entry.session.title, outcome: outcomes[index % outcomes.count], time: TodayClock.hm(entry.session.updatedAt, calendar: calendar))
        }
        return HomeBoardData(needsYou: Array(needs), needsTotal: board.needsYou.count, working: Array(working), workingTotal: board.working.count,
                             toRead: Array(read), toReadTotal: board.toRead.count)
    }

    /// A stand-in for the composer (the real one needs the Orchestrator's store, which reads its files).
    static var composer: some View {
        HStack {
            Text("Ask the Orchestrator…").font(.system(size: 14)).foregroundStyle(AppAppearance.tertiary)
            Spacer()
            Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(Circle().fill(AppAppearance.tertiary.opacity(0.35)))
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 3)
        .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(AppAppearance.separator))
    }

    static var below: some View {
        VStack(alignment: .leading, spacing: 14) {
            HomeSectionHeader(title: "Projects") { Button("All worktrees") {} }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 18) {
                ForEach(["focustown", "burro", "support-console"], id: \.self) { name in
                    BenchCard(title: name, symbol: nil, counts: HomeCounts(), quiet: "Quiet", help: name) {}
                }
            }
        }
    }

    /// The page as HomeView lays it out, over a still aquarium of the board's chats.
    func page(_ state: State, width: CGFloat) -> some View {
        let (data, board) = self.data(state)
        let ask = HomeAskCardData(footer: "Triage: 9 today · On", footerHelp: "Turn automatic triage off", lastAnswer: "Last answer 2h ago · Open")
        let page = HomePage(data: data, actions: HomePageActions(), todos: todos, notes: notes, queueTab: .constant(nil)) {
            HomeAskCardContent(data: ask, inline: true) { Self.composer }
        } below: {
            Self.below
        }
        .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 48)
        .frame(maxWidth: 1220).frame(maxWidth: .infinity)
        return page.background { StillAquarium(fish: Self.fish(board)) }
    }

    static func fish(_ board: HomeBoard) -> [AquariumFish] {
        AquariumFish.school(running: board.working.map(\.session), waiting: board.needsYou.compactMap(\.session), today: board.toRead.map(\.session))
    }

    static func render<V: View>(_ view: V, width: CGFloat, dark: Bool, to url: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: width).background(AppAppearance.background))
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
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

/// The aquarium drawn once, synchronously (the live one renders asynchronously at 6 fps, which an
/// offscreen capture can miss), with the app's own ink and amber.
struct StillAquarium: View {
    var fish: [AquariumFish]
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let ink: Color = scheme == .dark ? .white : .black
        Canvas { context, size in
            Aquarium.draw(&context, size: size, t: 1_000, ink: ink, amber: CoverField.amber, fish: fish, highlight: nil)
        }
        .allowsHitTesting(false)
    }
}
