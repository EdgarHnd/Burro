// Starting chats from the New chat sheet without waiting on it. Every entry point (⌘N, the ⌘K
// palette's "Start chat: …", a to-do, a note, a worktree, Retry) only opens the sheet prefilled;
// the sheet's Start (⌘↩, or ⇧⌘↩ to stay put) is the one explicit action that launches. The sheet
// closes at once and a pending "Starting…" row appears on the Chats page (selected, with the page
// shown, unless ⇧⌘↩). The provider is called off the main thread; for Claude that includes the
// start check of up to 20 seconds. When the provider answers, Burro refreshes its feed a few
// times until the session appears, then swaps the pending row for the real chat. A failure turns
// the row into the error with Retry (the sheet again, prefilled with the same request).
// On another machine the start goes through `RemoteLaunch` (Codex or Claude, off the main thread)
// and the row says "Starting on <Machine>…". When that machine answers, the chat's placeholder is
// put in the machine's list and selected at once, so the transcript loads before any check sees the
// chat; a check of that machine is requested right away, and the placeholder is re-added after
// checks that don't list the chat yet (for up to two minutes). A failure becomes one clear message
// (`RemoteLaunchFailure`) with Retry, the machine included.
// "Start in a new worktree" (this Mac only): the row first says "Creating worktree <branch>…" while
// `NewWorktree` makes it off the main thread; the chat then starts in the new folder (the same
// subfolder of it when the project is a subfolder of its repository). If the worktree can't be
// made, nothing of it is left, the chat is not started, and the row shows the error with Retry
// (the sheet again with the switch on).
// Dismissing a Starting / Creating worktree row cancels the start: the row is checked before the
// worktree is made and again before the chat is launched; a worktree made for a dismissed row is
// undone (as on failure, without forcing) and the chat is not started; if the undo leaves anything
// behind, the row comes back failed, listing what is left (path, branch, folder) to remove from
// Worktrees. Once the provider has been called the chat can't be called back; Dismiss then only
// hides the row.
// The sheet's per-project memory (`LaunchDefaults`) lives in preferences under `launch.defaults`;
// its recent prompts and templates (`LaunchPromptMemory`) under `launch.prompts`. Both stay on this Mac.
import AppKit
import BurroCore

extension AppStore {
    /// Preference key for Settings → Agent notch → "Open chats in Burro" (default on).
    nonisolated static let openChatsInBurroKey = "chats.openInBurro"
    var openChatsInBurro: Bool { UserDefaults.standard.object(forKey: Self.openChatsInBurroKey) as? Bool ?? true }

    // MARK: Opening the sheet

    /// Opens the New chat sheet prefilled. Never starts anything.
    func openNewChat(_ draft: LaunchDraft = LaunchDraft()) {
        newChatDraft = draft
        newChatPresented = true
    }
    /// "Start chat from this…" on a to-do: its text, in its project when it names one Burro knows.
    func startChat(from todo: TodoItem) {
        let folder = LaunchDraft.folder(forProject: todo.project, among: launchFolders, exists: FileManager.default.fileExists(atPath:))
        openNewChat(LaunchDraft(prompt: LaunchDraft.prompt(from: todo.text), folder: folder ?? currentLaunchProject?.path))
    }
    /// "Start chat from this…" on a note, or the palette's typed text: in the current or last project.
    func startChat(withText text: String) {
        openNewChat(LaunchDraft(prompt: LaunchDraft.prompt(from: text), folder: currentLaunchProject?.path))
    }

    /// The project a prefilled chat goes to when its source doesn't name one: the worktree selected on
    /// the Worktrees page, the local chat selected on the Chats page, else the last launch, else the main project.
    var currentLaunchProject: (path: String, name: String)? {
        func named(_ path: String) -> (path: String, name: String) {
            launchFolders.first { LaunchDefaults.key($0.path) == LaunchDefaults.key(path) } ?? (path, URL(fileURLWithPath: path).lastPathComponent)
        }
        if page == .worktrees, let id = selection, let tree = snapshot.worktrees.first(where: { $0.id == id }), !tree.isMissing {
            return named(tree.path)
        }
        if page == .remote, let session = notchChatSessions.first(where: { $0.id == remoteSelection }), session.remote == nil {
            return named(workspacePath(for: session))
        }
        if let last = launchDefaults.lastProject(exists: FileManager.default.fileExists(atPath:)) { return named(last) }
        return mainProject
    }

