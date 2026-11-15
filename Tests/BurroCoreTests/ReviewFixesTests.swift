// Fixes from an independent review: the reply cards' Send help for idle Claude chats, remote chats
// a machine no longer has, "seen" marks only while you are there and never hiding alerts, queued
// replies kept when the provider says busy, media copies recorded under the cache lock, the triage
// Off switch stopping a run, the remote stop-and-continue timeouts, Orchestrator file roots, and
// to-do Undo that only reverses what it did. Nothing here runs Claude, SSH or a real chat.
import XCTest
@testable import BurroCore

final class ReviewFixesTests: XCTestCase {
    private let id = "11111111-2222-4333-8444-555555555555"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("burro-review-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func session(_ state: AgentState = .idle, provider: AgentProvider = .claude, unread: Bool? = nil) -> AgentSession {
        var value = AgentSession(id: "claude:\(id)", provider: provider, title: "Fix it", cwd: "/tmp", state: state, updatedAt: now, evidence: "fixture")
        value.hasUnreadResult = unread
        return value
    }

    // MARK: 1. Card Send help

    func testCardSendHelpSaysAnIdleClaudeSessionIsStoppedAndContinued() {
        XCTAssertTrue(ChatReply.cardSendHelp(provider: .claude).contains("stops it and continues it"))
        XCTAssertEqual(ChatReply.cardSendHelp(provider: .codex), "Send this reply to the chat")
        XCTAssertEqual(ChatReply.cardSendHelp(provider: nil), "Send this reply to the chat")
    }

    // MARK: 2. A remote chat the machine no longer has

    func testOnlyAnUnreachableMachineIsAskedAgainOnTheTimer() {
        XCTAssertTrue(RemoteTranscriptMirror.Offline.unreachable("timed out").retriesOnTimer)
        XCTAssertFalse(RemoteTranscriptMirror.Offline.missing.retriesOnTimer)
    }

    // MARK: 3. Seen in Burro

    func testAChatIsMarkedSeenOnlyWhileYouAreThere() {
        XCTAssertTrue(ChatSeen.marks(onChatsPage: true, windowVisible: true, windowKey: true, appActive: true))
        XCTAssertFalse(ChatSeen.marks(onChatsPage: true, windowVisible: true, windowKey: false, appActive: true), "Visible on a second display, another window key")
        XCTAssertFalse(ChatSeen.marks(onChatsPage: true, windowVisible: true, windowKey: true, appActive: false), "Another app in front")
        XCTAssertFalse(ChatSeen.marks(onChatsPage: true, windowVisible: false, windowKey: true, appActive: true))
        XCTAssertFalse(ChatSeen.marks(onChatsPage: false, windowVisible: true, windowKey: true, appActive: true))
    }

    func testSeenOnlyChangesTheDisplayCopyNotWhatAlertsAndTriageSee() {
        var seen = ChatSeen()
        let finished = session(unread: true)
        seen.mark(finished)
        var manage = ChatManage()
        manage.rename(finished.id, to: "My title")
        let copies = seen.copies([finished], manage: manage)
        XCTAssertEqual(copies.display.first?.hasUnreadResult, false, "Burro shows it as read")
        XCTAssertEqual(copies.attention.first?.hasUnreadResult, true, "Notifications and triage still see a finished chat")
        XCTAssertEqual(copies.display.first?.title, "My title")
        XCTAssertEqual(copies.attention.first?.title, "My title")
    }

    // MARK: 4. Queued replies and busy refusals

    func testTheProvidersWorkingOrWaitingRefusalIsTyped() {
        let busy = ChatReply.ClaudeLive(handle: "c0d2240d", background: true, busy: true)
        let waiting = ChatReply.ClaudeLive(handle: "c0d2240d", background: true, busy: false, waiting: true)
        let idle = ChatReply.ClaudeLive(handle: "c0d2240d", background: true, busy: false, idle: true)
        let interactive = ChatReply.ClaudeLive(handle: nil, background: false, busy: false, idle: true)
        XCTAssertEqual(ReplyRefusal.of(busy, message: "m")?.reason, .working)
        XCTAssertEqual(ReplyRefusal.of(waiting, message: "m")?.reason, .waiting)
        XCTAssertNil(ReplyRefusal.of(idle, message: "m"))
        XCTAssertNil(ReplyRefusal.of(interactive, message: "m"), "Open in a terminal stays an ordinary refusal")
        XCTAssertNil(ReplyRefusal.of(nil, message: "m"))
        XCTAssertEqual(ReplyRefusal.remote(["kind": "background", "busy": true], message: "m")?.reason, .working)
        XCTAssertEqual(ReplyRefusal.remote(["kind": "background", "busy": false, "waiting": true], message: "m")?.reason, .waiting)
        XCTAssertNil(ReplyRefusal.remote(["kind": "interactive", "busy": false, "waiting": true], message: "m"))
        XCTAssertNil(ReplyRefusal.remote(["kind": "background", "attached": true, "idle": true], message: "m"))
        XCTAssertNil(ReplyRefusal.remote(nil, message: "m"))
        XCTAssertEqual(ReplyRefusal(.working, message: "Claude is working").errorDescription, "Claude is working")
    }

