import AppKit
import SwiftUI
import XCTest
@testable import Burro
@testable import BurroCore

/// Renders the Orchestrator page's Brief tab with invented chats, drafts, notes and budget to PNGs
/// for a visual check. Skipped unless BURRO_ORCH_SNAPSHOTS=1; writes to dist/screenshots
/// (gitignored) or BURRO_SNAPSHOT_DIR. Draws offscreen; the page is fed preview data and never
/// reads the Brief, proposals, memory or runs files, and nothing is sent or started.
@MainActor final class OrchestratorSnapshotTests: XCTestCase {
    func testRenderOrchestratorSnapshots() throws {
        guard ProcessInfo.processInfo.environment["BURRO_ORCH_SNAPSHOTS"] == "1" else { throw XCTSkip("set BURRO_ORCH_SNAPSHOTS=1") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = ProcessInfo.processInfo.environment["BURRO_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("dist/screenshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let now = Date()
        let (store, budget) = try sampleStore(now: now)
        for dark in [true, false] {
            let suffix = dark ? "dark" : "light"
            try render(OrchestratorPageLayout(store: store, budget: budget, now: now), size: CGSize(width: 1440, height: 856), dark: dark,
                       to: out.appendingPathComponent("orchestrator-1440-\(suffix).png"))
        }
        try render(OrchestratorPageLayout(store: store, budget: budget, now: now), size: CGSize(width: 1040, height: 820), dark: true,
                   to: out.appendingPathComponent("orchestrator-1040-dark.png"))
        try render(OrchestratorPageLayout(store: store, budget: budget, now: now), size: CGSize(width: 760, height: 1100), dark: true,
                   to: out.appendingPathComponent("orchestrator-760-dark.png"))

        let (empty, emptyBudget) = try sampleStore(now: now, empty: true)
        try render(OrchestratorPageLayout(store: empty, budget: emptyBudget, now: now), size: CGSize(width: 1440, height: 856), dark: true,
                   to: out.appendingPathComponent("orchestrator-empty-1440-dark.png"))

        // Proposals whose Send Burro couldn't confirm (invented): a start on another machine and a reply.
        var remoteStart = OrchestratorAction(kind: .start, createdAt: now.addingTimeInterval(-600),
                                             text: "Fix the leaderboard reset boundary and open a draft PR.", machine: "Other Mac",
                                             agent: "claude", folder: "/Users/sample/Dev/focustown", model: "claude-opus-5-5", effort: "high")
        remoteStart.hostID = UUID().uuidString
        remoteStart.recordSend(text: remoteStart.text, outcome: .failure(RemoteLaunchError.notConfirmed(host: "Other Mac")), now: now)
        var reply = OrchestratorAction(kind: .reply, createdAt: now.addingTimeInterval(-300), text: "Approved. Push it and open a draft PR.",
                                       chatID: "codex:8a2d5f10-1c3e-4a55-8b0f-2e7d9c4b6a22", chatTitle: "Support dashboard alerts", machine: "This Mac")
        reply.recordSend(text: reply.text, outcome: .failure(ReplyNotConfirmed("Codex's app server didn't answer in time.")), now: now)
        for dark in [true, false] {
            let cards = VStack(alignment: .leading, spacing: 14) {
                OrchestratorActionCard(store: store, action: remoteStart)
                OrchestratorActionCard(store: store, action: reply)
                Spacer(minLength: 0)
            }.padding(20)
            try render(cards, size: CGSize(width: 720, height: 520), dark: dark,
                       to: out.appendingPathComponent("orchestrator-unconfirmed-\(dark ? "dark" : "light").png"))
        }
    }

    private func sampleStore(now: Date, empty: Bool = false) throws -> (AppStore, OrchestratorBudget) {
        let suite = "burro.orch.snapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults)
        let ago = { (minutes: Double) in now.addingTimeInterval(-minutes * 60) }
        let windows = [UsageWindow(id: "session", title: "Session", remainingPercent: 62, resetsAt: Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: now)),
                       UsageWindow(id: "weekly", title: "Weekly", remainingPercent: 38, resetsAt: now.addingTimeInterval(4 * 86_400))]
        if empty {
            store.orchestrator.preview(history: [])
            store.orchestrator.preview(actions: [], memory: [], runsToday: [])
            store.brief.preview(file: BriefFile(), runsToday: 0, lastRun: nil)
            let budget = OrchestratorBudget(runsToday: 0, cap: 150, runs: [], claude: nil, enabled: true, gate: .open)
            return (store, budget)
        }
        let streak = "codex:6f1c1a52-6b7e-4b07-9d1e-3f1b8a0e1a11", alerts = "codex:8a2d5f10-1c3e-4a55-8b0f-2e7d9c4b6a22"
        store.agentActivity = AgentActivitySnapshot(sessions: [
            AgentSession(id: streak, provider: .codex, title: "Streak ladder config", cwd: "/Users/sample/Dev/focustown", state: .waiting,
                         updatedAt: ago(4), evidence: "Fixture"),
            AgentSession(id: alerts, provider: .codex, title: "Support dashboard alerts", cwd: "/Users/sample/Dev/support", state: .waiting,
                         updatedAt: ago(1), evidence: "Fixture"),
        ], warnings: [], readState: .empty, sampledAt: now)

        let draftA = OrchestratorAction(kind: .reply, createdAt: ago(4), text: "Merge it now, then run the device check on staging.",
                                        chatID: streak, chatTitle: "Streak ladder config", machine: "This Mac", conversation: BriefDrafts.triageConversation)
        let draftB = OrchestratorAction(kind: .reply, createdAt: ago(1), text: "Approved. Push it and open a draft PR against main.",
                                        chatID: alerts, chatTitle: "Support dashboard alerts", machine: "This Mac", conversation: BriefDrafts.triageConversation)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-orch-snapshot-\(UUID().uuidString)/focustown")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let start = OrchestratorAction(kind: .start, createdAt: ago(2),
                                       text: "Weekly leaderboard doesn't reset for players in UTC+ timezones (reports since 2.2.22). Find where the reset boundary is computed, fix it against the server week, and add a test that covers UTC+13 and UTC-11. Open a draft PR; don't touch the save format without asking.",
                                       agent: "claude", folder: folder.path, model: "claude-opus-5-5", effort: "high", conversation: "today")
        var todo = OrchestratorAction(kind: .addTodo, createdAt: ago(2), text: "Check the store screenshots", status: .applied)
        todo.appliedAt = ago(2)
        store.orchestrator.preview(actions: [draftA, draftB, start, todo], memory: [
            OrchestratorMemoryEntry(scope: OrchestratorMemoryEntry.global, text: "Release branches are named release/x.y.z.", source: .user, createdAt: ago(9000)),
            OrchestratorMemoryEntry(scope: OrchestratorMemoryEntry.global, text: "Never push to main; always a draft PR.", source: .user, createdAt: ago(8000)),
            OrchestratorMemoryEntry(scope: OrchestratorMemoryEntry.global, text: "Godot work goes to Other Mac.", source: .orchestrator, createdAt: ago(7000)),
            OrchestratorMemoryEntry(scope: OrchestratorMemoryEntry.global, text: "Quiet hours 23:00–08:00: don't notify.", source: .user, createdAt: ago(6000)),
            OrchestratorMemoryEntry(scope: OrchestratorMemoryEntry.global, text: "Prefer small PRs.", source: .user, createdAt: ago(5000)),
        ], runsToday: [OrchestratorRun(at: ago(200), trigger: "triage", model: "claude-haiku-5-5", costUSD: 0.12),
                       OrchestratorRun(at: ago(3), trigger: "ask", model: Orchestrator.model, costUSD: 0.30)])
        store.orchestrator.preview(history: [
            ChatMessage(id: 0, kind: .user, text: "Can someone pick up the leaderboard reset bug in focustown? This Mac is busy, use the other one. And remind me to check the store screenshots tomorrow.", at: ago(3)),
            ChatMessage(id: 1, kind: .tool, text: "", tool: "overview", output: "Machines: …"),
            ChatMessage(id: 2, kind: .tool, text: "focustown", tool: "start_chat", output: "Proposal \(start.id) recorded."),
            ChatMessage(id: 3, kind: .tool, text: "", tool: "add_todo", output: "To-do action \(todo.id) recorded."),
            ChatMessage(id: 4, kind: .assistant, text: "This Mac has two chats running, so I'd put it on Other Mac, which is idle. Here is the chat I'd start; it uses Opus at high effort because the reset touches the save format.", at: ago(2)),
        ])
        store.brief.preview(file: BriefFile(items: [
            BriefItem(chatID: streak, chatTitle: "Streak ladder config", machine: "This Mac", kind: .decision, headline: "Asks whether to merge #412",
                      question: "Merge #412 into staging now that CI is green, or wait for the device check?", proposalID: draftA.id,
                      sourceHash: "a", createdAt: ago(4)),
            BriefItem(chatID: alerts, chatTitle: "Support dashboard alerts", machine: "Other Mac", kind: .blocked, headline: "Wants to push",
                      question: "Wants approval to push feature/alert-routing.", proposalID: draftB.id, sourceHash: "b", createdAt: ago(1)),
            BriefItem(chatID: "codex:t3", chatTitle: "Twitter link setup", kind: .done, headline: "opened PR #1412, tests pass.", sourceHash: "c", createdAt: ago(30)),
            BriefItem(chatID: "codex:t4", chatTitle: "Study with friends layout", kind: .done, headline: "three options written up.", sourceHash: "d", createdAt: ago(40)),
            BriefItem(chatID: "codex:t5", chatTitle: "Audit repository security", kind: .done, headline: "clean, two updates suggested.", sourceHash: "e", createdAt: ago(50)),
            BriefItem(chatID: "claude:t6", chatTitle: "Godot shader warm-up", machine: "Other Mac", kind: .stuck, headline: "No new output for 52 min",
                      sourceHash: "f", createdAt: ago(5)),
        ]), runsToday: 9, lastRun: ago(3))
        let budget = OrchestratorBudget(runsToday: 9, cap: 150, runs: store.orchestrator.runsToday, claude: windows, enabled: true, gate: .open)
        return (store, budget)
    }

    private func render<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(AppAppearance.background))
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
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
