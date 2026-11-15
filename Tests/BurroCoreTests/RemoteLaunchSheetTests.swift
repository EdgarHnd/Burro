// Starting chats on another machine from the New chat sheet, without any machine: the form with a
// machine (request, per-machine project memory, switching machine), which machine a draft opens on,
// the machine chip's entries, the pending row's hand-over to a remote chat id through its
// placeholder, every remote failure's message, a start whose answer never came back, and the ⌘K
// palette's remote rows and their ranking.
import XCTest
@testable import BurroCore

final class RemoteLaunchSheetTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let studio = RemoteHost(id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, name: "Studio", destination: "me@studio")
    let mini = RemoteHost(id: UUID(uuidString: "66666666-7777-4888-8999-aaaaaaaaaaaa")!, name: "Mini", destination: "me@mini")
    let codexModels = [LaunchModel(id: "gpt-5.5", title: "GPT-5.5", efforts: ["low", "high"], isDefault: true)]
    func models(_ provider: LaunchProvider) -> [LaunchModel] { provider == .codex ? codexModels : LaunchModel.claude }
    func request(_ provider: LaunchProvider, _ folder: String, model: String? = nil, access: LaunchAccess = .ask) -> LaunchRequest {
        LaunchRequest(provider: provider, prompt: "Fix it", folder: folder, model: model, access: access)
    }
    func folder(_ path: String, trusted: Bool = true, exists: Bool = true, git: RemoteFolder.Git? = nil) -> RemoteFolder {
        RemoteFolder(path: path, exists: exists, trusted: trusted, sources: ["claude"], lastUsed: nil, git: git)
    }

    // MARK: Form and memory

    func testTheSamePathOnTwoMachinesIsTwoProjects() {
        var defaults = LaunchDefaults()
        defaults.record(request(.codex, "/Users/me/app", access: .edit))
        defaults.record(request(.claude, "/Users/me/app", access: .readOnly), machine: studio.id)
        XCTAssertEqual(defaults.choice(for: "/Users/me/app", models: models).provider, .codex)
        XCTAssertEqual(defaults.choice(for: "/Users/me/app", models: models).access, .edit)
        XCTAssertEqual(defaults.choice(for: "/Users/me/app", machine: studio.id, models: models).provider, .claude)
        XCTAssertEqual(defaults.choice(for: "/Users/me/app", machine: studio.id, models: models).access, .readOnly)
        XCTAssertEqual(defaults.lastMachineID, studio.id)
        XCTAssertEqual(LaunchDefaults.key("/Users/me/app/", machine: studio.id), "remote:\(studio.id.uuidString):/Users/me/app")

        // This Mac's lists never offer another machine's folders, and vice versa.
        XCTAssertEqual(defaults.lastProject(exists: { _ in true }), "/Users/me/app")
        XCTAssertEqual(defaults.orderedProjects(known: [], exists: { _ in true }).map(\.path), ["/Users/me/app"])
        XCTAssertEqual(defaults.lastProject(machine: studio.id), "/Users/me/app")
        XCTAssertNil(defaults.lastProject(machine: mini.id))

        defaults.record(request(.codex, "/Users/me/other"))
        XCTAssertNil(defaults.lastMachineID, "a launch on this Mac makes This Mac the last machine")
    }

    func testRemoteFoldersListRecentLaunchesFirstAndDropMissingOnes() {
        var defaults = LaunchDefaults()
        defaults.record(request(.codex, "/srv/b"), machine: studio.id)
        defaults.record(request(.codex, "/srv/c"), machine: mini.id)
        let listed = [folder("/srv/a"), folder("/srv/b"), folder("/srv/gone", exists: false), folder("/srv/c")]
        XCTAssertEqual(defaults.orderedFolders(machine: studio.id, folders: listed).map(\.path), ["/srv/b", "/srv/a", "/srv/c"])
        XCTAssertEqual(defaults.orderedFolders(machine: mini.id, folders: listed).map(\.path), ["/srv/c", "/srv/a", "/srv/b"])
    }

    func testFormWithAMachineBuildsTheRequestAndNeedsAnAbsoluteFolder() {
        var defaults = LaunchDefaults()
        defaults.record(request(.claude, "/Users/me/api", model: "claude-sonnet-5-5", access: .edit), machine: studio.id)
        var form = LaunchForm(draft: LaunchDraft(prompt: "Ship it"), machine: studio.id, fallbackFolder: "/local/app", defaults: defaults, models: models)
        XCTAssertEqual(form.machine, studio.id)
        XCTAssertEqual(form.folder, "/Users/me/api", "that machine's last project, not this Mac's fallback")
        XCTAssertEqual(form.choice.provider, .claude)
        XCTAssertEqual(form.choice.access, .edit)
        XCTAssertTrue(form.canStart)
        XCTAssertEqual(form.request, LaunchRequest(provider: .claude, prompt: "Ship it", folder: "/Users/me/api",
                                                   model: form.choice.model.isEmpty ? nil : form.choice.model, access: .edit))

        form.folder = "relative/path"
        XCTAssertFalse(form.canStart, "a folder on another machine must be absolute")

        let fresh = LaunchForm(draft: LaunchDraft(prompt: "Hi"), machine: mini.id, fallbackFolder: "/local/app", defaults: defaults, models: models)
        XCTAssertEqual(fresh.folder, "", "a machine without a last project has no folder yet")
        XCTAssertFalse(fresh.canStart)
    }

    func testSwitchingMachineResetsTheProjectToThatMachinesLastOne() {
        var defaults = LaunchDefaults()
        defaults.record(request(.codex, "/local/app", access: .edit))
        defaults.record(request(.claude, "/srv/api", access: .readOnly), machine: studio.id)
        var form = LaunchForm(draft: LaunchDraft(prompt: "Keep me"), fallbackFolder: "/local/app", defaults: defaults, models: models)
        XCTAssertNil(form.machine)

        form.selectMachine(studio.id, defaults: defaults, localFolder: "/local/app", models: models)
        XCTAssertEqual(form.machine, studio.id)
        XCTAssertEqual(form.folder, "/srv/api")
        XCTAssertEqual(form.choice.provider, .claude)
        XCTAssertEqual(form.choice.access, .readOnly)
        XCTAssertEqual(form.prompt, "Keep me")

        form.selectMachine(mini.id, defaults: defaults, localFolder: "/local/app", models: models)
        XCTAssertEqual(form.folder, "")

        form.selectMachine(nil, defaults: defaults, localFolder: "/local/app", models: models)
        XCTAssertNil(form.machine)
        XCTAssertEqual(form.folder, "/local/app")
        XCTAssertEqual(form.choice.provider, .codex)
        XCTAssertEqual(form.choice.access, .edit)

        // Picking a folder on a machine uses that machine's memory for it.
        form.selectMachine(studio.id, defaults: defaults, localFolder: "/local/app", models: models)
        form.selectProject("/local/app", defaults: defaults, parent: "/ignored", models: models)
        XCTAssertEqual(form.folder, "/local/app")
        XCTAssertEqual(form.choice.provider, .claude, "no memory for /local/app on Studio: the last provider, not this Mac's project")
    }

    func testWhichMachineADraftOpensOn() {
        let usable: (UUID) -> Bool = { $0 == self.studio.id }
        XCTAssertEqual(LaunchDraft().machine(lastMachine: studio.id, usable: usable), studio.id, "⌘N reopens on the last machine")
        XCTAssertNil(LaunchDraft().machine(lastMachine: mini.id, usable: usable), "not while it can't be used")
        XCTAssertNil(LaunchDraft(prompt: "x", folder: "/local").machine(lastMachine: studio.id, usable: usable), "a folder without a machine is on this Mac")
        XCTAssertEqual(LaunchDraft(folder: "/srv", machine: mini.id).machine(lastMachine: nil, usable: usable), mini.id, "an explicit machine is kept")

        let retry = LaunchDraft(retrying: request(.codex, "/srv/api"), machine: studio.id)
        XCTAssertEqual(retry.machine, studio.id)
        XCTAssertEqual(retry.folder, "/srv/api")
        XCTAssertEqual(retry.choice?.provider, .codex)
    }

    func testMemoryWithMachinesRoundTripsAndOlderValuesStillDecode() throws {
        var defaults = LaunchDefaults()
        defaults.record(request(.codex, "/srv/api"), machine: studio.id)
        XCTAssertEqual(LaunchDefaults.decode(defaults.encoded()), defaults)
        let old = #"{"projects":{},"providers":{},"recentProjects":["/p/a"]}"#
        let decoded = try XCTUnwrap(LaunchDefaults.decode(Data(old.utf8)))
        XCTAssertNil(decoded.lastMachineID)
        XCTAssertEqual(decoded.recentProjects, ["/p/a"])
    }

    // MARK: Machine chip

    func testMachineChipListsEveryMachineAndDisablesPausedAndUnreachableOnes() {
        var paused = mini; paused.enabled = false
        let broken = RemoteHost(name: "Bad", destination: "bad host; rm")
        let lab = RemoteHost(name: "Lab", destination: "me@lab")
        let snapshots: [UUID: RemoteHostSnapshot] = [
            studio.id: RemoteHostSnapshot(host: studio, sampledAt: now, attemptedAt: now, state: .online),
            lab.id: RemoteHostSnapshot(host: lab, attemptedAt: now, state: .offline, error: "timeout"),
        ]
        let options = LaunchMachines.options(hosts: [studio, paused, lab, broken], snapshot: { host in
            host.enabled ? snapshots[host.id] ?? RemoteHostSnapshot(host: host) : RemoteHostSnapshot(host: host, state: .disabled)
        }, status: { host in host.id == lab.id ? "Unreachable since 14:02 · retrying in 30 s" : (host.enabled ? "Connected · checked just now" : "Paused") })
        XCTAssertEqual(options.map(\.name), ["This Mac", "Studio", "Mini", "Lab", "Bad"])
        XCTAssertEqual(options.map(\.available), [true, true, false, false, false])
        XCTAssertEqual(options[2].unavailable, "Paused")
        XCTAssertEqual(options[3].unavailable, "Unreachable since 14:02 · retrying in 30 s")
        XCTAssertNotNil(options[4].unavailable)
        XCTAssertEqual(LaunchMachines.rowTitle(options[1]), "Studio · Connected · checked just now")
        XCTAssertEqual(LaunchMachines.rowTitle(options[0]), "This Mac")

        // Not checked yet is usable: the start itself reports a problem.
        XCTAssertNil(LaunchMachines.unavailability(RemoteHostSnapshot(host: studio), status: "Connecting…"))
    }

    func testFolderRowsShowRepositoryBranchAndClaudeTrust() {
        let worktree = folder("/srv/app-fix", trusted: false, git: RemoteFolder.Git(root: "/srv/app", branch: "fix/login", worktree: true))
        XCTAssertEqual(LaunchMachines.folderTitle(worktree, provider: .claude), "app-fix · app on fix/login · not trusted by Claude yet")
        XCTAssertEqual(LaunchMachines.folderTitle(worktree, provider: .codex), "app-fix · app on fix/login")
        XCTAssertEqual(LaunchMachines.folderTitle(folder("/srv/plain"), provider: .claude), "plain")
        XCTAssertEqual(LaunchMachines.folderTitle(folder("/srv/app", git: RemoteFolder.Git(root: "/srv/app", branch: nil, worktree: false)), provider: .codex), "app")
    }

    // MARK: Pending row and hand-over

    func testARemoteStartHandsOverToItsChatIDThroughAPlaceholder() throws {
        var launches = PendingLaunches()
        let launch = launches.begin(request(.claude, "/srv/api"), follow: true, now: now, machine: studio.id, machineName: "Studio")
        XCTAssertEqual(launches.launch(launch.id)?.status(now: now), "Starting on Studio… checking it got going")
        XCTAssertTrue(launches.placeholders(now: now).isEmpty, "nothing to show before the machine answers")

        let confirmed = now.addingTimeInterval(20)
        launches.succeed(launch.id, with: LaunchResult(provider: .claude, sessionID: "8E0C2A1B-0000-4000-8000-000000000001", handle: "8e0c2a1b", folder: "/srv/api"),
                         now: confirmed)
        let chatID = "remote:\(studio.id.uuidString):claude:8e0c2a1b-0000-4000-8000-000000000001"
        XCTAssertEqual(launches.launch(launch.id)?.chatID, chatID)
        XCTAssertEqual(chatID, RemoteLaunch.chatID(hostID: studio.id, provider: .claude, sessionID: "8e0c2a1b-0000-4000-8000-000000000001"))
        XCTAssertEqual(ChatTranscripts.identity(chatID: chatID)?.host, studio.id, "the Chats page can load its transcript by this id")

        // The placeholder goes into Studio's list; the feed then shows it and the row hands over.
        let placeholders = launches.placeholders(now: confirmed)
        XCTAssertEqual(placeholders.map(\.hostID), [studio.id])
        let placeholder = try XCTUnwrap(placeholders.first?.session)
        XCTAssertEqual(placeholder.id, chatID)
        XCTAssertEqual(placeholder.provider, .claude)
        XCTAssertEqual(placeholder.cwd, "/srv/api")
        XCTAssertEqual(placeholder.remote?.hostID, studio.id)
        XCTAssertEqual(ChatTranscripts.identity(of: placeholder)?.id, "8e0c2a1b-0000-4000-8000-000000000001")

        let old = RemoteHostSnapshot(host: studio, sampledAt: now, attemptedAt: now, state: .online)
        let withPlaceholder = old.addingPlaceholder(placeholder)
        XCTAssertEqual(withPlaceholder.sessions.map(\.id), [chatID])
        XCTAssertEqual(withPlaceholder.addingPlaceholder(placeholder).sessions.count, 1, "added once")
        XCTAssertTrue(withPlaceholder.checkedSessionIDs.isEmpty, "a placeholder never counts as listed")

        let matched = launches.reconcile(feedIDs: withPlaceholder.displaySessions(now: confirmed).map(\.id))
        XCTAssertEqual(matched.map(\.rowID), [launch.rowID])
        XCTAssertEqual(matched.map(\.sessionID), [chatID])
        XCTAssertTrue(launches.visible.isEmpty, "the row gives way to the chat")
        XCTAssertNotNil(launches.launch(launch.id), "but is kept until a check lists the chat")
        XCTAssertTrue(launches.reconcile(feedIDs: [chatID]).isEmpty, "handed over once")

        // A check made before the start was confirmed, or one that doesn't list it, settles nothing.
        launches.settle(samples: [studio.id: (now, [chatID])], now: confirmed.addingTimeInterval(5))
        XCTAssertNotNil(launches.launch(launch.id))
        launches.settle(samples: [studio.id: (confirmed.addingTimeInterval(4), ["remote:\(studio.id.uuidString):codex:other"])], now: confirmed.addingTimeInterval(5))
        XCTAssertNotNil(launches.launch(launch.id))
        XCTAssertEqual(launches.placeholders(now: confirmed.addingTimeInterval(5)).count, 1, "so its placeholder is put back")
        // A later check that lists it does.
        launches.settle(samples: [studio.id: (confirmed.addingTimeInterval(8), [chatID.uppercased()])], now: confirmed.addingTimeInterval(9))
        XCTAssertNil(launches.launch(launch.id))
    }

    func testAHandedOverPlaceholderExpiresAndAStartedRowSaysWhenItsLate() {
        var launches = PendingLaunches()
        let launch = launches.begin(request(.codex, "/srv/api"), follow: false, now: now, machine: studio.id, machineName: "Studio")
        launches.succeed(launch.id, with: LaunchResult(provider: .codex, sessionID: "019a0000-0000-7000-8000-000000000001", handle: nil, folder: "/srv/api"), now: now)
        XCTAssertEqual(launches.launch(launch.id)?.status(now: now), "Started · opening…")
        XCTAssertFalse(launches.launch(launch.id)!.isOverdue(now: now.addingTimeInterval(60)), "another machine gets longer to appear")
        XCTAssertEqual(launches.launch(launch.id)?.status(now: now.addingTimeInterval(100)), "Started · appears at the next check")

        launches.settle(samples: [:], now: now.addingTimeInterval(500))
        XCTAssertNotNil(launches.launch(launch.id), "a row still shown is never dropped silently")
        _ = launches.reconcile(feedIDs: [launches.launch(launch.id)!.chatID!])
        launches.settle(samples: [:], now: now.addingTimeInterval(500))
        XCTAssertNil(launches.launch(launch.id))
    }

    func testLocalStartsStillHandOverAndLeaveAtOnce() {
        var launches = PendingLaunches()
        let launch = launches.begin(request(.codex, "/p"), follow: true, now: now)
        launches.succeed(launch.id, with: LaunchResult(provider: .codex, sessionID: "019A-T", handle: nil, folder: "/p"))
        XCTAssertEqual(launches.launch(launch.id)?.chatID, "codex:019a-t")
        XCTAssertNil(launches.launch(launch.id)?.placeholderSession(now: now))
        XCTAssertTrue(launches.placeholders(now: now).isEmpty)
        XCTAssertEqual(launches.reconcile(feedIDs: ["remote:\(studio.id.uuidString):codex:019a-t"]).count, 0, "a remote chat never matches a local start")
        XCTAssertEqual(launches.reconcile(feedIDs: ["codex:019a-t"]).count, 1)
        XCTAssertTrue(launches.isEmpty)
    }

    // MARK: Failures

    func testEveryRemoteFailureBecomesAClearMessage() {
        let utc = TimeZone(identifier: "UTC")!
        let seen = Date(timeIntervalSince1970: 1_800_000_000 - 3600)   // 07:00 UTC that day
        func message(_ error: Error, lastSeen: Date? = nil) -> String {
            RemoteLaunchFailure.message(error, machine: "Studio", lastSeen: lastSeen, now: now, timeZone: utc)
        }
        XCTAssertEqual(message(RemoteLaunchError.unreachable(host: "studio"), lastSeen: seen),
                       "Couldn't reach Studio over SSH. Last seen \(RemoteStatusLine.clock(seen, now: now, timeZone: utc)). Check that it's awake and online, then Retry.")
        XCTAssertTrue(message(RemoteLaunchError.unreachable(host: "studio")).contains("Burro hasn't reached it yet."))
        XCTAssertEqual(message(RemoteLaunchError.claudeNotInstalled(host: "studio")),
                       "Claude Code isn't installed on Studio. Install it there, or start the chat with Codex.")
        XCTAssertTrue(message(RemoteLaunchError.codexNotInstalled(host: "studio")).hasPrefix("Codex isn't installed on Studio."))
        XCTAssertEqual(message(RemoteLaunchError.codexNotStandalone(host: "studio", detail: "Codex on Studio isn't the standalone install.")),
                       "Codex on Studio isn't the standalone install.")
        XCTAssertEqual(message(RemoteLaunchError.untrusted(host: "studio", folder: "/srv/api")),
                       "Claude hasn't been trusted in api on Studio yet. Open Terminal on Studio, run `claude` in that folder once and accept, then Retry.")
        let blocked = message(RemoteLaunchError.blocked(host: "Studio", folder: "/srv/api", reason: "approve 1 MCP server"))
        XCTAssertTrue(blocked.contains("approve 1 MCP server") && blocked.contains("Burro removed that stuck session"))
        XCTAssertTrue(message(RemoteLaunchError.notConfirmed(host: "Studio")).contains("it appears at the next check"))
        XCTAssertTrue(message(RemoteLaunchError.unconfirmed(host: "Studio", handle: "abc12345")).contains("Burro removed it"))
        XCTAssertEqual(message(RemoteLaunchError.folder(host: "Studio", reason: "That folder doesn't exist on this machine.")),
                       "That folder doesn't exist on this machine (Studio).")
        XCTAssertEqual(message(RemoteLaunchError.failed("Claude didn't start: boom")), "Claude didn't start: boom")
        XCTAssertEqual(message(LaunchError.emptyPrompt), LaunchError.emptyPrompt.errorDescription)
    }

    func testAClaudeStartWhoseAnswerNeverCameBackIsNotConfirmedRatherThanFailed() {
        let request = LaunchRequest(provider: .claude, prompt: "Go", folder: "/srv/api")
        XCTAssertThrowsError(try RemoteLaunch.startClaude(request, host: studio, run: { _, _, _ in throw RemoteLaunchError.timedOut(host: "Studio") })) { error in
            XCTAssertEqual(error as? RemoteLaunchError, .notConfirmed(host: "Studio"))
        }
        // Other calls keep the plain timeout.
        XCTAssertThrowsError(try RemoteLaunch.folders(host: studio, cache: RemoteCache(root: FileManager.default.temporaryDirectory.appendingPathComponent("burro-rls-\(UUID().uuidString)")),
                                                      now: now, run: { _, _, _ in throw RemoteLaunchError.timedOut(host: "Studio") })) { error in
            XCTAssertEqual(error as? RemoteLaunchError, .timedOut(host: "Studio"))
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "Studio didn't answer in time.")
        }
    }

    // MARK: Palette

    func testPaletteOffersEachEnabledMachineAndItsFoldersBelowThisMacs() {
        var paused = mini; paused.enabled = false
        let entries = CommandPaletteRemoteLaunch.entries(hosts: [studio, paused]) { host in
            host.id == self.studio.id ? [self.folder("/srv/app"), self.folder("/srv/gone", exists: false), self.folder("/srv/app")] : [self.folder("/m/x")]
        }
        XCTAssertEqual(entries.map(\.item.title), ["New chat on Studio…", "New chat in app on Studio…"])
        XCTAssertEqual(entries.map(\.machine), [studio.id, studio.id])
        XCTAssertEqual(entries.map(\.folder), [nil, "/srv/app"])
        XCTAssertEqual(Set(entries.map(\.item.id)).count, entries.count)

        let local = CommandPaletteItem(id: "action:new-chat-in:/Users/me/app", kind: .action, title: "New chat in app…",
                                       subtitle: "Opens the New chat sheet", keywords: ["start", "launch"])
        let index = CommandPaletteIndex([entries[1].item, local] + [entries[0].item])
        let results = index.results(for: "new chat in app").map(\.id)
        XCTAssertEqual(results.first, local.id, "this Mac's folder ranks first")
        XCTAssertTrue(results.contains(entries[1].item.id))
        XCTAssertEqual(index.results(for: "studio").first?.id, entries[0].item.id)

        let many = CommandPaletteRemoteLaunch.entries(hosts: [studio]) { _ in (0..<100).map { self.folder("/srv/f\($0)") } }
        XCTAssertEqual(many.count, 1 + CommandPaletteRemoteLaunch.folderLimit)
    }
}
