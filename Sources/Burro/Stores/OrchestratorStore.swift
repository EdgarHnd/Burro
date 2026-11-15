// The orchestrator chat: Claude Code run headless (Fable 5.2 unless you pick another model), one
// `claude -p` process per turn, one conversation per local day (the day's first question starts a
// fresh session, later ones resume it; earlier days stay listed and can be read back). Each turn
// gets the brief and its memory (global, then the main project's) as an appended system prompt.
// History is the shown conversation's own transcript, read back through the Rust worker after each
// turn; the turn in progress streams live. Replies and chats it proposes are kept as pending
// actions until you send or discard each one; to-dos it adds or completes are applied at once
// through the app's to-do store and can be undone. Every turn's cost goes to the runs log.
import Foundation
import Observation
import BurroCore

@MainActor @Observable final class OrchestratorStore {
    private(set) var history: [ChatMessage] = []
    private(set) var live: [ChatMessage] = []
    private(set) var streaming = ""
    private(set) var running = false
    private(set) var error: String?
    private(set) var loadedHistory = false
    /// One conversation per local day, newest last.
    private(set) var sessions: [OrchestratorDaySession] {
        didSet { defaults.set(OrchestratorSessions.encode(sessions), forKey: "orchestrator.sessions") }
    }
    /// An earlier conversation being read back, or nil for today's.
    private(set) var viewing: OrchestratorDaySession?
    /// "New conversation" was pressed: the next question starts a fresh session today.
    private(set) var startFresh = false
    /// Its memory, as last read (the Memory tab).
    private(set) var memory: [OrchestratorMemoryEntry] = []
    /// Runs logged today and the latest runs (the Runs tab).
    private(set) var runsToday: [OrchestratorRun] = []
    private(set) var recentRuns: [OrchestratorRun] = []
    /// Lets it read your notes through `read_notes` (off unless you turn it on).
    var notesAccess: Bool { didSet { defaults.set(notesAccess, forKey: "orchestrator.notesAccess") } }
    /// How hard the orchestrator thinks; applies from the next message.
    var effort: String { didSet { defaults.set(effort, forKey: "orchestrator.effort") } }
    /// Which Claude model runs it; applies from the next message.
    var model: String { didSet { defaults.set(model, forKey: "orchestrator.chosenModel") } }
    /// Replies and chats it proposed, newest last; nothing here has been sent unless marked sent.
    private(set) var actions: [OrchestratorAction] = []
    /// Proposals being sent right now.
    private(set) var sendingActions: Set<String> = []
    var draft = ""

