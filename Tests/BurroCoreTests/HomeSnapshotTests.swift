import AppKit
import SwiftUI
import XCTest
@testable import Burro
@testable import BurroCore

/// Renders Home's new layout with invented chats, to-dos and machines to PNGs for a visual check.
/// Skipped unless BURRO_HOME_SNAPSHOTS=1; writes to dist/screenshots (gitignored) or BURRO_SNAPSHOT_DIR.
/// Draws the plain-value content views offscreen; never reads the owner's chats, Brief or activity.
@MainActor final class HomeSnapshotTests: XCTestCase {
    private let calendar = Calendar.current
    private var dayStart: Date { calendar.startOfDay(for: Date()) }
    private func at(_ hour: Int, _ minute: Double) -> Date { dayStart.addingTimeInterval(Double(hour) * 3600 + minute * 60) }

    private var board: HomeBoardData {
        HomeBoardData(
            needsYou: [
                HomeNeedsCardData(id: "a", title: "Streak ladder config", tags: ["This Mac · focustown", "Claude · Opus 5.5"],
                                  when: "asked 4 min ago",
                                  message: "Asks whether to merge #412 into staging now that CI is green, or wait for the device check.",
                                  draft: HomeDraftData(text: "Merge it now, then run the device check on staging.", label: "Draft",
                                                       sendHelp: "Send this reply to the chat"),
                                  handOff: nil, dismissable: true),
                HomeNeedsCardData(id: "b", title: "Support dashboard alerts", tags: ["Studio · support-console", "Codex · gpt-5.5"],
                                  when: "waiting 1 min", message: "Waiting for your approval", draft: nil, handOff: "Open in Codex",
                                  dismissable: false),
            ], needsTotal: 2,
            working: [
                HomeWorkingCardData(id: "w1", title: "iOS hang on resume", state: "Working in focustown", machine: "This Mac",
                                    time: "turn 18 min", stop: .stop),
                HomeWorkingCardData(id: "w2", title: "Android 2.2.24 release notes", state: "Working in focustown-android", machine: "This Mac",
                                    time: "active just now", stop: .openInProvider, handOff: "Open in Claude"),
                HomeWorkingCardData(id: "w3", title: "Godot shader warm-up", state: "No new output for 50 min", machine: "Studio",
                                    time: "turn 1 h 12 min", stop: .stop),
                HomeWorkingCardData(id: "w4", title: "Refactor the save format", state: "Working in focustown", machine: "This Mac",
                                    time: "turn 6 min", stop: .elsewhere),
            ], workingTotal: 4,
            toRead: [
                HomeReadRowData(id: "r1", title: "Twitter link setup", outcome: "Opened PR #1412, tests pass, one flaky test noted.", time: "21:17"),
                HomeReadRowData(id: "r2", title: "Study with friends layout", outcome: "Three layout options written up; nothing committed.", time: "20:20"),
                HomeReadRowData(id: "r3", title: "Audit repository security", outcome: nil, time: "18:42"),
            ], toReadTotal: 3)
    }

    private var ask: HomeAskCardData {
        HomeAskCardData(footer: "Triage: 9 today · On", footerHelp: "Turn automatic triage off", lastAnswer: "Last answer 2h ago · Open")
    }

    private var machines: [HomeMachineRowData] {
        [HomeMachineRowData(id: "local", name: "This Mac", reachable: true, line: "2 working · 1 needs you", local: true),
         HomeMachineRowData(id: "studio", name: "Studio", reachable: true, line: "1 working · checked 8 s ago", local: false),
         HomeMachineRowData(id: "nas", name: "Basement server", reachable: false, line: "Unreachable since 14:02 · retrying in 30 s", local: false)]
    }

