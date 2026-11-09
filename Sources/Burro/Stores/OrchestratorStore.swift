// The orchestrator chat: one Claude Code (Opus 5.5) conversation Burro runs headless, one
// `claude -p` process per turn, resumed by session id. History is the chat's own transcript,
// read back through the Rust worker after each turn; the turn in progress streams live.
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
    private(set) var sessionID: String? { didSet { defaults.set(sessionID, forKey: "orchestrator.session") } }
    /// How hard the orchestrator thinks; applies from the next message.
    var effort: String { didSet { defaults.set(effort, forKey: "orchestrator.effort") } }
    var draft = ""

    /// Burro's current picture, written for the tool server before and during each turn.
    @ObservationIgnored var snapshot: () -> OrchestratorState? = { nil }
    @ObservationIgnored var profiles: () -> [UsageProvider: String] = { [:] }
    @ObservationIgnored private var turn: OrchestratorTurn?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sessionID = defaults.string(forKey: "orchestrator.session")
        let saved = defaults.string(forKey: "orchestrator.effort") ?? Orchestrator.defaultEffort
        effort = Orchestrator.efforts.contains(saved) ? saved : Orchestrator.defaultEffort
    }

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
    /// Chats it started this conversation, from its start_chat results.
    var startedChatIDs: [String] {
        messages.filter { $0.kind == .tool && $0.tool == "start_chat" }.compactMap { message in
            message.output?.firstMatch(of: /(?:claude|codex):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/).map { String($0.0) }
        }
    }
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
        guard !loadedHistory, !running else { return }
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

    /// Starts a fresh conversation; the old one stays on disk as an ordinary Claude transcript.
    func newConversation() {
        guard !running else { return }
        sessionID = nil
        history = []; live = []; streaming = ""; error = nil
    }

    private func run(_ prompt: String, executable: String, server: URL, retry: Bool) async {
        let resume = sessionID != nil
        let id = sessionID ?? UUID().uuidString.lowercased()
        do {
            let config = try Orchestrator.prepare(toolServer: server)
            writeSnapshot()
            let turn = try OrchestratorTurn(executable: executable, arguments: Orchestrator.arguments(sessionID: id, resume: resume, mcpConfig: config, effort: effort), prompt: prompt)
            self.turn = turn
            if !resume { sessionID = id }
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
                case .started(let started): if sessionID != started { sessionID = started }
                case .textDelta(let delta): streaming += delta
                case .text(let text):
                    streaming = ""
                    append(ChatMessage(id: 0, kind: .assistant, text: text, at: Date()))
                case .tool(_, let name, let summary):
                    append(ChatMessage(id: 0, kind: .tool, text: summary, tool: name, at: Date()))
                case .toolResult(_, let output):
                    if let index = live.lastIndex(where: { $0.kind == .tool && $0.output == nil }) { live[index].output = output }
                case .finished(let isError, let message, _):
                    if isError { failure = message ?? "The orchestrator stopped." }
                }
            }
            // Let Claude finish writing the transcript before reading it back.
            await Task.detached { turn.waitUntilExit() }.value
            self.turn = nil
            if let failure, resume, retry, failure.localizedCaseInsensitiveContains("no conversation found") || turn.errorOutput.localizedCaseInsensitiveContains("no conversation found") {
                // The saved conversation is gone (deleted or a different Claude profile): start over.
                sessionID = nil; history = []
                await run(prompt, executable: executable, server: server, retry: false)
                return
            }
            await reloadHistory()
            if let failure { error = failure.trimmingCharacters(in: .whitespacesAndNewlines) }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        finishTurn()
    }

    private func append(_ message: ChatMessage) { live.append(message) }

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
        case "start_chat": "Starting a chat…"
        case "Read": "Reading a file…"
        case "Grep", "Glob": "Searching files…"
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