    func testTheLocalReplyThrowsTheTypedRefusalForBusyAndWaitingOnly() {
        func listing(_ fields: [String: Any]) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: [(["sessionId": id] as [String: Any]).merging(fields) { $1 }]), as: UTF8.self)
        }
        func error(for text: String) -> Error? {
            let commands = ClaudeCommands(run: { arguments, _, _ in
                arguments.first == "agents" ? (0, text) : (0, "Resumed")
            }, processes: { "" }, sleep: { _ in })
            let args = ChatReply.claudeArguments(sessionID: id, ReplyRequest(text: "go on"))
            do { _ = try ChatReply.continueClaude(id, arguments: args, folder: "/tmp", stopIdleBackground: true, commands: commands); return nil }
            catch { return error }
        }
        let busy = error(for: listing(["id": "c0d2240d", "kind": "background", "pid": 42, "status": "busy"]))
        XCTAssertEqual((busy as? ReplyRefusal)?.reason, .working)
        let waiting = error(for: listing(["id": "c0d2240d", "kind": "background", "pid": 42, "status": "waiting", "state": "blocked"]))
        XCTAssertEqual((waiting as? ReplyRefusal)?.reason, .waiting)
        let interactive = error(for: listing(["kind": "interactive", "pid": 7, "status": "idle"]))
        XCTAssertNotNil(interactive)
        XCTAssertNil(interactive as? ReplyRefusal)
        XCTAssertTrue(ReplyQueue.retries(after: busy!))
        XCTAssertTrue(ReplyQueue.retries(after: waiting!))
        XCTAssertFalse(ReplyQueue.retries(after: interactive!))
        XCTAssertFalse(ReplyQueue.retries(after: LaunchError.failed("Claude didn't continue.")))
    }

    func testABusyRefusalKeepsTheMessageQueuedAndTriesAgainWhenIdle() throws {
        var queue = ReplyQueue()
        let chat = "claude:\(id)"
        try queue.enqueue(QueuedReply(chatID: chat, request: ReplyRequest(text: "then commit"), queuedAt: now))
        queue.markDispatched(chatID: chat, at: now.addingTimeInterval(10))
        queue.requeue(chatID: chat, now: now.addingTimeInterval(12))
        let item = try XCTUnwrap(queue.item(for: chat), "Still queued")
        XCTAssertNil(item.dispatchedAt, "No longer marked as going, so it isn't dropped as maybe-sent")
        XCTAssertEqual(item.text, "then commit")
        let idle = session(.idle)
        // Not before the retry delay, even though the chat looks idle.
        XCTAssertEqual(ReplyQueue.decision(item, session: idle, missingSince: nil, idleSince: now.addingTimeInterval(13),
                                           now: now.addingTimeInterval(20)), .wait)
        // Waits while the chat is working, then goes once it has settled idle again.
        XCTAssertEqual(ReplyQueue.decision(item, session: session(.working), missingSince: nil, idleSince: nil, now: now.addingTimeInterval(60)), .wait)
        XCTAssertEqual(ReplyQueue.decision(item, session: idle, missingSince: nil, idleSince: now.addingTimeInterval(60),
                                           now: now.addingTimeInterval(61)), .wait, "Idle timer restarted")
        XCTAssertEqual(ReplyQueue.decision(item, session: idle, missingSince: nil, idleSince: now.addingTimeInterval(60),
                                           now: now.addingTimeInterval(64)), .dispatch)
        // Still dropped a day after it was queued.
        if case .drop = ReplyQueue.decision(item, session: idle, missingSince: nil, idleSince: now, now: now.addingTimeInterval(86_400)) {} else {
            XCTFail("expires")
        }
        // Saved and loaded with its retry time; files without it still load.
        let store = ReplyQueueStore(url: try folder().appendingPathComponent("reply-queue.json"))
        try store.save(queue)
        XCTAssertEqual(store.load().item(for: chat)?.retryAfter, now.addingTimeInterval(12 + ReplyQueue.retryDelay))
    }

    // MARK: 5. Media copies under the cache lock

    func testACopyMovedInThroughTheLockedWriteSurvivesASweep() throws {
        let cache = RemoteCache(root: try folder())
        let host = UUID()
        let media = try cache.directory(.media, hostID: host)
        let partial = media.appendingPathComponent("0123456789abcdef.png-1234.part")
        try Data("png".utf8).write(to: partial)
        let target = media.appendingPathComponent("0123456789abcdef.png")
        try cache.writing(.media, hostID: host) { _ in
            XCTAssertEqual(rename(partial.path, target.path), 0)
            return RemoteCacheEntry(key: "abc", file: "0123456789abcdef.png", remotePath: "/x/abc.png", size: 3, remoteMTime: 1, fetchedAt: now, openedAt: now)
        }
        cache.sweep(.media, now: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(cache.entry(.media, hostID: host, key: "abc")?.url.lastPathComponent, "0123456789abcdef.png")
        // A copy that is in the folder without its entry is what a sweep removes.
        let stray = media.appendingPathComponent("fedcba9876543210.png")
        try Data("png".utf8).write(to: stray)
        cache.sweep(.media, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
    }

    // MARK: 6. Triage Off stops a run

    private func triageInput() -> TriageInput {
        TriageInput.build(chatID: "claude:\(id)", title: "Fix it", project: "app", machine: "This Mac", stop: .finished,
                          messages: [ChatMessage(id: 1, kind: .assistant, text: "Done. Shall I push?", at: now)], notes: [])
    }

    func testACancelledTriageNeverCallsClaude() {
        let cancel = ProcessCancel()
        cancel.cancel()
        let called = Locked(false)
        let runner = TriageRunner(executable: { "/fake" }, run: { _, _, _, _ in called.set(true); return (0, "{}") })
        XCTAssertNil(OrchestratorTriage.run([triageInput()], trigger: "triage", runner: runner, cancel: cancel))
        XCTAssertFalse(called.value)
    }

    func testTurningTriageOffDuringTheCallStopsItAndDropsTheAnswer() {
        let cancel = ProcessCancel()
        let usedCancellable = Locked(false)
        let runner = TriageRunner(executable: { "/fake" }, run: { _, _, _, _ in (0, "{}") }, cancellable: { _, _, _, _, token in
            usedCancellable.set(true)
            token.cancel()
            throw CancellationError()
        })
        XCTAssertNil(OrchestratorTriage.run([triageInput()], trigger: "triage", runner: runner, cancel: cancel))
        XCTAssertTrue(usedCancellable.value, "A stoppable runner gets the token")
        // A runner that can't be stopped: its answer is still dropped.
        let late = ProcessCancel()
        let plain = TriageRunner(executable: { "/fake" }, run: { _, _, _, _ in late.cancel(); return (0, "anything") })
        XCTAssertNil(OrchestratorTriage.run([triageInput()], trigger: "triage", runner: plain, cancel: late))
    }

    func testCancellingStopsTheProcessBeingWaitedOn() {
        let cancel = ProcessCancel()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancel.cancel() }
        let started = Date()
        XCTAssertThrowsError(try LaunchShell.run("/bin/sleep", ["20"], timeout: 30, cancel: cancel)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    // MARK: 7. Remote stop-and-continue timeouts

    func testRemoteContinueEndsInsideBurrosWait() throws {
        XCTAssertEqual(ChatReply.remoteTimeout(["continue": ["--bg"]]), 150)
        XCTAssertEqual(ChatReply.remoteTimeout(["args": ["--bg"]]), 90)
        let script = try String(contentsOf: try XCTUnwrap(RemoteScript.url("remote_reply")), encoding: .utf8)
        func constants(_ prefix: String) throws -> [Double] {
            let line = try XCTUnwrap(script.split(separator: "\n").first { $0.hasPrefix(prefix) })
            return line.split(separator: "=")[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        let steps = try constants("CONTINUE_LOOKUP, CONTINUE_PS, CONTINUE_STOP, RESUME")
        let wait = try constants("STOP_WAIT, STOP_POLL")
        XCTAssertEqual(steps, [10, 5, 20, 55])
        let (lookup, ps, stop, resume) = (steps[0], steps[1], steps[2], steps[3])
        // First lookup, the attach check, the stop, the confirmation (its last lookup may start just
        // before the deadline), and the resume, with room for the SSH connection.
        let worst = lookup + ps + stop + (wait[0] + wait[1] + lookup) + resume
        XCTAssertLessThan(worst + 20, ChatReply.remoteTimeout(["continue": []]))
    }

    // MARK: 8. Orchestrator file roots

    func testOnlyRepositoriesAndWorktreesAreRootsAndPrivateHomeFoldersStayPrivate() throws {
        let home = try folder()
        let repo = home.appendingPathComponent("Dev/app"), loose = home.appendingPathComponent("Documents/notes")
        let config = home.appendingPathComponent(".config/tool"), cloud = home.appendingPathComponent("Library/Mobile Documents/proj")
        let tree = home.appendingPathComponent("Dev/app-feature")
        for url in [repo, loose, config, cloud, tree] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try Data("main".utf8).write(to: repo.appendingPathComponent("main.swift"))
        try Data("secret".utf8).write(to: loose.appendingPathComponent("diary.txt"))
        try Data("machine x password y".utf8).write(to: home.appendingPathComponent(".netrc"))
        func project(_ url: URL, repository: Bool) -> OrchestratorState.Project {
            .init(name: url.lastPathComponent, path: url.path, isRepository: repository, worktrees: 1, readyToRemove: 0, tokensToday: 0, lastActive: nil)
        }
        let worktree = OrchestratorState.WorktreeRow(path: tree.path, repository: "app", repositoryPath: repo.path, branch: "feature", isPrimary: false,
                                                     changed: 0, untracked: 0, unpushed: 0, lastCommit: nil, activity: "", readyToRemove: false)
        let state = OrchestratorState(mainProject: repo.path, machines: [],
                                      projects: [project(repo, repository: true), project(loose, repository: false),
                                                 project(config, repository: true), project(cloud, repository: true)],
                                      chats: [], worktrees: [worktree], todos: [], hosts: [], profiles: [:])
        let access = OrchestratorFileAccess.standard(state: state, home: home.path)
        let canonical = { (url: URL) in OrchestratorFileAccess.canonical(url.path)! }
        XCTAssertEqual(access.roots, [canonical(repo), canonical(tree)],
                       "A chat's loose working folder, anything in a hidden home folder and anything in ~/Library are never roots")
        if case .success = access.read(loose.appendingPathComponent("diary.txt").path) { XCTFail("loose folder") }
        if case .success = access.read(home.appendingPathComponent(".netrc").path) { XCTFail(".netrc") }
        if case .failure = access.read(repo.appendingPathComponent("main.swift").path) { XCTFail("repository file") }
        XCTAssertFalse(access.search(query: "secret", name: nil).contains("diary"))

        let denied = OrchestratorFileAccess.expand(OrchestratorFileAccess.deniedFolders(home: home.path))
        let homes = [home.path.lowercased()]
        for path in [".config/gh/hosts.yml", ".docker/config.json", ".kube/config", ".netrc", ".npmrc", ".zsh_history", "Library/Preferences/x.plist",
                     "Library/Mobile Documents/proj/a.txt"] {
            XCTAssertTrue(OrchestratorFileAccess.isPrivate(home.appendingPathComponent(path).path, denied, homes), path)
        }
        for path in ["Dev/app/.env.example-not-root-level", "Dev/app/.github/workflows/ci.yml"] {
            XCTAssertFalse(OrchestratorFileAccess.isPrivate(home.appendingPathComponent(path).path, denied, homes), "Hidden entries inside a project are fine: \(path)")
        }
    }

    // MARK: 9. To-do Undo

    func testUndoReversesOnlyAChangeThatHappenedOnTheToDoItTouched() throws {
        let store = OrchestratorActionStore(url: try folder().appendingPathComponent("actions.json"))
        _ = try store.request(.completeTodo(id: "todo-1", text: "Ship it", now: now, conversation: nil), now: now)
        _ = try store.request(.addTodo(text: "Write tests", project: nil, now: now, conversation: nil), now: now)
        let claimed = try store.claimLocal(now: now, newID: { "abc" })
        let complete = try XCTUnwrap(claimed.first { $0.kind == .completeTodo })
        let add = try XCTUnwrap(claimed.first { $0.kind == .addTodo })
        XCTAssertFalse(complete.canUndo(now: now), "No Undo until Burro recorded what applying did")

        // Already ticked by you: applying changed nothing, so there is nothing to undo.
        try store.recordLocal(complete.id, changed: false, todoID: "todo-1")
        let unchanged = try XCTUnwrap(store.load().first { $0.id == complete.id })
        XCTAssertFalse(unchanged.canUndo(now: now))
        XCTAssertNil(unchanged.undoTarget)
        XCTAssertEqual(unchanged.headline, "“Ship it” was already done")
        XCTAssertNil(try store.undoLocal(complete.id, now: now), "Undo does nothing")

        // Added: Undo targets exactly the id it was added under.
        try store.recordLocal(add.id, changed: true, todoID: "local:abc")
        let added = try XCTUnwrap(store.load().first { $0.id == add.id })
        XCTAssertTrue(added.canUndo(now: now))
        XCTAssertEqual(added.undoTarget, "local:abc")
        let before = try XCTUnwrap(try store.undoLocal(add.id, now: now))
        XCTAssertEqual(before.undoTarget, "local:abc")
        XCTAssertEqual(store.load().first { $0.id == add.id }?.status, .undone)

        // Files written before this field existed: no Undo rather than a guess.
        var legacy = OrchestratorAction.completeTodo(id: "todo-2", text: "Old", now: now, conversation: nil)
        legacy.status = .applied; legacy.appliedAt = now
        XCTAssertFalse(legacy.canUndo(now: now))
    }
}

/// A value tests can set from a `@Sendable` closure.
private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}
