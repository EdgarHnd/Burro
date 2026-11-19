import AppKit
import SwiftUI
import XCTest
@testable import Burro
@testable import BurroCore

/// Renders the window (sidebar, strip and page), the compact and expanded notch and the menu-bar
/// popover with invented chats to PNGs for a visual check. Skipped unless BURRO_CHROME_SNAPSHOTS=1;
/// writes to dist/screenshots (gitignored) or BURRO_SNAPSHOT_DIR. Draws offscreen; never sends,
/// checks or reads a real chat (drafts, questions, checks and turn times come from a fixture). The
/// window renders put AppShell around side-effect-free pages: a Home stand-in built from Home's
/// plain-value views over the aquarium, the Chats list with no chat open (so no transcript is read
/// and no Claude check runs), and Worktrees over invented worktrees. Grey dots stand in for the
/// traffic lights, which an offscreen window doesn't draw.
@MainActor final class ChromeSnapshotTests: XCTestCase {
    private let now = Date()

    private func chat(_ id: String, _ title: String, _ provider: AgentProvider, _ state: AgentState, folder: String,
                      minutesAgo: Double, unread: Bool = false) -> AgentSession {
        AgentSession(id: id, provider: provider, title: title, cwd: "/Users/sample/Dev/\(folder)", state: state,
                     updatedAt: now.addingTimeInterval(-minutesAgo * 60), evidence: "fixture", hasUnreadResult: unread)
    }
    private var sessions: [AgentSession] {
        [chat("codex:11111111-1111-4111-8111-111111111111", "Streak ladder config", .codex, .waiting, folder: "focustown", minutesAgo: 4),
         chat("claude:22222222-2222-4222-8222-222222222222", "Support dashboard alerts", .claude, .waiting, folder: "support-console", minutesAgo: 1),
         chat("codex:33333333-3333-4333-8333-333333333333", "iOS hang on resume", .codex, .working, folder: "focustown", minutesAgo: 0),
         chat("claude:44444444-4444-4444-8444-444444444444", "Godot shader warm-up", .claude, .working, folder: "autumn-scene", minutesAgo: 0),
         chat("codex:55555555-5555-4555-8555-555555555555", "Android 2.2.24 release notes", .codex, .working, folder: "focustown", minutesAgo: 1),
         chat("codex:66666666-6666-4666-8666-666666666666", "Twitter link setup", .codex, .idle, folder: "focustown", minutesAgo: 30, unread: true),
         chat("claude:77777777-7777-4777-8777-777777777777", "Study with friends layout", .claude, .idle, folder: "focustown", minutesAgo: 80, unread: true),
         chat("codex:88888888-8888-4888-8888-888888888888", "Audit repository security", .codex, .idle, folder: "burro", minutesAgo: 120, unread: true)]
    }
    private var fixture: NotchFixture {
        let streak = sessions[0].id, support = sessions[1].id
        return NotchFixture(
            drafts: [streak: OrchestratorAction(kind: .reply, createdAt: now, text: "Merge it now, then run the device check on staging.", chatID: streak)],
            questions: [streak: "Merge #412 into staging now that CI is green, or wait for the device check?"],
            checks: [support: ChatReply.ClaudeCheck(problem: "Claude is waiting for you in this chat (a question or an approval). Attach to it to answer.",
                                                    attach: "a1b2c3d4", open: true, background: true)],
            turns: [sessions[2].id: 134, sessions[3].id: 41 * 60 + 12])
    }

