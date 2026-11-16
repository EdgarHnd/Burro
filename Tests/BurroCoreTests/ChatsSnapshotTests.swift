import AppKit
import SwiftUI
import XCTest
@testable import Burro
@testable import BurroCore

/// Renders the Chats page's panes with invented chats to PNGs for a visual check. Skipped unless
/// BURRO_CHATS_SNAPSHOTS=1; writes to dist/screenshots (gitignored) or BURRO_SNAPSHOT_DIR. Uses the
/// page's layout views with plain values only: no store, no transcript reads, no provider calls.
@MainActor final class ChatsSnapshotTests: XCTestCase {
    private let now = Date()
    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    private func chat(_ title: String, _ state: AgentState, unread: Bool = false, minutes: Double, id: String,
                      machine: String? = nil, provider: AgentProvider = .claude) -> AgentSession {
        var session = AgentSession(id: id, provider: provider, title: title, cwd: "/tmp", state: state, updatedAt: ago(minutes), evidence: "fixture")
        session.hasUnreadResult = unread
        if let machine { session.remote = RemoteOrigin(hostID: UUID(), hostName: machine, sampledAt: now, stale: false) }
        return session
    }

    /// (chat, preview a scan already has, folder).
    private var chats: [(AgentSession, String?, String)] {
        var list: [(AgentSession, String?, String)] = [
            (chat("Weekly release train", .idle, minutes: 60 * 24 * 3, id: "pin"), "iOS 2.2.24 in review, Android at 20% rollout.", "focustown-rn-godot"),
            (chat("Streak ladder config", .waiting, minutes: 4, id: "ask1"), "Merge **#412** into `staging` now, or wait for the device check?", "focustown-rn-godot"),
            (chat("Support dashboard alerts", .waiting, minutes: 1, id: "ask2", machine: "Studio", provider: .codex), nil, "support-console"),
            (chat("iOS hang on resume", .working, minutes: 36, id: "hang"), nil, "focustown-rn-godot"),
            (chat("Player house upgrades and restoration flow", .working, minutes: 60 * 3.2, id: "house"), nil, "focustown-rn-godot"),
            (chat("Android 2.2.24 release notes", .working, minutes: 2, id: "notes", provider: .codex), nil, "focustown-rn-godot"),
            (chat("Godot shader warm-up", .working, minutes: 9, id: "shader", machine: "Studio", provider: .codex), nil, "focustown-rn-godot"),
            (chat("Twitter link setup", .idle, unread: true, minutes: 50, id: "tw"), "The [redesign session](#local_4f35f387-59 opened PR #1412, tests pass.", "focustown-rn-godot"),
            (chat("Study with friends layout", .idle, unread: true, minutes: 110, id: "study", provider: .codex), "::inbox-item{title=\"Layout pass is ready\" summary=\"Two columns on iPad\"}", "focustown-rn-godot"),
            (chat("Morning report automation", .idle, minutes: 60 * 26, id: "pin2", provider: .codex), nil, "burro"),
        ]
        let earlier = ["Menu bar fish count", "Refund macro wording", "Season pass copy review", "Crash on room transition",
                       "Push notification opt-in", "Leaderboard reset job", "Avatar shop pricing", "Weekly metrics digest",
                       "Localisation: Japanese pass", "Store screenshots for 2.2", "Remove legacy auth flow", "Burro notch spacing",
                       "Onboarding copy tweaks", "Godot export presets", "Analytics event audit", "Sentry release health"]
        for (index, title) in earlier.enumerated() {
            let remote = index % 4 == 1
            list.append((chat(title, .inactive, minutes: Double(20 + index * 95), id: "e\(index)", machine: remote ? "Studio" : nil,
                              provider: index % 3 == 2 ? .codex : .claude),
                         "Done.", remote ? "support-console" : (index % 3 == 0 ? "burro" : "focustown-rn-godot")))
        }
        return list
    }

