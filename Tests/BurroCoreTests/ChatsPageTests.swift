// The Chats page's decisions: list sections (pinned group, statuses, every chat once), the rows
// built from them (state from the section, place, previews only where they matter, how much of
// Earlier shows), row times (honest for working Claude chats), token counts in any language,
// the header's turn clock, the waiting chat's hand-off card, the per-file change list parsed from
// `git diff --numstat` (and read from a real temporary repository), and "cost so far" from a
// transcript's token counts, read incrementally. Nothing here touches a real chat or repository.
import XCTest
@testable import BurroCore

final class ChatsPageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var utc: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!; return calendar }

    private func session(_ name: String, _ state: AgentState, unread: Bool = false, updated: TimeInterval = 0, stale: Bool = false) -> AgentSession {
        var value = AgentSession(id: name, provider: .claude, title: name, cwd: "/tmp", state: state, updatedAt: now.addingTimeInterval(updated), evidence: "fixture")
        value.hasUnreadResult = unread
        if stale { value.remote = RemoteOrigin(hostID: UUID(), hostName: "Mini", sampledAt: now, stale: true) }
        return value
    }

    // MARK: Sections

    func testSectionsKeepEveryChatOnceWithPinnedIdleChatsOnTop() {
        let chats = [session("ask", .waiting), session("run", .working), session("cron", .scheduled), session("done", .idle, unread: true),
                     session("old", .idle, updated: -900), session("new", .idle, updated: -60), session("pin", .idle, updated: -5000),
                     session("pinnedAsk", .waiting), session("staleAsk", .waiting, stale: true)]
        let pins: Set<String> = ["pin", "pinnedAsk"]
        let sections = ChatListSection.sections(chats, pinned: { pins.contains($0) })
        XCTAssertEqual(sections.map(\.kind), [.pinned, .needsYou, .working, .readyToRead, .earlier])
        XCTAssertEqual(sections.map { $0.sessions.map(\.id) },
                       [["pin"], ["ask", "pinnedAsk"], ["run", "cron"], ["done"], ["staleAsk", "new", "old"]])
        XCTAssertNil(sections[0].title, "The pinned group has no header")
        XCTAssertEqual(sections.compactMap(\.title), ["Needs you", "Working", "Ready to read", "Earlier"])
        XCTAssertEqual(Set(sections.flatMap { $0.sessions.map(\.id) }).count, chats.count)
        XCTAssertTrue(ChatListSection.sections([], pinned: { _ in true }).isEmpty)
    }

    func testStatusOfAChat() {
        XCTAssertEqual(ChatPageStatus.of(session("a", .waiting)), .needsYou)
        XCTAssertEqual(ChatPageStatus.of(session("a", .waiting, stale: true)), .idle, "A stale remote chat isn't asking now")
        XCTAssertEqual(ChatPageStatus.of(session("a", .scheduled)), .working)
        XCTAssertEqual(ChatPageStatus.of(session("a", .inactive, unread: true)), .readyToRead)
        XCTAssertEqual(ChatPageStatus.of(session("a", .idle)).title, "Idle")
    }

    // MARK: Times

    func testRowTimes() {
        let noon = utc.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12, minute: 0))!   // a Monday
        func label(_ seconds: TimeInterval) -> String { ChatRowTime.label(noon.addingTimeInterval(-seconds), now: noon, calendar: utc) }
        XCTAssertEqual(label(20), "now")
        XCTAssertEqual(label(-30), "now", "A clock slightly ahead still reads now")
        XCTAssertEqual(label(4 * 60 + 10), "4 min")
        XCTAssertEqual(label(2 * 3600 + 43 * 60), "09:17")
        XCTAssertEqual(label(14 * 3600), "Yesterday")
        XCTAssertEqual(label(3 * 86400), "Fri")
        XCTAssertEqual(label(9 * 86400), "7 Nov")
    }

    func testWorkingClaudeRowsSayHowLongTheyHaveWorked() {
        let noon = utc.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12, minute: 0))!
        func meta(_ status: ChatPageStatus, _ seconds: TimeInterval, codex: Bool = false) -> String {
            ChatRowTime.meta(status: status, updatedAt: noon.addingTimeInterval(-seconds), followsOutput: codex, now: noon, calendar: utc)
        }
        XCTAssertEqual(meta(.working, 20), "just started")
        XCTAssertEqual(meta(.working, 36 * 60), "for 36 min")
        XCTAssertEqual(meta(.working, 2 * 3600 + 51 * 60), "since 09:09", "Claude's time is when it started working, not its latest output")
        XCTAssertEqual(meta(.working, 26 * 3600), "since Yesterday")
        XCTAssertEqual(meta(.working, 2 * 3600 + 51 * 60, codex: true), "09:09", "Codex's time follows its log")
        XCTAssertEqual(meta(.working, 4 * 60, codex: true), "4 min")
        XCTAssertEqual(meta(.idle, 2 * 3600 + 51 * 60), "09:09")
        XCTAssertEqual(meta(.needsYou, 4 * 60), "4 min")
        XCTAssertEqual(meta(.readyToRead, 20), "now")
    }

    func testRowsTakeTheirStateFromTheirSection() {
        let noon = utc.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12, minute: 0))!
        var remote = AgentSession(id: "remote:x:claude:1", provider: .claude, title: "Shader warm-up", cwd: "/w/focustown", state: .working,
                                  updatedAt: noon.addingTimeInterval(-9 * 60), evidence: "fixture")
        remote.remote = RemoteOrigin(hostID: UUID(), hostName: "Studio", sampledAt: noon, stale: false)
        let row = ChatListRow.make(remote, in: .working, pinned: false, folder: "focustown", preview: "Editing two files", now: noon, calendar: utc)
        XCTAssertEqual(row.status, .working)
        XCTAssertEqual(row.meta, "Studio · focustown · for 9 min")
        XCTAssertNil(row.preview, "Working rows never show a preview")
        XCTAssertTrue(row.isActive)

        let earlier = ChatListRow.make(remote, in: .earlier, pinned: true, folder: "focustown", preview: "Done", now: noon, calendar: utc)
        XCTAssertEqual(earlier.status, .idle, "The section decides, so a row can't say Working under Earlier")
        XCTAssertEqual(earlier.meta, "Studio · focustown · 9 min")
        XCTAssertNil(earlier.preview)
        XCTAssertFalse(earlier.isActive)
        XCTAssertTrue(earlier.pinned)

        let local = session("ask", .waiting, updated: -4 * 60)
        let ask = ChatListRow.make(local, in: .needsYou, pinned: false, folder: "focustown-rn-godot", preview: "Merge #412 now?", now: now, calendar: utc)
        XCTAssertEqual(ask.meta, "focustown-rn-godot · 4 min", "This Mac shows just the folder")
        XCTAssertEqual(ask.preview, "Merge #412 now?")
        XCTAssertEqual(ChatListRow.make(local, in: .readyToRead, pinned: false, folder: "f", preview: "Done", now: now, calendar: utc).preview, "Done")
        XCTAssertEqual(ChatListRow.place(machine: nil, folder: ""), "This Mac")
        XCTAssertEqual(ChatListRow.place(machine: "Studio", folder: ""), "Studio")
        XCTAssertEqual(ChatListRow.status(of: .pinned), .idle)
    }

    func testEarlierShowsTheMostRecentUntilAskedForAll() {
        XCTAssertEqual(ChatListEarlier.shown(total: 50, filtering: false, expanded: false, selectedIndex: nil), 12)
        XCTAssertEqual(ChatListEarlier.shown(total: 50, filtering: false, expanded: false, selectedIndex: 11), 12)
        XCTAssertEqual(ChatListEarlier.shown(total: 50, filtering: false, expanded: false, selectedIndex: 12), 50, "The open chat is never hidden")
        XCTAssertEqual(ChatListEarlier.shown(total: 50, filtering: true, expanded: false, selectedIndex: nil), 50)
        XCTAssertEqual(ChatListEarlier.shown(total: 50, filtering: false, expanded: true, selectedIndex: nil), 50)
        XCTAssertEqual(ChatListEarlier.shown(total: 15, filtering: false, expanded: false, selectedIndex: nil), 15, "Not worth hiding three")
        XCTAssertEqual(ChatListEarlier.shown(total: 16, filtering: false, expanded: false, selectedIndex: nil), 12)
        XCTAssertEqual(ChatListEarlier.shown(total: 0, filtering: false, expanded: false, selectedIndex: nil), 0)
    }

    func testTokenCountsReadTheSameInEveryLanguage() {
        XCTAssertEqual(TokenCount.compact(0), "0")
        XCTAssertEqual(TokenCount.compact(950), "950")
        XCTAssertEqual(TokenCount.compact(999.6), "1K")
        XCTAssertEqual(TokenCount.compact(1000), "1K")
        XCTAssertEqual(TokenCount.compact(12_500), "12.5K")
        XCTAssertEqual(TokenCount.compact(124_000), "124K")
        XCTAssertEqual(TokenCount.compact(500_400), "500K")
        XCTAssertEqual(TokenCount.compact(999_700), "1M")
        XCTAssertEqual(TokenCount.compact(1_234_000), "1.2M")
        XCTAssertEqual(TokenCount.compact(200_000_000), "200M")
        XCTAssertEqual(TokenCount.compact(-5), "0")
    }

    func testTurnClock() {
        let messages = [ChatMessage(id: 0, kind: .user, text: "go", at: now), ChatMessage(id: 1, kind: .assistant, text: "ok", at: now.addingTimeInterval(5)),
                        ChatMessage(id: 2, kind: .user, text: "more", at: now.addingTimeInterval(60)), ChatMessage(id: 3, kind: .tool, text: "ls")]
        XCTAssertEqual(ChatTurnClock.start(messages, working: true), now.addingTimeInterval(60))
        XCTAssertNil(ChatTurnClock.start(messages, working: false))
        XCTAssertNil(ChatTurnClock.start([ChatMessage(id: 0, kind: .assistant, text: "hi", at: now)], working: true))
        XCTAssertEqual(ChatTurnClock.label(40), "turn 40 s")
        XCTAssertEqual(ChatTurnClock.label(18 * 60 + 59), "turn 18 min")
        XCTAssertEqual(ChatTurnClock.label(3600 + 5 * 60), "turn 1 h 05 min")
        XCTAssertEqual(ChatTurnClock.label(-3), "turn 0 s")
        XCTAssertEqual(ChatTurnClock.short(4 * 60), "4 min")
    }

    // MARK: Hand-off

    func testHandOffNamesTheOnePlaceThatCanAnswer() {
        var attach = ComposerPlan(reason: "waiting", action: .attachInTerminal(handle: "abc123"))
        attach.canType = false
        XCTAssertEqual(ChatHandoff.card(plan: attach, hasURL: true).action, .attachInTerminal(handle: "abc123"))
        let queue = ComposerPlan(reason: "busy", action: .queue)
        XCTAssertEqual(ChatHandoff.card(plan: queue, hasURL: true).action, .openInProvider, "Queueing doesn't answer an approval")
        XCTAssertNil(ChatHandoff.card(plan: queue, hasURL: false).action)
        var reply = ComposerPlan(); reply.canSend = true
        let card = ChatHandoff.card(plan: reply, hasURL: true)
        XCTAssertEqual(card.title, "Waiting for you")
        XCTAssertTrue(card.detail.contains("answer below"))
        XCTAssertTrue(ChatHandoff.card(plan: attach, hasURL: false).detail.contains("can't answer approvals"))
    }

    // MARK: Changes

    func testNumstatParsing() {
        let text = "48\t21\tSources/GodotBridge.swift\n62\t0\tSources/RenderServerQueue.swift\n-\t-\tAssets/logo.png\n"
            + "3\t1\tSources/{Old => New}/Scene.swift\n2\t2\told.txt => docs/new.txt\n1\t0\t\"with space.txt\"\nnot a line\nx\t1\tbad\n"
        let files = ChatChanges.parseNumstat(text)
        XCTAssertEqual(files.map(\.path), ["Sources/GodotBridge.swift", "Sources/RenderServerQueue.swift", "Sources/New/Scene.swift", "docs/new.txt",
                                           "with space.txt", "Assets/logo.png"])
        XCTAssertEqual(files.first?.name, "GodotBridge.swift")
        XCTAssertNil(files.last?.added, "Binary files have no line counts")
        let list = ChatChangeList(files: files)
        XCTAssertEqual(list.added, 48 + 62 + 3 + 2 + 1)
        XCTAssertEqual(list.removed, 21 + 1 + 2)
        XCTAssertEqual(ChatChanges.destination("a/{b => }/c.txt"), "a/c.txt")
        XCTAssertTrue(ChatChanges.parseNumstat("").isEmpty)
    }

    func testChangesReadFromARepositoryAgainstItsBase() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-changes-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let git = CommandRunner()
        func run(_ args: [String]) { XCTAssertTrue(git.git(folder.path, args).succeeded, args.joined(separator: " ")) }
        run(["init", "-q", "-b", "main"])
        run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "base"])
        run(["checkout", "-q", "-b", "feature"])
        try "one\ntwo\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        run(["add", "a.txt"])
        run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "a"])
        try "one\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let list = try XCTUnwrap(ChatChanges.read(path: folder.path, base: "main"))
        XCTAssertEqual(list.files, [ChatFileChange(path: "a.txt", added: 1, removed: 0)], "Committed and uncommitted, against the merge base")
        XCTAssertNil(ChatChanges.read(path: FileManager.default.temporaryDirectory.appendingPathComponent("burro-none-\(UUID().uuidString)").path, base: nil))
    }

    // MARK: Cost

    private func claudeLine(_ id: String, model: String = "claude-opus-5-5", input: Int, output: Int, cached: Int = 0) -> String {
        #"{"type":"assistant","requestId":"r-\#(id)","timestamp":"2026-11-16T10:00:00.000Z","message":{"id":"m-\#(id)","model":"\#(model)","stop_reason":"end_turn","content":[{"type":"text","text":"secret words"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cached),"cache_creation_input_tokens":0}}}"#
    }

    func testCostTallyPricesClaudeUsageOnceAndRefusesUnknownModels() throws {
        var tally = ChatCostTally(provider: .claude)
        XCTAssertNil(tally.dollars, "Nothing to price")
        tally.consume(Data((claudeLine("1", input: 1_000_000, output: 0) + "\n" + #"{"type":"user","message":{"content":"hi"}}"# + "\n").utf8))
        XCTAssertEqual(try XCTUnwrap(tally.dollars), 4, accuracy: 0.0001)
        // The same message streamed again with a bigger count replaces, never adds.
        tally.consume(Data((claudeLine("1", input: 1_000_000, output: 100_000) + "\n").utf8))
        XCTAssertEqual(try XCTUnwrap(tally.dollars), 4 + 2, accuracy: 0.0001)
        tally.consume(Data((claudeLine("2", model: "claude-unknown-9", input: 10, output: 10) + "\n").utf8))
        XCTAssertNil(tally.dollars, "A model without a price can't be summed honestly")
        XCTAssertEqual(ChatCost.label(3.8412), "$3.84")
        XCTAssertEqual(ChatCost.label(0.001), "<$0.01")
        XCTAssertEqual(ChatCost.label(nil), "—")
    }

    func testCostReaderReadsOnlyWhatWasAppendedAndFindsTheFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("burro-cost-\(UUID().uuidString)").resolvingSymlinksInPath()
        let id = "11111111-2222-4333-8444-555555555555"
        let folder = root.appendingPathComponent("projects/-Users-me-dev")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = folder.appendingPathComponent("\(id).jsonl")
        try Data((claudeLine("1", input: 1_000_000, output: 0) + "\n" + #"{"type":"assistant","partial"#).utf8).write(to: file)
        XCTAssertEqual(ChatCost.transcript(provider: .claude, id: id, root: root, startedAt: nil)?.resolvingSymlinksInPath().path, file.resolvingSymlinksInPath().path)
        XCTAssertNil(ChatCost.transcript(provider: .claude, id: "not-a-uuid", root: root, startedAt: nil))
        let reader = ChatCost.Reader()
        XCTAssertEqual(try XCTUnwrap(reader.dollars(provider: .claude, id: id, root: root, startedAt: nil)), 4, accuracy: 0.0001)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        // Finish the half-written line as garbage, then a new priced line.
        try handle.write(contentsOf: Data((":1}\n" + claudeLine("2", input: 0, output: 1_000_000) + "\n").utf8))
        try handle.close()
        XCTAssertEqual(try XCTUnwrap(reader.dollars(file: file, provider: .claude)), 4 + 20, accuracy: 0.0001)

        // Codex: found in the day folder of its start.
        let codexRoot = root.appendingPathComponent("codex")
        let day = codexRoot.appendingPathComponent("sessions/2026/11/16")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let rollout = day.appendingPathComponent("rollout-2026-11-16T10-00-00-\(id).jsonl")
        try Data().write(to: rollout)
        let start = utc.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 10))!
        XCTAssertEqual(ChatCost.transcript(provider: .codex, id: id, root: codexRoot, startedAt: start, calendar: utc)?.resolvingSymlinksInPath().path, rollout.resolvingSymlinksInPath().path)
        XCTAssertNil(ChatCost.transcript(provider: .codex, id: id, root: codexRoot, startedAt: nil, calendar: utc))
    }
}