    /// A stand-in for the composer (the real one needs the Orchestrator's store, which reads its files).
    private var composer: some View {
        HStack {
            Text("Ask the Orchestrator…").font(.system(size: 14)).foregroundStyle(AppAppearance.tertiary)
            Spacer()
            Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(Circle().fill(AppAppearance.tertiary.opacity(0.35)))
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 5)
        .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(AppAppearance.separator))
    }

    private func side(_ today: TodayStore, todos: TodoStore, notes: NotesStore) throws -> some View {
        let day = try XCTUnwrap(today.tracked)
        return VStack(spacing: 14) {
            HomeAskCardContent(data: ask) { self.composer }
            HomeActivityCard(tracker: today.tracker, day: day, now: at(18, 42),
                             awayAgentTime: 2 * 3600 + 40 * 60) {}
            HomeTodayCard(todos: todos, startChat: { _ in })
            HomeMachinesCardContent(rows: machines)
            HomeNotesCard(notes: notes) { _ in }
        }
    }

    private var lower: some View {
        VStack(alignment: .leading, spacing: 14) {
            HomeSectionHeader(title: "Projects") { Button("All worktrees") {} }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 18) {
                ForEach(["focustown", "burro", "support-console"], id: \.self) { name in
                    BenchCard(title: name, symbol: nil, counts: HomeCounts(), quiet: "Quiet", help: name) {}
                }
            }
        }
    }

    private func page(width: CGFloat, data: HomeBoardData, sentence: String, today: TodayStore, todos: TodoStore, notes: NotesStore) throws -> some View {
        let wide = width >= HomeView.twoColumnWidth
        let content = min(width, 1220) - 56
        let left = wide ? content - HomeView.sideWidth - 28 : content
        let top = VStack(alignment: .leading, spacing: 26) {
            HomeCover(sentence: sentence, now: at(20, 5))
            HomeBoardContent(data: data, actions: HomeBoardActions(), columns: left >= 780 ? 3 : left >= 460 ? 2 : 1)
        }
        let side = try side(today, todos: todos, notes: notes)
        return Group {
            if wide {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 34) { top; lower }.frame(maxWidth: .infinity, alignment: .leading)
                    side.frame(width: HomeView.sideWidth)
                }
            } else {
                VStack(alignment: .leading, spacing: 30) { top; side; lower }
            }
        }
        .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 40)
        .frame(maxWidth: 1220).frame(maxWidth: .infinity)
    }

    func testRenderHomeSnapshots() async throws {
        guard ProcessInfo.processInfo.environment["BURRO_HOME_SNAPSHOTS"] == "1" else { throw XCTSkip("set BURRO_HOME_SNAPSHOTS=1") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = ProcessInfo.processInfo.environment["BURRO_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("dist/screenshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let today = try await store()
        let todos = TodoStore(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent("burro-home-todos-\(UUID().uuidString).json"), config: nil)
        for text in ["New consumer support dashboard", "Upgrade Godot and the bridge", "Design the study-with-friends feature"] { todos.add(text) }
        let notesFolder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-home-notes-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: notesFolder) }
        let notes = NotesStore(folder: notesFolder)
        let sentence = HomeBoard.sentence(needsYou: 2, working: 3, toRead: 3, shipped: 4)

        for dark in [true, false] {
            let suffix = dark ? "dark" : "light"
            try render(page(width: 1440, data: board, sentence: sentence, today: today, todos: todos, notes: notes), width: 1440, dark: dark,
                       to: out.appendingPathComponent("home-1440-\(suffix).png"))
        }
        try render(page(width: 1100, data: board, sentence: sentence, today: today, todos: todos, notes: notes), width: 1100, dark: true,
                   to: out.appendingPathComponent("home-1100-dark.png"))
        try render(page(width: 760, data: board, sentence: sentence, today: today, todos: todos, notes: notes), width: 760, dark: true,
                   to: out.appendingPathComponent("home-760-dark.png"))
        var editing = board
        editing.needsYou[0].draft?.sending = true
        editing.needsYou[1].draft = HomeDraftData(text: "", label: "Draft", sent: "Sent. Codex picks it up on its next turn.", sendHelp: "")
        // Brief items whose chat closed: one the Claude app still has, one it doesn't, one on another machine.
        editing.needsYou += [
            HomeNeedsCardData(id: "c1", title: "Weekly Mac leftovers check", tags: ["This Mac", "Closed"], when: "asked 2 h ago",
                              message: "Found three idle node processes from yesterday's builds. Kill them?", draft: nil, handOff: nil,
                              dismissable: true, closed: .openInClaude),
            HomeNeedsCardData(id: "c2", title: "Nightly dependency audit", tags: ["This Mac", "Closed"], when: "asked 5 h ago",
                              message: "Two packages have new major versions. Upgrade now or pin them?", draft: nil, handOff: nil,
                              dismissable: true, closed: .closed),
            HomeNeedsCardData(id: "c3", title: "Studio disk cleanup", tags: ["Studio", "Not listed"], when: "asked 1 h ago",
                              message: "Clear the 40 GB of old simulator runtimes?", draft: nil, handOff: nil,
                              dismissable: true, closed: .notListed),
        ]
        editing.needsTotal = editing.needsYou.count
        try render(HomeBoardContent(data: editing, actions: HomeBoardActions()), width: 860, dark: true,
                   to: out.appendingPathComponent("home-sections-states-dark.png"))
        try render(page(width: 1440, data: HomeBoardData(), sentence: HomeBoard.sentence(needsYou: 0, working: 0, toRead: 0),
                        today: today, todos: todos, notes: notes), width: 1440, dark: false,
                   to: out.appendingPathComponent("home-empty-light.png"))
    }

    /// A tracker on a temporary folder holding an invented working day, and a Today store that has read it.
    private func store() async throws -> TodayStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-home-snapshot-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let log = ActivityLog(folder: folder)
        func span(_ bundle: String, _ app: String, _ from: Date, _ to: Date, _ title: String) -> ActivitySpan {
            ActivitySpan(ActivityPrivacy.key(bundleID: bundle, app: app, title: title, address: nil), start: from, end: to)
        }
        try log.append([
            span("com.apple.mail", "Mail", at(8, 30), at(9, 0), "Inbox"),
            span("com.apple.dt.Xcode", "Xcode", at(9, 0), at(11, 40), "HomeView.swift"),
            span("com.tinyspeck.slackmacgap", "Slack", at(11, 40), at(12, 10), "general — Slack"),
            span("com.figma.Desktop", "Figma", at(13, 30), at(14, 30), "Home"),
            span("com.apple.dt.Xcode", "Xcode", at(14, 30), at(17, 20), "HomeAttention.swift"),
        ])
        let suite = "burro.home.snapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let tracker = ActivityTracker(defaults: defaults, log: log)
        tracker.enabled = true
        let today = TodayStore(defaults: defaults, tracker: tracker)
        today.refreshTracked()
        for _ in 0..<200 where today.tracked == nil { try await Task.sleep(for: .milliseconds(10)) }
        _ = try XCTUnwrap(today.tracked)
        return today
    }

    private func render<V: View>(_ view: V, width: CGFloat, dark: Bool, to url: URL) throws {
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