    /// The repository a worktree folder belongs to, so a new worktree borrows its repository's launch memory.
    func launchParent(of folder: String) -> String? {
        let key = LaunchDefaults.key(folder)
        guard let tree = snapshot.worktrees.first(where: { LaunchDefaults.key($0.path) == key }) else { return nil }
        return tree.repositoryPath == tree.path ? nil : tree.repositoryPath
    }

    // MARK: Memory

    var launchDefaults: LaunchDefaults {
        get {
            let stored = UserDefaults.standard
            if let saved = LaunchDefaults.decode(stored.data(forKey: LaunchDefaults.preferencesKey)) { return saved }
            return LaunchDefaults.migrating { stored.object(forKey: $0) }
        }
        set { if let data = newValue.encoded() { UserDefaults.standard.set(data, forKey: LaunchDefaults.preferencesKey) } }
    }

    var launchPrompts: LaunchPromptMemory {
        get { LaunchPromptMemory.decode(UserDefaults.standard.data(forKey: LaunchPromptMemory.preferencesKey)) ?? LaunchPromptMemory() }
        set { if let data = newValue.encoded() { UserDefaults.standard.set(data, forKey: LaunchPromptMemory.preferencesKey) } }
    }

    // MARK: Launching

    /// Starts the chat in the background (the owner pressed Start), on this Mac or on the machine
    /// `machine`; on this Mac with `newWorktree`, in a worktree made for it first. Returns at once.
    func launch(_ request: LaunchRequest, follow: Bool, machine: UUID? = nil, newWorktree: Bool = false) {
        guard !request.trimmedPrompt.isEmpty, !request.folder.isEmpty else { return }
        var prompts = launchPrompts
        prompts.recordStart(request.prompt, folder: request.folder, machine: machine)
        launchPrompts = prompts
        if let machine {
            guard let host = remoteHosts.first(where: { $0.id == machine }) else { return }
            launchRemote(request, follow: follow, host: host)
            return
        }
        // Remembered under the project, not the worktree made for it.
        var memory = launchDefaults
        memory.record(request)
        launchDefaults = memory
        let branch = newWorktree ? NewWorktree.branchName(prompt: request.prompt, provider: request.provider) : nil
        let pending = pendingLaunches.begin(request, follow: follow, now: Date(), worktreeBranch: branch)
        if follow {
            search = ""
            page = .remote
            remoteSelection = pending.rowID
        }
        let id = pending.id
        Task { @MainActor in
            var request = request
            if newWorktree {
                guard pendingLaunches.launch(id) != nil else { return } // dismissed: nothing made, nothing started
                let asked = request
                let made = await Task.detached(priority: .userInitiated) { () -> Result<CreatedWorktree, Error> in
                    Result { try NewWorktree.create(in: asked.folder, prompt: asked.prompt, provider: asked.provider) }
                }.value
                switch made {
                case .success(let tree):
                    guard pendingLaunches.launch(id) != nil else {
                        // Dismissed while the worktree was being made: undo it, start nothing. What
                        // the undo couldn't remove comes back as a failed row naming it.
                        let leftovers = await Task.detached(priority: .utility) { NewWorktree.discard(tree) }.value
                        pendingLaunches.leftBehind(pending, leftovers: leftovers)
                        return
                    }
                    request.folder = tree.folder
                    pendingLaunches.worktreeCreated(id, folder: tree.folder, branch: tree.branch)
                case .failure(let error):
                    let reason = (error as? LocalizedError)?.errorDescription ?? "Git couldn't create the worktree."
                    pendingLaunches.fail(id, message: "No worktree made: " + reason + " The chat wasn't started.")
                    return
                }
            }
            guard pendingLaunches.launch(id) != nil else { return } // dismissed before the provider was called
            let outcome = await Task.detached(priority: .userInitiated) { [request] () -> Result<LaunchResult, Error> in
                Result { request.provider == .codex ? try CodexLaunch.start(request) : try ClaudeLaunch.start(request) }
            }.value
            switch outcome {
            case .success(let result):
                pendingLaunches.succeed(id, with: result)
                await followLaunch(id)
            case .failure(let error):
                pendingLaunches.fail(id, message: (error as? LocalizedError)?.errorDescription ?? "The chat didn't start.")
            }
        }
    }

