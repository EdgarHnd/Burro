// Check where the two halves of the Orchestrator meet and its new surfaces: triage's runs in the
// shared runs log, `chat_digest` carrying the Brief's triage result, `overview` not repeating the
// Brief, honest stuck detection (each provider's best signal, a long quiet step, other machines),
// drafts shown once per chat (menu bar, Chats, Brief), "Use" filling the composer, the banner text
// with triage's headline, and `start_chat` on another machine. Nothing here runs Claude, starts or
// messages a chat, or opens SSH; files go in temporary folders.
import XCTest
@testable import BurroCore

final class OrchestratorSeamTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let chat = "claude:11111111-2222-4333-8444-555555555555"

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("burro-seams-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func session(_ id: String? = nil, state: AgentState = .waiting, updatedAt: Date? = nil, remote: RemoteOrigin? = nil) -> AgentSession {
        AgentSession(id: id ?? chat, provider: .claude, title: "Fix login", cwd: "/Dev/app", state: state, updatedAt: updatedAt ?? t0,
                     evidence: "fixture", remote: remote)
    }
    private func tools(chats: [AgentSession], hosts: [RemoteHost] = [], machines: [OrchestratorState.Machine] = [], in base: URL) throws -> OrchestratorTools {
        let state = OrchestratorState(generatedAt: t0, mainProject: nil, machines: machines, projects: [], chats: chats, worktrees: [],
                                      todos: [], hosts: hosts, profiles: [:])
        let url = base.appendingPathComponent("state.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(state).write(to: url)
        var tools = OrchestratorTools(stateURL: url)
        tools.now = { self.t0.addingTimeInterval(300) }
        return tools
    }
    private func triaged(_ base: URL, chatUpdatedAt: Date, proposal: String? = nil) throws {
        try BriefStore(url: base.appendingPathComponent("brief.json")).update(now: t0) { file in
            let result = TriageResult(chatID: chat, kind: .decision, headline: "Asks whether to merge #412", question: "Merge now?",
                                      options: ["Merge", "Wait"], confidence: 0.9)
            _ = BriefReducer.apply(result, title: "Fix login", machine: "This Mac", sourceHash: "h", chatUpdatedAt: chatUpdatedAt, to: &file, now: t0)
            if let proposal { BriefReducer.attach(proposal: proposal, to: file.items[0].id, in: &file) }
        }
    }

    // MARK: Runs log

    func testTriageRunUsageComesFromTheSameResultParserAsAsks() {
        let output = """
        {"type":"system","subtype":"init"}
        {"type":"result","is_error":false,"result":"{}","total_cost_usd":0.004,"duration_ms":900,"usage":{"input_tokens":100,"cache_creation_input_tokens":50,"output_tokens":7,"cache_read_input_tokens":20}}
        """
        let run = OrchestratorRun.from(output: output, at: t0, trigger: "triage", model: "haiku")
        XCTAssertEqual(run, OrchestratorRun(at: t0, trigger: "triage", model: "haiku", durationMs: 900, inputTokens: 150, outputTokens: 7,
                                            cacheReadTokens: 20, costUSD: 0.004))
        XCTAssertNil(OrchestratorRun.from(output: "not json\n{\"type\":\"assistant\"}", at: t0, trigger: "triage", model: "haiku"))
    }

    // MARK: Tools

    func testChatDigestCarriesTheTriageResultAndItsDraft() throws {
        let base = try folder()
        var tools = try tools(chats: [session(updatedAt: t0)], in: base)
        var reads = 0
        tools.readChat = { _, _, _, _ in
            reads += 1
            return ChatTranscript(messages: [ChatMessage(id: 0, kind: .user, text: "Fix the login bug"),
                                             ChatMessage(id: 1, kind: .assistant, text: String(repeating: "Done. ", count: 200) + "Should I merge #412?")])
        }
        let saved = try tools.actions.propose(OrchestratorAction(kind: .reply, createdAt: t0, text: "Yes, merge it.", chatID: chat, chatTitle: "Fix login",
                                                                 conversation: BriefDrafts.triageConversation), now: t0)
        try triaged(base, chatUpdatedAt: t0, proposal: saved.action.id)
        let (text, isError) = tools.call("chat_digest", ["id": chat])
        XCTAssertFalse(isError)
        XCTAssertTrue(text.contains("[decision] Asks whether to merge #412"), text)
        XCTAssertTrue(text.contains("Question: Merge now?"))
        XCTAssertTrue(text.contains("Options: Merge | Wait"))
        XCTAssertTrue(text.contains("by triage): waiting for the user's Send: \"Yes, merge it.\""))
        XCTAssertTrue(text.contains("The brief is current"))
        XCTAssertFalse(text.contains("Ends on:"), "the question is already given")
        XCTAssertEqual(reads, 1)

        // The chat moved on after triage read it: say so, and show the question it ends on now.
        var later = try self.tools(chats: [session(updatedAt: t0.addingTimeInterval(600))], in: base)
        later.readChat = tools.readChat
        let moved = later.call("chat_digest", ["id": chat]).0
        XCTAssertTrue(moved.contains("changed after triage read it"))
        XCTAssertTrue(moved.contains("Ends on:"))
    }

    func testChatDigestWithoutABriefEntryIsUnchanged() throws {
        var tools = try tools(chats: [session()], in: try folder())
        tools.readChat = { _, _, _, _ in ChatTranscript(messages: [ChatMessage(id: 0, kind: .assistant, text: "Merge?")]) }
        let text = tools.call("chat_digest", ["id": chat]).0
        XCTAssertFalse(text.contains("Brief ("))
        XCTAssertTrue(text.contains("Ends on: Merge?"))
    }

    func testOverviewOnlyCountsChatsTheBriefAlreadyCovers() throws {
        let base = try folder()
        let other = "claude:99999999-2222-4333-8444-555555555555"
        let tools = try tools(chats: [session(), session(other)], in: base)
        try triaged(base, chatUpdatedAt: t0)
        let text = tools.call("overview", [:]).0
        XCTAssertTrue(text.contains("## Needs you (2)"))
        XCTAssertTrue(text.contains("id \(other)"))
        XCTAssertFalse(text.contains("id \(chat)"), "in the brief: counted, not repeated")
        XCTAssertTrue(text.contains("- 1 more in the brief"))
    }

    func testTheBriefToolShowsAReplyTheOrchestratorProposedForAnItemWithoutADraft() throws {
        let base = try folder()
        let tools = try tools(chats: [session()], in: base)
        try triaged(base, chatUpdatedAt: t0)
        XCTAssertTrue(tools.call("brief", [:]).0.contains("No draft: worth a look."))
        _ = try tools.actions.propose(OrchestratorAction(kind: .reply, createdAt: t0, text: "Wait for CI.", chatID: chat), now: t0)
        let text = tools.call("brief", [:]).0
        XCTAssertTrue(text.contains("waiting for the user's Send: \"Wait for CI.\""), text)
        XCTAssertFalse(text.contains("by triage"))
    }

    func testTheSystemPromptSendsTheModelToTheBriefFirst() {
        XCTAssertTrue(Orchestrator.brief.contains("Call `brief` first"))
        XCTAssertFalse(Orchestrator.brief.contains("if it isn't available"), "the tool exists now")
        XCTAssertTrue(Orchestrator.brief.contains("don't re-derive"))
        XCTAssertEqual(Orchestrator.briefURL.lastPathComponent, "brief.json")
        XCTAssertEqual(BriefStore.standard.url, Orchestrator.briefURL)
        XCTAssertEqual(TriageMemory.url, Orchestrator.memoryURL)
        XCTAssertEqual(OrchestratorRuns.standard.url, Orchestrator.runsURL)
    }

    // MARK: Stuck

    private func claude(local: Bool = true, updatedAt: Date? = nil) -> BriefChatState {
        BriefChatState(id: "c", working: true, updatedAt: updatedAt ?? t0, updatesWhileWorking: false, local: local)
    }

    func testAClaudeChatOnThisMacIsJudgedByItsTranscriptNotItsStatusTime() {
        var watch = StuckWatch()
        let chat = claude()
        XCTAssertTrue(watch.dueChecks([chat], now: t0.addingTimeInterval(44 * 60)).isEmpty, "not quiet long enough to look")
        XCTAssertTrue(watch.update([chat], now: t0.addingTimeInterval(50 * 60)).isEmpty, "never judged before its transcript is looked at")
        XCTAssertEqual(watch.dueChecks([chat], now: t0.addingTimeInterval(50 * 60)), ["c"])
        XCTAssertTrue(watch.dueChecks([chat], now: t0.addingTimeInterval(52 * 60)).isEmpty, "at most every five minutes")
        // The transcript grew two minutes ago: alive, though its status time is 50 minutes old.
        watch.record("c", glance: .init(modified: t0.addingTimeInterval(48 * 60), toolRunning: false, revision: 7), now: t0.addingTimeInterval(50 * 60))
        XCTAssertEqual(watch.lastSignal(chat), t0.addingTimeInterval(48 * 60))
        XCTAssertEqual(watch.revision("c"), 7)
        XCTAssertTrue(watch.update([chat], now: t0.addingTimeInterval(60 * 60)).isEmpty)
        XCTAssertTrue(watch.dueChecks([chat], now: t0.addingTimeInterval(60 * 60)).isEmpty, "quiet for 12 minutes only")
        // Unchanged since: 45 minutes after its last growth it is stuck.
        XCTAssertEqual(watch.dueChecks([chat], now: t0.addingTimeInterval(93 * 60)), ["c"])
        watch.record("c", glance: nil, now: t0.addingTimeInterval(93 * 60))
        let stuck = watch.update([chat], now: t0.addingTimeInterval(93 * 60))
        XCTAssertEqual(stuck.map(\.id), ["c"])
        XCTAssertEqual(stuck.first?.since, t0.addingTimeInterval(48 * 60))
    }

    func testALongQuietToolCallWaitsThreeHours() {
        var watch = StuckWatch()
        let chat = claude()
        _ = watch.dueChecks([chat], now: t0.addingTimeInterval(46 * 60))
        watch.record("c", glance: .init(modified: t0, toolRunning: true), now: t0.addingTimeInterval(46 * 60))
        XCTAssertTrue(watch.longStep("c"))
        XCTAssertTrue(watch.update([chat], now: t0.addingTimeInterval(2 * 3600)).isEmpty, "a build or sub-agent still running")
        XCTAssertEqual(watch.update([chat], now: t0.addingTimeInterval(3 * 3600)).map(\.id), ["c"])
        var file = BriefFile()
        BriefReducer.stuck(chatID: "c", title: "Big build", machine: nil, since: t0, chatUpdatedAt: t0, longStep: true, in: &file, now: t0.addingTimeInterval(3 * 3600))
        XCTAssertEqual(file.items.first?.headline, "One step running for 3 h with no output")
        // Codex too: a running tool raises its bar.
        var codex = StuckWatch()
        let state = BriefChatState(id: "x", working: true, updatedAt: t0, updatesWhileWorking: true, local: true)
        codex.record("x", glance: .init(modified: t0, toolRunning: true), now: t0)
        XCTAssertTrue(codex.update([state], now: t0.addingTimeInterval(50 * 60)).isEmpty)
    }

    func testAClaudeChatElsewhereOrUnreadableWaitsThreeHours() {
        var watch = StuckWatch()
        let remote = claude(local: false)
        XCTAssertTrue(watch.dueChecks([remote], now: t0.addingTimeInterval(4 * 3600)).isEmpty, "never over SSH for this")
        XCTAssertTrue(watch.update([remote], now: t0.addingTimeInterval(2 * 3600)).isEmpty)
        XCTAssertEqual(watch.update([remote], now: t0.addingTimeInterval(3 * 3600)).map(\.id), ["c"])
        var blind = StuckWatch()
        let local = claude()
        _ = blind.dueChecks([local], now: t0.addingTimeInterval(46 * 60))
        blind.record("c", glance: nil, unreadable: true, now: t0.addingTimeInterval(46 * 60))
        XCTAssertTrue(blind.update([local], now: t0.addingTimeInterval(2 * 3600)).isEmpty)
        XCTAssertEqual(blind.update([local], now: t0.addingTimeInterval(3 * 3600)).map(\.id), ["c"])
    }

    func testAGlanceReadsTheFileTimeAndARunningTool() {
        let running = ChatTranscript(messages: [ChatMessage(id: 0, kind: .assistant, text: "Building", at: t0),
                                                ChatMessage(id: 1, kind: .tool, text: "swift build", tool: "Bash", at: t0.addingTimeInterval(5))],
                                     modified: t0.addingTimeInterval(9))
        XCTAssertEqual(StuckWatch.Glance(running, revision: 3), .init(modified: t0.addingTimeInterval(9), toolRunning: true, revision: 3))
        let done = ChatTranscript(messages: [ChatMessage(id: 0, kind: .tool, text: "ls", tool: "Bash", output: "a", at: t0)])
        XCTAssertEqual(StuckWatch.Glance(done, revision: nil), .init(modified: t0, toolRunning: false))
    }

    func testAStuckItemResolvesWhenTheTranscriptMoves() {
        var file = BriefFile()
        BriefReducer.stuck(chatID: "c", title: "Task", machine: nil, since: t0, chatUpdatedAt: t0, in: &file, now: t0.addingTimeInterval(3600))
        _ = BriefReducer.reconcile(&file, chats: [BriefChatState(id: "c", working: true, updatedAt: t0, updatesWhileWorking: false)], now: t0.addingTimeInterval(3700))
        XCTAssertTrue(file.items[0].isOpen)
        _ = BriefReducer.reconcile(&file, chats: [BriefChatState(id: "c", working: true, updatedAt: t0, updatesWhileWorking: false,
                                                                 lastSignal: t0.addingTimeInterval(3650))], now: t0.addingTimeInterval(3700))
        XCTAssertFalse(file.items[0].isOpen, "new output in the transcript, status time unchanged")
    }

    func testSessionsMapToTheirSignal() {
        let local = BriefChatState(session(state: .working))
        XCTAssertFalse(local.updatesWhileWorking)
        XCTAssertTrue(local.local)
        var codex = session("codex:11111111-2222-4333-8444-555555555555", state: .working)
        codex.provider = .codex
        codex.remote = RemoteOrigin(hostID: UUID(), hostName: "devbox", sampledAt: t0, stale: false)
        let remote = BriefChatState(codex)
        XCTAssertTrue(remote.updatesWhileWorking)
        XCTAssertFalse(remote.local)
    }

    // MARK: Drafts

    func testOneDraftPerChatEverywhere() throws {
        let other = "codex:99999999-2222-4333-8444-555555555555"
        let triage = OrchestratorAction(id: "t", kind: .reply, createdAt: t0, text: "Merge it.\nThen tag.", chatID: chat, conversation: BriefDrafts.triageConversation)
        let asked = OrchestratorAction(id: "a", kind: .reply, createdAt: t0.addingTimeInterval(60), text: "Wait.", chatID: chat.uppercased())
        let second = OrchestratorAction(id: "b", kind: .reply, createdAt: t0, text: "Go on.", chatID: other)
        var sent = OrchestratorAction(id: "s", kind: .reply, createdAt: t0, text: "Old", chatID: "claude:x")
        sent.status = .sent
        let start = OrchestratorAction(id: "n", kind: .start, createdAt: t0, text: "New work", agent: "claude", folder: "/Dev/app")
        let expired = OrchestratorAction(id: "e", kind: .reply, createdAt: t0.addingTimeInterval(-2 * 86_400), text: "Late", chatID: "claude:y")
        let actions = [triage, asked, second, sent, start, expired]
        var file = BriefFile()
        _ = BriefReducer.apply(TriageResult(chatID: chat, kind: .decision, headline: "Asks", confidence: 0.9), title: "Fix login", machine: nil,
                               sourceHash: "h", chatUpdatedAt: t0, to: &file, now: t0)
        BriefReducer.attach(proposal: "t", to: file.items[0].id, in: &file)
        let now = t0.addingTimeInterval(120)
        XCTAssertEqual(BriefDrafts.draft(chatID: chat, file: file, actions: actions, now: now)?.id, "t", "triage's own draft first")
        XCTAssertEqual(BriefDrafts.draft(chatID: chat, file: BriefFile(), actions: actions, now: now)?.id, "a", "else the newest waiting reply")
        XCTAssertEqual(BriefDrafts.ready(file: file, actions: actions, now: now).map(\.id).sorted(), ["b", "t"], "one per chat; no sent, expired or start")
        XCTAssertEqual(BriefDrafts.shownInline(file: file, actions: actions, now: now), ["t"])
        XCTAssertEqual(BriefDrafts.menuTitle(0), nil)
        XCTAssertEqual(BriefDrafts.menuTitle(1), "1 draft ready")
        XCTAssertEqual(BriefDrafts.menuTitle(3), "3 drafts ready")
        XCTAssertEqual(BriefDrafts.firstLine(triage.text), "Merge it.")
        XCTAssertEqual(BriefDrafts.firstLine(String(repeating: "a", count: 200), limit: 10).count, 10)
    }

    func testUseFillsOnlyThatChatsComposer() {
        let insert = ComposerInsertion(chatID: chat, text: "Yes, merge.")
        XCTAssertEqual(insert.merged(into: "", chatID: chat), "Yes, merge.")
        XCTAssertEqual(insert.merged(into: "  \n", chatID: chat.uppercased()), "Yes, merge.")
        XCTAssertEqual(insert.merged(into: "Also run the tests.", chatID: chat), "Also run the tests.\n\nYes, merge.", "what he typed stays")
        XCTAssertEqual(insert.merged(into: "Yes, merge.", chatID: chat), "Yes, merge.", "not twice")
        XCTAssertNil(insert.merged(into: "", chatID: "claude:other"))
        XCTAssertNotEqual(ComposerInsertion(chatID: chat, text: "x"), ComposerInsertion(chatID: chat, text: "x"), "each Use is new")
    }

    func testTheBannerTakesTriagesHeadline() {
        XCTAssertEqual(ChatAlertText.body(needsYou: true, title: "Fix login"), "Needs you: Fix login")
        XCTAssertEqual(ChatAlertText.body(needsYou: false, title: " "), "Finished")
        XCTAssertEqual(ChatAlertText.body(needsYou: true, title: "Fix login", headline: "Asks whether to merge #412"), "Fix login: Asks whether to merge #412")
        XCTAssertEqual(ChatAlertText.body(needsYou: true, title: "", headline: "Asks"), "Needs you: Asks")
        XCTAssertEqual(ChatAlertText.body(needsYou: true, title: "Fix login", headline: "  "), "Needs you: Fix login")
    }

    // MARK: Start on another machine

    func testMachinesAndFoldersResolve() throws {
        let devbox = RemoteHost(name: "devbox", destination: "me@devbox")
        let off = RemoteHost(name: "old", destination: "me@old", enabled: false)
        XCTAssertEqual(try OrchestratorMachines.resolve(nil, hosts: [devbox]).get(), nil)
        XCTAssertEqual(try OrchestratorMachines.resolve("this mac", hosts: [devbox]).get(), nil)
        XCTAssertEqual(try OrchestratorMachines.resolve("DevBox", hosts: [devbox]).get()?.id, devbox.id)
        guard case .failure(let refusal) = OrchestratorMachines.resolve("old", hosts: [devbox, off]) else { return XCTFail("disabled machines are refused") }
        XCTAssertEqual(refusal.names, ["This Mac", "devbox"])
        XCTAssertTrue(refusal.message.contains("This Mac, devbox"))
        let known = ["/home/me/app", "/home/me/work/site"]
        XCTAssertEqual(OrchestratorMachines.folder("site", known: known), "/home/me/work/site")
        XCTAssertEqual(OrchestratorMachines.folder("work/site", known: known), "/home/me/work/site")
        XCTAssertEqual(OrchestratorMachines.folder("/srv/x/", known: []), "/srv/x", "an absolute path as given")
        XCTAssertNil(OrchestratorMachines.folder("nowhere", known: known))
        XCTAssertNil(OrchestratorMachines.folder("", known: known))
    }

    func testStartChatOnAnotherMachineRecordsTheHostAndChecksNothingLocally() throws {
        let base = try folder()
        let devbox = RemoteHost(name: "devbox", destination: "me@devbox")
        let machine = OrchestratorState.Machine(id: devbox.id.uuidString, name: "devbox", connection: "online", lastSeen: nil, os: nil, versions: [:],
                                                folders: ["/home/me/site"])
        let tools = try tools(chats: [], hosts: [devbox], machines: [machine], in: base)
        let (text, isError) = tools.call("start_chat", ["agent": "claude", "folder": "site", "prompt": "Fix the footer", "machine": "devbox"])
        XCTAssertFalse(isError, text)
        XCTAssertTrue(text.contains("on devbox"))
        XCTAssertTrue(text.contains("Nothing has started"))
        let action = try XCTUnwrap(tools.actions.load().first)
        XCTAssertEqual(action.hostID, devbox.id.uuidString)
        XCTAssertEqual(action.host, devbox.id)
        XCTAssertEqual(action.machine, "devbox")
        XCTAssertEqual(action.folder, "/home/me/site", "no such folder here, and that's fine")
        XCTAssertTrue(action.isRemoteStart)
        XCTAssertEqual(action.status, .pending, "nothing starts without Send")
        XCTAssertEqual(action.headline, "Start a Claude Code chat in site on devbox")

        let unknown = tools.call("start_chat", ["agent": "codex", "folder": "/x", "prompt": "p", "machine": "laptop"])
        XCTAssertTrue(unknown.1)
        XCTAssertTrue(unknown.0.contains("This Mac, devbox"))
        let missing = tools.call("start_chat", ["agent": "codex", "folder": "nowhere", "prompt": "p", "machine": "devbox"])
        XCTAssertTrue(missing.1)
        XCTAssertTrue(missing.0.contains("on devbox"))
        // The same prompt on this Mac is a different proposal (and still checks the folder here).
        let local = tools.call("start_chat", ["agent": "claude", "folder": "/home/me/site", "prompt": "Fix the footer"])
        XCTAssertTrue(local.1, "that folder doesn't exist on this Mac")
    }

    func testOldActionFilesStillDecodeWithoutAHost() throws {
        let json = #"{"version":1,"actions":[{"id":"a","kind":"start","createdAt":1800000000,"text":"p","agent":"claude","folder":"/Dev/app","status":"pending"}]}"#
        let actions = OrchestratorActionStore.decode(Data(json.utf8))
        XCTAssertEqual(actions.count, 1)
        XCTAssertNil(actions[0].hostID)
        XCTAssertFalse(actions[0].isRemoteStart)
        XCTAssertEqual(actions[0].headline, "Start a Claude Code chat in app")
        var remote = actions[0]
        remote.hostID = UUID().uuidString
        XCTAssertFalse(remote.sameProposal(as: actions[0]), "a start elsewhere isn't the same proposal")
    }

    func testTheSnapshotOffersEachMachinesFoldersAndOverviewListsThem() throws {
        let list = try JSONDecoder().decode(RemoteFolderList.self, from: Data("""
        {"folders":[{"path":"/old","exists":true,"trusted":true,"sources":["claude"],"lastUsed":100},
                    {"path":"/gone","exists":false,"trusted":false,"sources":["codex"]},
                    {"path":"/new","exists":true,"trusted":false,"sources":["codex"],"lastUsed":200}],
         "truncated":false,"warnings":[],"listedAt":0}
        """.utf8))
        XCTAssertEqual(OrchestratorMachines.offered(list), ["/new", "/old"])
        XCTAssertEqual(OrchestratorMachines.offered(nil), [])
        let machine = OrchestratorState.Machine(id: "x", name: "devbox", connection: "online", lastSeen: nil, os: nil, versions: [:], folders: ["/new", "/old"])
        let tools = try tools(chats: [], machines: [machine], in: try folder())
        XCTAssertTrue(tools.call("overview", [:]).0.contains("- devbox: /new, /old"))
        // Snapshots from older builds have no folders.
        let old = #"{"id":"x","name":"devbox","connection":"online","versions":{}}"#
        XCTAssertNil(try JSONDecoder().decode(OrchestratorState.Machine.self, from: Data(old.utf8)).folders)
    }
}
