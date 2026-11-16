import AppKit
import SwiftUI
import XCTest
@testable import Burro
@testable import BurroCore

/// Renders the top bar, the compact and expanded notch and the menu-bar popover with invented
/// chats to PNGs for a visual check. Skipped unless BURRO_CHROME_SNAPSHOTS=1; writes to
/// dist/screenshots (gitignored) or BURRO_SNAPSHOT_DIR. Draws offscreen; never sends, checks or
/// reads a real chat (drafts, questions, checks and turn times come from a fixture).
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
            try render(TopBar(store: store, notch: notch), size: CGSize(width: 1440, height: 52), dark: dark, to: out.appendingPathComponent("chrome-topbar-1440-\(suffix).png"))
            try render(TopBar(store: store, notch: notch), size: CGSize(width: 1000, height: 52), dark: dark, to: out.appendingPathComponent("chrome-topbar-1000-\(suffix).png"))
            try render(MenuBarPopover(store: store, notch: notch, focusedToday: 4 * 3600 + 4 * 60, draftCount: 2), size: nil, dark: dark,
                       to: out.appendingPathComponent("chrome-menubar-\(suffix).png"))
        }
        store.page = .worktrees
        try render(TopBar(store: store, notch: notch), size: CGSize(width: 1000, height: 52), dark: true, to: out.appendingPathComponent("chrome-topbar-1000-worktrees-dark.png"))
        store.page = .home

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