    private func makeStore(_ sessions: [AgentSession]) throws -> AppStore {
        let suite = "burro.chrome.snapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "notchEnabled"); defaults.set(false, forKey: "usageEnabled"); defaults.set(false, forKey: "discover")
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults)
        store.didCheckAgents = true
        store.agentActivity = AgentActivitySnapshot(sessions: sessions, warnings: [], sampledAt: now)
        return store
    }

    func testRenderChromeSnapshots() throws {
        guard ProcessInfo.processInfo.environment["BURRO_CHROME_SNAPSHOTS"] == "1" else { throw XCTSkip("set BURRO_CHROME_SNAPSHOTS=1") }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = ProcessInfo.processInfo.environment["BURRO_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("dist/screenshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let store = try makeStore(sessions)
        let notch = NotchController()

        for dark in [true, false] {
            let suffix = dark ? "dark" : "light"
            try render(MenuBarPopover(store: store, notch: notch, focusedToday: 4 * 3600 + 4 * 60, draftCount: 2), size: nil, dark: dark,
                       to: out.appendingPathComponent("chrome-menubar-\(suffix).png"))
        }

        // The window: Home, Chats and Worktrees at a roomy and the minimum size, dark and light.
        // 1000 points is under SidebarLayout's narrow threshold, so those show the rail.
        let window = try makeStore(sessions)
        window.didCheckAgents = false // Chats: keeps the no-chat pane from looking a chat up.
        window.remoteSelection = "fixture:none"
        window.didScan = true
        window.snapshot = ScanSnapshot(worktrees: worktrees, agents: [], warnings: [], scannedAt: now, duration: 0.4)
        let sizes = [CGSize(width: 1440, height: 900), CGSize(width: 1000, height: 700)]
        for dark in [true, false] {
            let suffix = dark ? "dark" : "light"
            for size in sizes {
                for page in [AppPage.home, .remote, .worktrees] {
                    window.go(to: page)
                    try render(shell(window, page: page), size: size, dark: dark,
                               to: out.appendingPathComponent("chrome-window-\(page.rawValue)-\(Int(size.width))-\(suffix).png"))
                }
            }
        }
        // Collapsed by choice at full width, after a jump (the back pill), and the full sidebar alone.
        window.go(to: .today)
        window.page = .timeline
        window.sidebarCollapsed = true
        try render(shell(window, page: .home), size: sizes[0], dark: true, to: out.appendingPathComponent("chrome-window-rail-timeline-1440-dark.png"))
        window.sidebarCollapsed = false
        window.go(to: .remote)
        for dark in [true, false] {
            try render(Sidebar(store: window, collapsed: false, toggle: {}).frame(width: SidebarLayout.fullWidth), size: CGSize(width: SidebarLayout.fullWidth, height: 900),
                       dark: dark, to: out.appendingPathComponent("chrome-sidebar-\(dark ? "dark" : "light").png"))
        }
        // The crew empty, and longer than its cap ("Show all N in Chats"), full and as a rail.
        let quiet = try makeStore([])
        try render(shell(quiet, page: .home), size: sizes[0], dark: false, to: out.appendingPathComponent("chrome-window-crew-empty-1440-light.png"))
        let crowd = try makeStore(sessions + (1...9).map { index in
            chat("codex:9\(index)999999-9999-4999-8999-99999999999\(index)", "Background task \(index): long running migration step", index % 2 == 0 ? .codex : .claude,
                 .working, folder: "focustown", minutesAgo: Double(index * 7))
        })
        try render(Sidebar(store: crowd, collapsed: false, toggle: {}).frame(width: SidebarLayout.fullWidth), size: CGSize(width: SidebarLayout.fullWidth, height: 900),
                   dark: true, to: out.appendingPathComponent("chrome-sidebar-crew-long-dark.png"))
        try render(Sidebar(store: crowd, collapsed: true, toggle: {}).frame(width: SidebarLayout.railWidth), size: CGSize(width: SidebarLayout.railWidth, height: 900),
                   dark: true, to: out.appendingPathComponent("chrome-rail-crew-long-dark.png"))

        // Expanded: needs you + working, then working only, then nothing but results to read.
        try renderExpanded(store, name: "chrome-notch-expanded", out: out)
        try renderExpanded(try makeStore(Array(sessions[2...])), name: "chrome-notch-expanded-working", out: out)
        try renderExpanded(try makeStore(Array(sessions[5...])), name: "chrome-notch-expanded-quiet", out: out)
        // Compact: idle, working, needs you; with a camera housing and without.
        let compactStates: [(String, [AgentSession])] = [("idle", []), ("working", Array(sessions[2...4])), ("needs", sessions)]
        for (name, list) in compactStates {
            let compactStore = try makeStore(list)
            for safeTop in [CGFloat(32), 0] {
                let presentation = NotchPresentation()
                presentation.compactGeometry = NotchGeometry.layout(screen: CGRect(x: 0, y: 0, width: 1512, height: 982),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950), safeTop: safeTop, hardwareWidth: safeTop > 0 ? 200 : 0, expanded: false)
                let size = presentation.compactGeometry.frame.size
                let view = notchView(compactStore, presentation, compact: true)
                    .frame(width: size.width, height: size.height)
                    .background(Color.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
                try render(view.padding(12), size: CGSize(width: size.width + 24, height: size.height + 24), dark: true,
                           background: Color(white: 0.55), to: out.appendingPathComponent("chrome-notch-compact-\(name)-\(safeTop > 0 ? "notch" : "flat").png"))
            }
        }
    }

    private var worktrees: [Worktree] {
        func tree(_ repo: String, _ branch: String, state: AgentState?, changed: Int = 0, hoursAgo: Double, primary: Bool = false) -> Worktree {
            let path = "/sample/\(repo)/\(branch.replacingOccurrences(of: "/", with: "-"))"
            var facts = GitFacts()
            facts.base = "origin/main"; facts.changed = changed; facts.merged = changed == 0; facts.lastCommit = now.addingTimeInterval(-hoursAgo * 3600)
            let agents = state.map { [AgentSession(id: UUID().uuidString, provider: .claude, title: branch, cwd: path, state: $0,
                                                   updatedAt: now.addingTimeInterval(-hoursAgo * 3600), evidence: "fixture")] } ?? []
            return Worktree(path: path, repository: repo, repositoryPath: "/sample/\(repo)/main", branch: branch,
                            head: String(repeating: "c", count: 40), isPrimary: primary, isLocked: false, isMissing: false,
                            isPrunable: false, facts: facts, agents: agents, processes: [], protectedByUser: false,
                            assessment: Assessment(level: .keep, reasons: []))
        }
        return [tree("lighthouse", "main", state: nil, hoursAgo: 30, primary: true),
                tree("lighthouse", "feat/tide-tables", state: .working, changed: 6, hoursAgo: 0.2),
                tree("lighthouse", "fix/lamp-flicker", state: .idle, changed: 2, hoursAgo: 3),
                tree("lighthouse", "release/2.4-notes", state: .waiting, hoursAgo: 1),
                tree("ledger", "main", state: nil, hoursAgo: 50, primary: true),
                tree("ledger", "feat/csv-import", state: nil, hoursAgo: 96)]
    }

    /// AppShell around a page that starts nothing, with stand-in traffic lights.
    private func shell(_ store: AppStore, page: AppPage) -> some View {
        AppShell(store: store) {
            switch page {
            case .remote: ChatsView(store: store)
            case .worktrees: WorktreeListView(store: store)
            default: self.homeStandIn(store)
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.gray.opacity(0.7)).frame(width: 12, height: 12) } }
                .padding(.leading, 14).padding(.top, 10)
        }
        .modifier(AppTheme())
    }

    /// Home's dashboard from plain values over the aquarium, laid out as HomeView does (HomeView
    /// itself would check Claude chats and read the Orchestrator's history, to-dos and notes): the
    /// store's own board, lanes without bars (no scan here), temporary to-dos and notes.
    private func homeStandIn(_ store: AppStore) -> some View {
        let summary = store.homeSummary
        let fish = AquariumFish.school(running: summary.running, waiting: summary.needsYou, scheduled: summary.scheduled, today: summary.today)
        let board = HomeBoard.build(waiting: summary.needsYou, running: summary.running, unread: summary.unread)
        let calendar = Calendar.current, start = calendar.startOfDay(for: now)
        let day = DateInterval(start: start, duration: 86_400)
        let place: (AgentSession) -> String = { [$0.remote?.hostName ?? "This Mac", URL(fileURLWithPath: $0.cwd).lastPathComponent].joined(separator: " · ") }
        let lanes = TodayLanes.build(HomeLanes.inputs(board, place: place, turnStart: { _ in nil }), activity: nil, needsSince: HomeLanes.needsSince(board),
                                     brief: [], window: day, isToday: true, now: now, calendar: calendar)
        let stats = HomeStats.cells(working: board.working.count, longestTurn: nil, machines: board.working.map { _ in "This Mac" },
                                    waiting: board.needsYou.count, oldestWaiting: board.needsYou.map(\.since).min(), activity: nil,
                                    toRead: board.toRead.count, stuck: 0, newestToRead: board.toRead.map(\.session.updatedAt).max(),
                                    day: .value(dollars: nil, tokens: nil), calendar: calendar)
        let data = HomePageData(
            now: now, sentence: HomeBoard.sentenceRuns(needsYou: board.needsYou.count, working: board.working.count, toRead: board.toRead.count),
            stats: HomePage<EmptyView, EmptyView>.statCells(stats, waiting: board.needsYou.count,
                                                            avatars: board.needsYou.compactMap { $0.session.map { ($0.id, $0.provider) } },
                                                            tracked: nil, tracking: false, paused: false, openToday: {}),
            lanes: lanes, laneWindow: DayRibbonLayout.laneWindow(day: day, pieces: HomeLanes.pieces(lanes), now: now, calendar: calendar).window,
            day: day, scanned: false,
            board: HomeBoardData(
                needsYou: board.needsYou.map { HomeNeedsCardData(id: $0.id, title: $0.title, tags: ["This Mac · focustown", "Codex · gpt-5.5"],
                                                                  when: "asked 4 min ago", message: "Waiting for your approval", draft: nil,
                                                                  handOff: "Open in Codex", dismissable: false) },
                needsTotal: board.needsYou.count,
                working: board.working.map { HomeWorkingCardData(id: $0.id, title: $0.session.title, state: "Working in focustown", machine: "This Mac",
                                                                 time: "turn 18 min", stop: .stop) },
                workingTotal: board.working.count,
                toRead: board.toRead.map { HomeReadRowData(id: $0.id, title: $0.session.title, outcome: nil, time: "21:17") }, toReadTotal: board.toRead.count),
            machines: [HomeMachineRowData(id: "local", name: "This Mac", reachable: true, line: "\(board.working.count) working", local: true)])
        let todos = TodoStore(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent("burro-chrome-todos-\(UUID().uuidString).json"), config: nil)
        let notes = NotesStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent("burro-chrome-notes-\(UUID().uuidString)"))
        return GeometryReader { geometry in
            ZStack(alignment: .top) {
                CoverBackdrop(running: summary.counts.running, waiting: summary.counts.waiting, fish: fish, hover: AquariumHover(), animate: false)
                ScrollView {
                    HomePage(data: data, actions: HomePageActions(), todos: todos, notes: notes, queueTab: .constant(nil)) {
                        HomeAskCardContent(data: HomeAskCardData(footer: "Triage: 3 today · On", footerHelp: ""), inline: true) { HomeSnapshotFixture.composer }
                    } below: {
                        HomeSnapshotFixture.below
                    }
                    .padding(.horizontal, 28).padding(.top, 34)
                    .frame(maxWidth: 1220).frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
            }
        }
        .background(AppAppearance.background)
    }

    private func notchView(_ store: AppStore, _ presentation: NotchPresentation, compact: Bool) -> NotchView {
        NotchView(store: store, presentation: presentation, onToggle: {}, onPin: {}, onCollapse: {}, onSelect: { _ in }, onInspect: { _ in },
                  onOpenDashboard: {}, onSelectPage: { _ in }, onNavigationBounds: { _ in }, onContentChange: {}, compact: compact, fixture: fixture)
    }

    private func renderExpanded(_ store: AppStore, name: String, out: URL) throws {
        let presentation = NotchPresentation()
        presentation.expanded = true
        func geometry() -> NotchGeometry {
            NotchGeometry.layout(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                                 safeTop: 32, hardwareWidth: 200, expanded: true, visibleAgents: presentation.visibleRows)
        }
        // First pass lets the list report its rows, as the controller would before sizing the panel.
        _ = try image(notchView(store, presentation, compact: false), size: geometry().frame.size, dark: true, background: .black)
        presentation.expandedGeometry = geometry()
        let size = presentation.expandedGeometry.frame.size
        let view = notchView(store, presentation, compact: false)
            .frame(width: size.width, height: size.height)
            .background(Color.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26))
        try render(view.padding(16), size: CGSize(width: size.width + 32, height: size.height + 32), dark: true,
                   background: Color(white: 0.55), to: out.appendingPathComponent("\(name).png"))
    }

    private func render<V: View>(_ view: V, size: CGSize?, dark: Bool, background: Color = AppAppearance.background, to url: URL) throws {
        try image(view, size: size, dark: dark, background: background).write(to: url)
    }

    private func image<V: View>(_ view: V, size: CGSize?, dark: Bool, background: Color) throws -> Data {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.background(background))
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size ?? CGSize(width: 400, height: 400)), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        let fitted = size ?? host.fittingSize
        host.frame.size = fitted
        window.setContentSize(fitted)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let bounds = host.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