    /// Refreshes the feed on a widening schedule until the started session appears (about 45 s in all).
    private func followLaunch(_ id: UUID) async {
        for delay in [0.0, 1, 2, 3, 4, 5, 6, 8, 8, 8] {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard pendingLaunches.launch(id) != nil else { return }
            await refreshAgents()
            reconcileLaunches()
        }
    }

    private func launchRemote(_ request: LaunchRequest, follow: Bool, host: RemoteHost) {
        var memory = launchDefaults
        memory.record(request, machine: host.id)
        launchDefaults = memory
        let pending = pendingLaunches.begin(request, follow: follow, now: Date(), machine: host.id, machineName: host.name)
        if follow {
            search = ""
            page = .remote
            remoteSelection = pending.rowID
        }
        let id = pending.id
        Task { @MainActor in
            guard pendingLaunches.launch(id) != nil else { return } // dismissed before the machine was asked
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<RemoteLaunchResult, Error> in
                Result { request.provider == .codex ? try RemoteLaunch.startCodex(request, host: host) : try RemoteLaunch.startClaude(request, host: host) }
            }.value
            switch outcome {
            case .success(let result):
                pendingLaunches.succeed(id, with: result.launch, now: Date())
                reconcileLaunches()
                await followRemoteLaunch(id)
            case .failure(let error):
                let lastSeen = remoteSnapshots[host.id]?.sampledAt
                pendingLaunches.fail(id, message: RemoteLaunchFailure.message(error, machine: host.name, lastSeen: lastSeen, now: Date()))
            }
        }
    }

    /// Asks the chat's machine to be checked now (through the regular poll schedule), then keeps the
    /// placeholder in place until a check lists the chat or it expires.
    private func followRemoteLaunch(_ id: UUID) async {
        let machine = pendingLaunches.launch(id)?.machine
        func probe() async { if let machine { await requestRemoteProbe(machine) } else { await refreshRemotes() } }
        await probe()
        reconcileLaunches()
        for delay in [3.0, 5, 10, 10, 15, 20, 20, 20, 20] {
            try? await Task.sleep(for: .seconds(delay))
            guard pendingLaunches.launch(id) != nil else { return }
            if delay == 10 { await probe() }
            reconcileLaunches()
        }
        reconcileLaunches()
    }

    /// Swaps every started pending row whose session is now in the feed for the real chat. Remote
    /// chats first get their placeholder in their machine's list (re-added after a check that doesn't
    /// list them yet) and are settled once a check made after the start lists them.
    func reconcileLaunches() {
        guard pendingLaunches.awaitingFeed else { return }
        let now = Date()
        pendingLaunches.settle(samples: remoteSnapshots.mapValues { ($0.sampledAt, $0.checkedSessionIDs) }, now: now)
        var added = false
        for (hostID, session) in pendingLaunches.placeholders(now: now) {
            guard let host = remoteHosts.first(where: { $0.id == hostID }), host.enabled else { continue }
            let current = remoteSnapshots[hostID] ?? RemoteHostSnapshot(host: host)
            let next = current.addingPlaceholder(session)
            if next.sessions.count != current.sessions.count { remoteSnapshots[hostID] = next; added = true }
        }
        if added { rebuildAgentActivity() }
        for match in pendingLaunches.reconcile(feedIDs: notchChatSessions.map(\.id)) where remoteSelection == match.rowID {
            remoteSelection = match.sessionID
        }
    }

    /// Retry: the sheet again, prefilled with the failed request on the same machine (and the new
    /// worktree switch on when the worktree was never made). The failed row goes away.
    func retryLaunch(_ launch: PendingLaunch) {
        dismissLaunch(launch)
        openNewChat(LaunchDraft(retrying: launch.request, machine: launch.machine, newWorktree: launch.retryInNewWorktree))
    }
    func dismissLaunch(_ launch: PendingLaunch) {
        if remoteSelection == launch.rowID { remoteSelection = nil }
        pendingLaunches.remove(launch.id)
    }
    /// For a chat on this Mac that started but hasn't shown up: its provider's own view of it.
    func openStartedLaunch(_ launch: PendingLaunch) {
        guard !launch.isRemote, case .started(let result) = launch.phase else { return }
        open(result)
    }
}