    /// Burro's current picture, written for the tool server before and during each turn.
    @ObservationIgnored var snapshot: () -> OrchestratorState? = { nil }
    @ObservationIgnored var profiles: () -> [UsageProvider: String] = { [:] }
    /// Applies a to-do change it asked for (returns why not, or nil), and reverses one on Undo.
    @ObservationIgnored var applyLocal: (OrchestratorAction) -> String? = { _ in "Burro isn't ready to change to-dos." }
    @ObservationIgnored var undoLocal: (OrchestratorAction) -> String? = { _ in "Burro isn't ready to change to-dos." }
    @ObservationIgnored let memoryStore: OrchestratorMemory
    @ObservationIgnored let runsLog: OrchestratorRuns
    @ObservationIgnored private var turn: OrchestratorTurn?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, actionStore: OrchestratorActionStore = .standard, memoryStore: OrchestratorMemory = .standard,
         runsLog: OrchestratorRuns = .standard) {
        self.defaults = defaults
        self.actionStore = actionStore
        self.memoryStore = memoryStore
        self.runsLog = runsLog
        sessions = OrchestratorSessions.migrate(legacy: defaults.string(forKey: "orchestrator.session"),
                                                into: OrchestratorSessions.decode(defaults.data(forKey: "orchestrator.sessions")))
        defaults.removeObject(forKey: "orchestrator.session")
        notesAccess = defaults.object(forKey: "orchestrator.notesAccess") as? Bool ?? false
        // A new orchestrator model starts at its own default effort; a pick made since stays.
        if defaults.string(forKey: "orchestrator.model") != Orchestrator.model {
            defaults.removeObject(forKey: "orchestrator.effort")
            defaults.set(Orchestrator.model, forKey: "orchestrator.model")
        }
        let saved = defaults.string(forKey: "orchestrator.effort") ?? Orchestrator.defaultEffort
        effort = Orchestrator.efforts.contains(saved) ? saved : Orchestrator.defaultEffort
        let picked = defaults.string(forKey: "orchestrator.chosenModel") ?? Orchestrator.model
        model = Orchestrator.models.contains { $0.id == picked } ? picked : Orchestrator.model
        actions = actionStore.load()
    }

    @ObservationIgnored let actionStore: OrchestratorActionStore

    static func today(_ now: Date = Date()) -> String { TodoDay.key(now) }
    /// The conversation on screen: one being read back, else today's (nil before today's first question).
    var sessionID: String? {
        if let viewing { return viewing.sessionID }
        return startFresh ? nil : OrchestratorSessions.current(sessions, day: Self.today())?.sessionID
    }
    /// Earlier conversations, newest first.
    var earlierSessions: [OrchestratorDaySession] { OrchestratorSessions.earlier(sessions, today: Self.today()) }
    /// Today's runs and what they cost.
    var todayCost: Double { runsToday.reduce(0) { $0 + $1.costUSD } }

    var setupProblem: String? {
        if ClaudeLaunch.executable() == nil { return "Install Claude Code on this Mac to use the orchestrator." }
        if Self.toolServer == nil { return "This build of Burro is missing its orchestrator tools (burro-mcp)." }
        return nil
    }

    /// History, then this turn, then the reply being written; ids are positions.
    var messages: [ChatMessage] {
        // Claude Code's own step for loading deferred tools is noise here.
        var all = (history + live).filter { !($0.kind == .tool && $0.tool == "ToolSearch") }
        if !streaming.isEmpty { all.append(ChatMessage(id: 0, kind: .assistant, text: streaming)) }
        return all.enumerated().map { index, message in var copy = message; copy.id = index; return copy }
    }
    /// Chats started from its proposals.
    var startedChatIDs: [String] { actions.compactMap(\.startedChatID) }
    /// Proposals still waiting for Send or Discard (not expired).
    var waitingActions: [OrchestratorAction] { actions.filter { $0.isWaiting() } }
    /// Conversation shown before the day changed, so a new day starts empty.
    @ObservationIgnored private var loadedDay = OrchestratorStore.today()
    var lastReply: String? { (streaming.isEmpty ? nil : streaming) ?? messages.last { $0.kind == .assistant }?.text }
    var lastQuestion: String? { messages.last { $0.kind == .user }?.text }
    /// What the orchestrator is doing right now, for the Home card.
    var activity: String? {
        guard running else { return nil }
        if !streaming.isEmpty { return "Writing…" }
        if let tool = live.last(where: { $0.kind == .tool }), tool.output == nil { return Self.describe(tool) }
        return "Thinking…"
    }

    func loadHistory() async {
        if loadedDay != Self.today(), viewing == nil, !running {
            // A new day: yesterday's conversation moves to the earlier list.
            loadedDay = Self.today(); history = []; live = []; loadedHistory = false
        }
        guard !loadedHistory, !running else { return }
        loadedHistory = true
        await reloadHistory()
    }

    /// Reads back an earlier day's conversation; nil returns to today's.
    func show(_ session: OrchestratorDaySession?) async {
        guard !running else { return }
        viewing = session
        history = []; live = []; streaming = ""; error = nil
        loadedHistory = true
        await reloadHistory()
    }

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !running else { return }
        guard let executable = ClaudeLaunch.executable() else { error = "Install Claude Code to use the orchestrator."; return }
        guard let server = Self.toolServer else { error = "This build of Burro is missing its orchestrator tools (burro-mcp)."; return }
        draft = ""
        error = nil
        if viewing != nil { viewing = nil; history = [] }
        loadedDay = Self.today()
        live = [ChatMessage(id: 0, kind: .user, text: prompt, at: Date())]
        streaming = ""
        running = true
        task = Task { await run(prompt, executable: executable, server: server, retry: true) }
    }

    func stop() { turn?.cancel() }

    #if DEBUG
    /// Render harnesses and tests only.
    func preview(history: [ChatMessage], live: [ChatMessage] = [], streaming: String = "", running: Bool = false) {
        self.history = history; self.live = live; self.streaming = streaming; self.running = running; loadedHistory = true
    }
    #endif

    /// Starts a fresh conversation for the rest of today; the old one stays listed under today.
    func newConversation() {
        guard !running else { return }
        startFresh = true
        viewing = nil
        history = []; live = []; streaming = ""; error = nil
    }

    private func run(_ promptText: String, executable: String, server: URL, retry: Bool) async {
        let day = Self.today()
        let chosen = OrchestratorSessions.session(for: day, in: sessions, fresh: startFresh)
        let resume = chosen.resume, id = chosen.sessionID
        let started = Date()
        var usage: OrchestratorRun?
        do {
            let config = try Orchestrator.prepare(toolServer: server)
            writeSnapshot()
            let entries = memoryStore.load()
            let mainProject = snapshot()?.mainProject
            let prompt = Orchestrator.systemPrompt(memory: entries, mainProject: mainProject, now: started)
            let used = OrchestratorMemory.relevant(entries, mainProject: mainProject).map(\.id)
            let memoryStore = memoryStore
            Task.detached(priority: .utility) { try? memoryStore.touch(used) }
            let turn = try OrchestratorTurn(executable: executable,
                                            arguments: Orchestrator.arguments(sessionID: id, resume: resume, mcpConfig: config, effort: effort,
                                                                              model: model, systemPrompt: prompt),
                                            prompt: promptText)
            self.turn = turn
            sessions = chosen.sessions
            startFresh = false
            // Keep the snapshot fresh during long turns.
            let refresher = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    self?.writeSnapshot()
                }
            }
            defer { refresher.cancel() }
            var failure: String?
            for await event in turn.events {
                switch event {
                case .started(let reported):
                    if reported != id { sessions = OrchestratorSessions.rename(id, to: reported, in: sessions) }
                case .run(let run): usage = run
                case .textDelta(let delta): streaming += delta
                case .text(let text):
                    streaming = ""
                    append(ChatMessage(id: 0, kind: .assistant, text: text, at: Date()))
                case .tool(_, let name, let summary):
                    append(ChatMessage(id: 0, kind: .tool, text: summary, tool: name, at: Date()))
                case .toolResult(_, let output):
                    if let index = live.lastIndex(where: { $0.kind == .tool && $0.output == nil }) { live[index].output = output }
                    if output.hasPrefix("Proposal ") { reloadActions() }
                    if output.hasPrefix("To-do action ") { applyLocalActions() }
                    if output.hasPrefix("Remembered ") || output.hasPrefix("Forgot: ") { reloadMemory() }
                case .finished(let isError, let message, _):
                    if isError { failure = message ?? "The orchestrator stopped." }
                }
            }
            // Let Claude finish writing the transcript before reading it back.
            await Task.detached { turn.waitUntilExit() }.value
            self.turn = nil
            logRun(usage, started: started)
            if let failure, resume, retry, failure.localizedCaseInsensitiveContains("no conversation found") || turn.errorOutput.localizedCaseInsensitiveContains("no conversation found") {
                // The saved conversation is gone (deleted or a different Claude profile): start over.
                sessions = OrchestratorSessions.drop(id, from: sessions); history = []
                await run(promptText, executable: executable, server: server, retry: false)
                return
            }
            await reloadHistory()
            reloadActions()
            applyLocalActions()
            if let failure { error = failure.trimmingCharacters(in: .whitespacesAndNewlines) }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        finishTurn()
    }

    private func append(_ message: ChatMessage) { live.append(message) }

    private func logRun(_ usage: OrchestratorRun?, started: Date) {
        var run = usage ?? OrchestratorRun(at: started, trigger: "ask", model: model)
        run.at = started; run.trigger = "ask"; run.model = Orchestrator.validModel(model)
        if run.durationMs == 0 { run.durationMs = Int(Date().timeIntervalSince(started) * 1000) }
        let log = runsLog, entry = run
        Task.detached(priority: .utility) { try? log.append(entry) }
        runsToday.append(entry)
        recentRuns.insert(entry, at: 0)
    }

    // MARK: Memory and runs

    func reloadMemory() { memory = memoryStore.load() }
    func reloadRuns() {
        let log = runsLog
        Task { [weak self] in
            let (today, recent) = await Task.detached(priority: .utility) { (log.today(), log.recent(40)) }.value
            self?.runsToday = today; self?.recentRuns = recent
        }
    }
    func addMemory(_ text: String, scope: String = OrchestratorMemoryEntry.global) {
        _ = try? memoryStore.remember(text, scope: scope, source: .user)
        reloadMemory()
    }
    func editMemory(_ id: String, text: String) {
        _ = try? memoryStore.edit(id, text: text)
        reloadMemory()
    }
    func deleteMemory(_ id: String) {
        _ = try? memoryStore.forget(id)
        reloadMemory()
    }

    // MARK: Local actions (to-dos)

    /// Applies the to-do changes it asked for, once each.
    func applyLocalActions() {
        let claimed = (try? actionStore.claimLocal()) ?? []
        for action in claimed {
            if let problem = applyLocal(action) { try? actionStore.failLocal(action.id, error: problem) }
        }
        reloadActions()
    }

    func undo(_ action: OrchestratorAction) {
        if let before = try? actionStore.undoLocal(action.id), let problem = undoLocal(before) {
            try? actionStore.failLocal(action.id, error: problem)
        }
        reloadActions()
    }

    // MARK: Proposed actions

    func reloadActions() { actions = actionStore.load() }

    func discard(_ action: OrchestratorAction) {
        try? actionStore.discard(action.id)
        reloadActions()
    }

    /// Marks a proposal as going out; false when it's already sending, sent, expired or gone.
    func beginSending(_ id: String) -> Bool {
        reloadActions()
        guard let action = actions.first(where: { $0.id == id }), action.isWaiting(), !sendingActions.contains(id) else { return false }
        sendingActions.insert(id)
        return true
    }

    /// Records what Send did: the text that went, and the confirmation or the error.
    func finishSending(_ id: String, text: String, outcome: Result<(message: String, chatID: String?), Error>) {
        sendingActions.remove(id)
        _ = try? actionStore.modify(id) { action in
            action.text = text
            switch outcome {
            case .success(let sent):
                action.status = .sent; action.result = sent.message; action.error = nil; action.sentAt = Date()
                action.startedChatID = sent.chatID
            case .failure(let failure):
                action.error = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
            }
        }
        reloadActions()
    }

    private func finishTurn() {
        running = false
        turn = nil
        task = nil
    }

    /// Swaps in the transcript from disk once it covers this turn; otherwise keeps the live copy.
    private func reloadHistory() async {
        guard let sessionID else { return }
        let profiles = profiles()
        let loaded = await Task.detached(priority: .userInitiated) {
            try? ChatTranscripts.load(chatID: "claude:" + sessionID, hosts: [], profiles: profiles, limit: 300)
        }.value
        guard let loaded else { return }
        let liveUser = live.first { $0.kind == .user }.map { String($0.text.prefix(200)) }
        if liveUser == nil || loaded.messages.contains(where: { $0.kind == .user && $0.text.hasPrefix(liveUser!) }) {
            history = loaded.messages
            live = []
            streaming = ""
        }
    }

    private func writeSnapshot() {
        guard let state = snapshot() else { return }
        Task.detached(priority: .utility) { try? Orchestrator.write(state) }
    }

    static func describe(_ tool: ChatMessage) -> String {
        switch tool.tool {
        case "ToolSearch": "Getting Burro's tools…"
        case "overview": "Looking at everything…"
        case "list_chats": "Listing chats…"
        case "read_chat": "Reading a chat…"
        case "list_worktrees": "Checking worktrees…"
        case "start_chat": "Proposing a chat…"
        case "reply_chat": "Drafting a reply…"
        case "brief": "Reading the brief…"
        case "chat_digest": "Checking a chat…"
        case "read_shipped": "Checking what shipped…"
        case "usage": "Checking usage…"
        case "read_notes": "Reading notes…"
        case "add_todo", "complete_todo": "Updating to-dos…"
        case "remember", "forget": "Updating its memory…"
        case "Read", "read_file": "Reading a file…"
        case "Grep", "Glob", "search_files": "Searching files…"
        default: "Working…"
        }
    }

    /// The signed `burro-mcp` next to Burro's executable (or the SwiftPM build in development).
    static var toolServer: URL? {
        guard let main = Bundle.main.executableURL else { return nil }
        let sibling = main.deletingLastPathComponent().appendingPathComponent("burro-mcp")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }
}