    private func list(selected: String, showAll: Bool = false) -> some View {
        let byID = Dictionary(uniqueKeysWithValues: chats.map { ($0.0.id, $0) })
        let sections = ChatListSection.sections(chats.map(\.0), pinned: { $0.hasPrefix("pin") })
        return VStack(alignment: .leading, spacing: 8) {
            FilterHost().padding(.horizontal, 10).padding(.top, 12)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(sections, id: \.kind) { section in
                    if let title = section.title {
                        ChatsSectionHeader(title: title, count: section.sessions.count, color: ChatsModel.color(section.kind), emphasised: section.kind == .needsYou)
                    }
                    let shown = section.kind == .earlier
                        ? ChatListEarlier.shown(total: section.sessions.count, filtering: false, expanded: showAll, selectedIndex: nil)
                        : section.sessions.count
                    ForEach(section.sessions.prefix(shown)) { session in
                        let entry = byID[session.id]!
                        let row = ChatListRow.make(session, in: section.kind, pinned: session.id.hasPrefix("pin"), folder: entry.2,
                                                   preview: ChatListPresentation.preview(entry.1), now: self.now, calendar: .current)
                        ChatListRowView(row: row, selected: session.id == selected) {}
                    }
                    if shown < section.sessions.count { ChatsShowAllRow(total: section.sessions.count) {} }
                }
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 0)
        }
        .frame(width: ChatsModel.listWidth)
    }

    private struct FilterHost: View {
        @State private var query = ""
        @FocusState private var focused: Bool
        var body: some View { ChatsFilterField(query: $query, focused: $focused) }
    }

    private struct ComposerHost: View {
        var plan: ComposerPlan
        var handoffAction: ComposerPlan.Action? = nil
        var text: String
        var attachments: [String] = []
        var checking = false
        @State private var value = ""
        @FocusState private var focused: Bool
        var body: some View {
            ChatComposerBox(plan: plan, handoffAction: handoffAction,
                            text: Binding(get: { value.isEmpty ? text : value }, set: { value = $0 }), focused: $focused,
                            placeholder: plan.canSend ? "Reply to Claude…" : "Queue a message for when Claude is done…",
                            sending: false, attachments: attachments, agent: "Claude", machine: nil, checking: checking) {
                if plan.attachments && plan.canType { ComposerAttachLabel() }
                if plan.showPickers {
                    ComposerOptionLabel(symbol: ReplyAccess.ask.symbol, title: "Ask me")
                    ComposerOptionLabel(symbol: nil, title: "Opus 5.5")
                    ComposerOptionLabel(symbol: nil, title: "High effort")
                }
            }
            .frame(maxWidth: ChatColumn.width).frame(maxWidth: .infinity)
            .padding(.horizontal, ChatColumn.inset).padding(.top, 8).padding(.bottom, 16)
        }
    }

    private var transcript: ChatTranscript {
        let start = ago(18)
        func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }
        let messages: [ChatMessage] = [
            ChatMessage(id: 0, kind: .user, text: "The app hangs for 3 to 5 seconds when it comes back from the background on iOS 26. Find out why and fix it. Sentry has a cluster under \"App hanging\".", at: at(0)),
            ChatMessage(id: 1, kind: .tool, text: "xcodebuild -scheme FocusTown build", tool: "Bash", output: "BUILD SUCCEEDED", at: at(1), note: "Build the app"),
            ChatMessage(id: 2, kind: .tool, text: "rg resume Sources", tool: "Grep", output: "12 matches", at: at(2)),
            ChatMessage(id: 3, kind: .tool, text: "sentry-cli issues list", tool: "Bash", output: "14 events", at: at(3), note: "List the Sentry issues"),
            ChatMessage(id: 4, kind: .assistant, text: "Found it. On resume, `GodotBridge.resume()` waits on the main thread for the render server to rebuild every room texture before the first frame. The 14 Sentry events all show the same stack.\n\nI moved the texture rebuild off the main thread and show the last frame until it finishes. Changes are in 4 files.", at: at(9)),
            ChatMessage(id: 5, kind: .user, text: "Good. Run the Swift tests, then wipe the simulator and check a cold resume.", at: at(14)),
            ChatMessage(id: 6, kind: .tool, text: "swift test", tool: "Bash", at: at(16.8), note: "Run the Swift tests"),
        ]
        return ChatTranscript(messages: messages, title: "iOS hang on resume", folder: "/Users/me/Dev/focustown-wt/ios-resume-hang",
                              contextTokens: 124_000, contextWindow: 200_000)
    }

    private var waitingTranscript: ChatTranscript {
        var value = transcript
        value.messages.removeLast()
        value.messages.append(ChatMessage(id: 6, kind: .tool, text: "swift test", tool: "Bash", output: "Executed 340 tests, with 0 failures", at: ago(3), note: "Run the Swift tests"))
        value.messages.append(ChatMessage(id: 7, kind: .assistant, text: "All 340 tests pass. I want to wipe the simulator next to check a cold resume.", at: ago(2)))
        return value
    }

    /// A Codex reply with an inbox item, a narrow table, a wide one that scrolls, and markup to hide.
    private var markdownTranscript: ChatTranscript {
        let reply = """
        The floor was the cost. I measured each room with the floor on and off:

        | | Draw calls | Frame (ms) |
        |---|--:|--:|
        | Floor on | 412 | 14.8 |
        | Floor off | 160 | 9.1 |
        | **Saved** | 252 | 5.7 |

        ::inbox-item{title="Morning Report runs locally" summary="Keep the Mac awake and the desktop app running at 8 a.m."}
        ::created-thread{threadId="019a2c4e-thread"}

        Per room, after batching the floor tiles into one mesh:
        | Room | Before | After | Change | Tiles | Textures | Notes |
        |:--|--:|--:|:-:|--:|--:|:--|
        | Café | 96 | 38 | −60% | 1,204 | 18 | Tiles merged into one mesh; the counter keeps its own material |
        | Library | 88 | 41 | −53% | 980 | 22 | Shelves still draw per book; worth instancing next |
        | Park | 140 | 52 | −63% | 2,310 | 31 | `GrassMultiMesh` \\| shadows off on low end |
        | Rooftop | 88 | 29 | −67% | 640 | 12 |

        ::code-comment{title="Batch the shelves too" body="Each book is a draw call." file="/Users/me/Dev/focustown/rooms/library.gd" start=88 end=96 priority=2}
        Want me to instance the library shelves as well?
        """
        let messages: [ChatMessage] = [
            ChatMessage(id: 0, kind: .user, text: "Why is the café room dropping frames on the iPhone 13? Measure the draw calls with and without the floor.", at: ago(12)),
            ChatMessage(id: 1, kind: .tool, text: "godot --headless --profile rooms", tool: "Bash", output: "4 rooms profiled", at: ago(10), note: "Profile the rooms"),
            ChatMessage(id: 2, kind: .assistant, text: reply, at: ago(4)),
        ]
        return ChatTranscript(messages: messages, title: "Café room frame drops", folder: "/Users/me/Dev/focustown")
    }

    private func markdownPage() -> some View {
        HStack(spacing: 0) {
            list(selected: "notes")
            Rectangle().fill(AppAppearance.separator).frame(width: 1)
            VStack(spacing: 0) {
                ChatHeaderBar(title: "Café room frame drops", status: .readyToRead, agent: "Codex · gpt-5.5 · High effort",
                              place: "This Mac · focustown", turnStart: nil, stop: nil, showsInspector: false, toggleInspector: {}) {
                    EmptyView()
                } menu: { EmptyView() }
                Rectangle().fill(AppAppearance.separator).frame(height: 1)
                ChatTranscriptView(transcript: markdownTranscript, provider: .codex, working: false, trailing: nil)
                    .frame(maxHeight: .infinity)
                ComposerHost(plan: ComposerPlan(), text: "", checking: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var inspector: ChatInspectorValues {
        ChatInspectorValues(
            folder: .init(name: "ios-resume-hang", path: NSHomeDirectory() + "/Dev/focustown-wt/ios-resume-hang", branch: "fix/ios-resume-hang",
                          pending: "4 uncommitted · 2 unpushed", worktree: true, primary: false),
            changes: .files(ChatChangeList(files: ChatChanges.parseNumstat("48\t21\tGodotBridge.swift\n62\t0\tRenderServerQueue.swift\n9\t4\tSceneDelegate.swift\n37\t0\tTests/ResumeTimingTests.swift\n"))),
            contextTokens: 124_000, contextWindow: 200_000, cost: 3.84, costKnown: true, started: ago(18))
    }

    private enum Mode { case working, waiting, elsewhere }

    private func page(_ mode: Mode, inspector shows: Bool = true) -> some View {
        let waiting = mode == .waiting
        var plan = ComposerPlan()
        switch mode {
        case .waiting:
            plan = ComposerPlan(reason: "Claude is waiting for you in this chat (a question or an approval). Attach to it to answer.",
                                action: .attachInTerminal(handle: "a1b2c3"))
        case .elsewhere:
            plan = ComposerPlan(reason: ChatReply.runsElsewhere, action: .openInProvider)
            plan.stop = .elsewhere
        case .working:
            plan.canType = true; plan.canQueue = true; plan.stop = .claudeBackground(handle: "a1b2c3"); plan.attachments = true
        }
        let card = ChatHandoff.card(plan: plan, hasURL: true)
        let shown = waiting ? waitingTranscript : transcript
        let session = chat("iOS hang on resume", waiting ? .waiting : .working, minutes: waiting ? 2 : 0, id: "hang")
        return HStack(spacing: 0) {
            list(selected: waiting ? "ask1" : "hang")
            Rectangle().fill(AppAppearance.separator).frame(width: 1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ChatHeaderBar(title: "iOS hang on resume", status: waiting ? .needsYou : .working, agent: "Claude · Opus 5.5 · High effort",
                                  place: "This Mac · focustown", turnStart: ChatTurnClock.start(shown.messages, working: !waiting),
                                  stop: plan.stop, showsInspector: shows, toggleInspector: {}) {
                        EmptyView()
                    } menu: {
                        Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium)).foregroundStyle(AppAppearance.secondary).frame(width: 28, height: 28)
                    }
                    Rectangle().fill(AppAppearance.separator).frame(height: 1)
                    ChatTranscriptView(transcript: shown, provider: .claude, working: !waiting,
                                       trailing: waiting ? AnyView(ChatHandoffCard(card: card, since: ago(2), agent: "Claude", machine: nil) { _ in }) : nil)
                        .environment(\.chatWaiting, waiting)
                        .frame(maxHeight: .infinity)
                    if mode == .working {
                        ChatDraftLineContent(text: "When the tests pass, open a draft PR against staging and link the Sentry issue.", use: {}, discard: {})
                    }
                    ComposerHost(plan: plan, handoffAction: waiting ? card.action : nil,
                                 text: mode == .working ? "Also add a breadcrumb before the rebuild so we can see it in Sentry next time." : "",
                                 attachments: mode == .working ? ["/tmp/sentry-hang-stack.png"] : [])
                }
                if shows { ChatInspectorPanel(values: inspector, now: now) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.chatWaiting, waiting)
            .id(session.id)
        }
    }

    func testRenderChatsSnapshots() throws {
        guard ProcessInfo.processInfo.environment["BURRO_CHATS_SNAPSHOTS"] == "1" else { throw XCTSkip("set BURRO_CHATS_SNAPSHOTS=1") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = ProcessInfo.processInfo.environment["BURRO_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("dist/screenshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [true, false] {
            let suffix = dark ? "dark" : "light"
            try render(page(.working), size: CGSize(width: 1440, height: 900), dark: dark, to: out.appendingPathComponent("chats-working-\(suffix).png"))
            try render(page(.waiting), size: CGSize(width: 1440, height: 900), dark: dark, to: out.appendingPathComponent("chats-waiting-\(suffix).png"))
            try render(page(.elsewhere), size: CGSize(width: 1440, height: 900), dark: dark, to: out.appendingPathComponent("chats-elsewhere-\(suffix).png"))
            try render(list(selected: "hang"), size: CGSize(width: ChatsModel.listWidth, height: 1380), dark: dark, to: out.appendingPathComponent("chats-list-\(suffix).png"))
            try render(markdownPage(), size: CGSize(width: 1200, height: 900), dark: dark, to: out.appendingPathComponent("chats-markdown-\(suffix).png"))
        }
        // The window's minimum width (ContentView: 1000 pt, the whole width; there is no sidebar).
        try render(page(.working, inspector: false), size: CGSize(width: 1000, height: 760), dark: true, to: out.appendingPathComponent("chats-narrow-dark.png"))
        // At the window's minimum width the per-room table is wider than the conversation: it scrolls.
        try render(markdownPage(), size: CGSize(width: 1000, height: 900), dark: true, to: out.appendingPathComponent("chats-markdown-narrow-dark.png"))
    }

    private func render<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(AppAppearance.background))
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame.size = size
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
