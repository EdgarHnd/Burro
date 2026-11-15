// Burro's tools for the orchestrator, served over MCP (stdio, newline-delimited JSON-RPC) by
// `burro-mcp`. Everything reads Burro's latest snapshot, except `read_chat` (reads one
// transcript on demand, this Mac or over SSH). `reply_chat` and `start_chat` never send or
// launch anything: they record a proposal in the actions file next to the snapshot, which the
// user sends (or discards) from Burro.
import Foundation

public struct OrchestratorTools {
    public var stateURL: URL
    public var now: () -> Date = Date.init
    /// Swapped in tests.
    var readChat: (String, [RemoteHost], [UsageProvider: String], Int) throws -> ChatTranscript = { id, hosts, profiles, limit in
        try ChatTranscripts.load(chatID: id, hosts: hosts, profiles: profiles, limit: limit)
    }
    /// Where proposals go: `actions.json` beside the snapshot.
    public var actions: OrchestratorActionStore
    /// The orchestrator conversation, recorded on each proposal.
    public var conversation: String?

    public init(stateURL: URL, conversation: String? = nil) {
        self.stateURL = stateURL
        self.conversation = conversation
        actions = OrchestratorActionStore(url: stateURL.deletingLastPathComponent().appendingPathComponent("actions.json"))
    }

    // MARK: JSON-RPC

    /// Handles one message; returns the reply, or nil for notifications.
    public func handle(_ message: [String: Any]) -> [String: Any]? {
        let method = message["method"] as? String ?? ""
        guard let id = message["id"] else { return nil }
        func reply(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        switch method {
        case "initialize":
            let params = message["params"] as? [String: Any]
            return reply(["protocolVersion": params?["protocolVersion"] as? String ?? "2025-06-18",
                          "capabilities": ["tools": [String: Any]()],
                          "serverInfo": ["name": "burro", "version": "1"]])
        case "ping":
            return reply([:])
        case "tools/list":
            return reply(["tools": Self.definitions])
        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            let (text, isError) = call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
            return reply(["content": [["type": "text", "text": text]], "isError": isError])
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unknown method \(method)"]]
        }
    }

    public func call(_ name: String, _ arguments: [String: Any]) -> (String, Bool) {
        if name == "start_chat" { return startChat(arguments) }
        if name == "reply_chat" { return replyChat(arguments) }
        guard let state = Orchestrator.readState(from: stateURL) else {
            return ("Burro hasn't shared a snapshot yet. Open Burro and try again.", true)
        }
        switch name {
        case "overview": return (overview(state), false)
        case "list_chats": return (listChats(state, arguments), false)
        case "read_chat": return readChat(state, arguments)
        case "list_worktrees": return (listWorktrees(state, arguments), false)
        default: return ("Unknown tool \(name).", true)
        }
    }

    static var definitions: [[String: Any]] { [
        tool("overview", "Everything Burro sees right now: machines and their agent versions, the main project, every project, chats that need the user, are working or are ready to read (with subagents), and today's to-dos.", [:]),
        tool("list_chats", "List chats across all machines, newest first, with ids for read_chat.", [
            "status": ["type": "string", "enum": ["needs_you", "working", "unread", "recent", "all"], "description": "Default all."],
            "machine": ["type": "string", "description": "Machine name, e.g. \"This Mac\"."],
            "project": ["type": "string", "description": "Project name or path."],
            "query": ["type": "string", "description": "Text to match in titles and folders."],
            "include_subagents": ["type": "boolean"],
            "limit": ["type": "integer", "minimum": 1, "maximum": 200],
        ]),
        tool("read_chat", "Read a chat's latest messages (user, assistant and tool calls) on any machine.", [
            "id": ["type": "string", "description": "A chat id from overview or list_chats."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 300, "description": "Messages to show, default 60."],
        ], required: ["id"]),
        tool("list_worktrees", "A project's git worktrees: branch, uncommitted and unpushed work, activity, and whether Burro considers it safe to clean.", [
            "project": ["type": "string", "description": "Project name or path. Default: the main project."],
        ]),
        tool("reply_chat", "Propose a reply to a chat on any machine, usually one that needs the user. This does not send it: the user reviews, edits and sends it (or discards it) in Burro.", [
            "id": ["type": "string", "description": "A chat id from overview or list_chats."],
            "message": ["type": "string", "description": "The reply, written as the user would send it."],
        ], required: ["id", "message"]),
        tool("start_chat", "Propose a new chat on this Mac in a project folder. This does not start it: the user reviews, edits and sends it (or discards it) in Burro.", [
            "agent": ["type": "string", "enum": ["claude", "codex"]],
            "folder": ["type": "string", "description": "Project name or absolute folder path."],
            "prompt": ["type": "string", "description": "A self-contained task: goal, context, what done looks like."],
            "model": ["type": "string", "description": "Optional model id."],
            "effort": ["type": "string", "enum": ["low", "medium", "high", "xhigh", "max"], "description": "Optional reasoning effort."],
            "access": ["type": "string", "enum": ["ask", "edit", "readOnly"], "description": "Default ask: the agent asks before acting."],
        ], required: ["agent", "folder", "prompt"]),
    ] }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }

    // MARK: Tools

    func overview(_ state: OrchestratorState) -> String {
        var lines = [header(state)]
        if let main = state.mainProject, let project = state.projects.first(where: { $0.path == main }) {
            lines.append("Main project: \(project.name) (\(project.path))")
        }
        lines.append("\n## Machines")
        for machine in state.machines {
            let chats = state.chats.filter { machineName($0) == machine.name && $0.isSubagent != true }
            var parts = [machine.connection]
            if let seen = machine.lastSeen, machine.connection != "online", machine.connection != "this Mac" { parts.append("seen \(ago(seen))") }
            let running = chats.filter { $0.state == .working }.count, waiting = chats.filter(needsYou).count
            if running > 0 { parts.append("\(running) running") }
            if waiting > 0 { parts.append("\(waiting) need you") }
            let versions = machine.versions.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
            if !versions.isEmpty { parts.append(versions.joined(separator: ", ")) }
            lines.append("- \(machine.name): " + parts.joined(separator: " · "))
        }
        let chats = sorted(state.chats.filter { $0.isSubagent != true })
        for (title, group) in [("Needs you", chats.filter(needsYou)), ("Working", chats.filter { $0.state == .working || $0.state == .scheduled }),
                               ("Ready to read", chats.filter(\.isDone))] where !group.isEmpty {
            lines.append("\n## \(title) (\(group.count))")
            lines += group.prefix(25).map { row($0, state) }
        }
        let recent = chats.filter { !needsYou($0) && $0.state != .working && $0.state != .scheduled && !$0.isDone }
            .filter { now().timeIntervalSince($0.updatedAt) < 86_400 }
        if !recent.isEmpty {
            lines.append("\n## Other chats in the last 24 hours (\(recent.count))")
            lines += recent.prefix(15).map { row($0, state) }
        }
        lines.append("\n## Projects")
        for project in state.projects.sorted(by: { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }).prefix(20) {
            var parts: [String] = []
            if project.isRepository { parts.append("\(project.worktrees) worktrees" + (project.readyToRemove > 0 ? " (\(project.readyToRemove) safe to clean)" : "")) }
            if project.tokensToday > 0 { parts.append(tokens(project.tokensToday) + " tokens today") }
            if let active = project.lastActive { parts.append("active \(ago(active))") }
            lines.append("- \(project.name) — \(project.path)" + (parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")))
        }
        let today = state.todos
        lines.append("\n## To-dos (\(today.filter { !$0.done }.count) open)")
        if today.isEmpty { lines.append("- none") }
        lines += today.map { "- [\($0.done ? "x" : " ")] \($0.text)" + ($0.project.map { " (\($0))" } ?? "") }
        return lines.joined(separator: "\n")
    }

    func listChats(_ state: OrchestratorState, _ arguments: [String: Any]) -> String {
        let status = arguments["status"] as? String ?? "all"
        let machine = (arguments["machine"] as? String)?.lowercased()
        let project = (arguments["project"] as? String).flatMap { resolveProject($0, state) }
        let query = arguments["query"] as? String
        let subagents = arguments["include_subagents"] as? Bool ?? false
        let limit = max(1, min(200, arguments["limit"] as? Int ?? 40))
        let chats = sorted(state.chats).filter { chat in
            if chat.isSubagent == true && !subagents { return false }
            switch status {
            case "needs_you": if !needsYou(chat) { return false }
            case "working": if chat.state != .working && chat.state != .scheduled { return false }
            case "unread": if !chat.isDone { return false }
            case "recent": if now().timeIntervalSince(chat.updatedAt) > 86_400 { return false }
            default: break
            }
            if let machine, machineName(chat).lowercased() != machine { return false }
            if let project, !inProject(chat, project, state) { return false }
            if let query, !query.isEmpty, ![chat.title, chat.cwd].contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return false }
            return true
        }
        guard !chats.isEmpty else { return header(state) + "\nNo chats match." }
        return ([header(state), "\(chats.count) chats" + (chats.count > limit ? ", showing \(limit)" : "")] + chats.prefix(limit).map { row($0, state) })
            .joined(separator: "\n")
    }

    func readChat(_ state: OrchestratorState, _ arguments: [String: Any]) -> (String, Bool) {
        guard let raw = (arguments["id"] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return ("Pass a chat id.", true) }
        let limit = max(1, min(300, arguments["limit"] as? Int ?? 60))
        let chat = state.chats.first { $0.id == raw } ?? state.chats.first { $0.id.hasSuffix(":" + raw.lowercased()) }
        let id = chat?.id ?? raw
        do {
            let transcript = try readChat(id, state.hosts, state.usageProfiles, limit)
            var lines: [String] = []
            let title = transcript.title ?? chat?.title ?? "Chat"
            lines.append("# \(title)")
            if let chat { lines.append("\(agent(chat)) on \(machineName(chat)), \(folderName(chat)) · \(stateText(chat)) · updated \(ago(chat.updatedAt))") }
            if transcript.truncated { lines.append("(Older messages not shown; this is the latest \(transcript.messages.count).)") }
            for message in transcript.messages {
                let time = message.at.map { " " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
                switch message.kind {
                case .user: lines.append("\n[user\(time)]\n" + OrchestratorEvent.clip(message.text, 6000))
                case .assistant: lines.append("\n[assistant\(time)]\n" + OrchestratorEvent.clip(message.text, 6000))
                case .tool:
                    let output = message.output.map { $0.isEmpty ? "" : " → " + OrchestratorEvent.clip($0.replacingOccurrences(of: "\n", with: " "), 240) } ?? ""
                    lines.append("[tool \(message.tool ?? "tool")] \(message.text)\(output)")
                }
            }
            if transcript.messages.isEmpty { lines.append("No messages yet.") }
            return (lines.joined(separator: "\n"), false)
        } catch {
            return ((error as? LocalizedError)?.errorDescription ?? "Couldn't read that chat.", true)
        }
    }

    func listWorktrees(_ state: OrchestratorState, _ arguments: [String: Any]) -> String {
        let path = (arguments["project"] as? String).flatMap { resolveProject($0, state) } ?? state.mainProject
        guard let path else { return "Name a project." }
        let trees = state.worktrees.filter { $0.repositoryPath == path }
        guard !trees.isEmpty else { return "No worktrees found for \(path)." }
        var lines = [header(state), "\(trees.count) worktrees of \(trees[0].repository)"]
        for tree in trees.sorted(by: { ($0.lastCommit ?? .distantPast) > ($1.lastCommit ?? .distantPast) }) {
            var parts = [tree.branch.isEmpty ? "detached" : tree.branch, tree.activity]
            if tree.isPrimary { parts.append("primary") }
            if tree.changed + tree.untracked > 0 { parts.append("\(tree.changed) changed, \(tree.untracked) untracked") }
            if let unpushed = tree.unpushed, unpushed > 0 { parts.append("\(unpushed) unpushed") }
            if let commit = tree.lastCommit { parts.append("last commit \(ago(commit))") }
            if tree.readyToRemove { parts.append("safe to clean") }
            lines.append("- \(tree.path): " + parts.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }

    func startChat(_ arguments: [String: Any]) -> (String, Bool) {
        guard let agent = (arguments["agent"] as? String).flatMap(LaunchProvider.init(rawValue:)) else { return ("agent must be claude or codex.", true) }
        let prompt = (arguments["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return ("Write a prompt for the chat.", true) }
        let requested = (arguments["folder"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let state = Orchestrator.readState(from: stateURL)
        var folder = requested.hasPrefix("/") ? requested : (state.flatMap { resolveProject(requested, $0) } ?? "")
        folder = (folder as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        guard !folder.isEmpty, FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return ("Couldn't find the folder \"\(requested)\". Use a project name from overview or an absolute path.", true)
        }
        guard !Orchestrator.owns(folder: folder) else { return ("Start chats in a project folder, not the orchestrator's own.", true) }
        let access = (arguments["access"] as? String).flatMap(LaunchAccess.init(rawValue:)) ?? .ask
        let model = (arguments["model"] as? String)?.trimmingCharacters(in: .whitespaces)
        let effort = (arguments["effort"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased()
        let action = OrchestratorAction(kind: .start, createdAt: now(), text: prompt, agent: agent.rawValue, folder: folder,
                                        model: model?.isEmpty == false ? model : nil, effort: effort?.isEmpty == false ? effort : nil,
                                        access: access.rawValue, conversation: conversation)
        return propose(action, summary: "Start \(agent.title) in \(folder) (\(access.title.lowercased()))")
    }

    func replyChat(_ arguments: [String: Any]) -> (String, Bool) {
        guard let raw = (arguments["id"] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return ("Pass a chat id.", true) }
        let message = (arguments["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return ("Write the reply.", true) }
        guard message.count <= 100_000 else { return ("That reply is too long.", true) }
        guard let state = Orchestrator.readState(from: stateURL) else {
            return ("Burro hasn't shared a snapshot yet. Open Burro and try again.", true)
        }
        guard let chat = state.chats.first(where: { $0.id == raw }) ?? state.chats.first(where: { $0.id.hasSuffix(":" + raw.lowercased()) }),
              ChatTranscripts.identity(of: chat) != nil else {
            return ("No chat with the id \"\(raw)\". Use an id from overview or list_chats.", true)
        }
        let action = OrchestratorAction(kind: .reply, createdAt: now(), text: message, chatID: chat.id, chatTitle: chat.title,
                                        machine: machineName(chat), conversation: conversation)
        var summary = "Reply to \"\(chat.title)\" (\(agent(chat)) on \(machineName(chat)))"
        if !needsYou(chat) { summary += ". Note: that chat is \(stateText(chat)) right now, not waiting for a reply" }
        return propose(action, summary: summary)
    }

    /// Records the proposal and tells the model, plainly, that nothing was sent.
    private func propose(_ action: OrchestratorAction, summary: String) -> (String, Bool) {
        do {
            let (saved, duplicate) = try actions.propose(action, now: now())
            let what = action.kind == .reply ? "Nothing has been sent" : "Nothing has started"
            return ("Proposal \(saved.id)\(duplicate ? " (already waiting; not added twice)" : ""): \(summary). "
                    + "\(what). It is waiting for the user's approval in Burro, where they can edit it and send it, or discard it. "
                    + "Tell the user it is waiting for them; don't say it was sent or started.", false)
        } catch {
            return ("Couldn't record the proposal: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)", true)
        }
    }

    // MARK: Formatting

    private func header(_ state: OrchestratorState) -> String {
        let age = now().timeIntervalSince(state.generatedAt)
        return age > 300 ? "(Burro's snapshot is \(ago(state.generatedAt)) old; Burro may be closed or asleep.)" : "Burro snapshot, \(ago(state.generatedAt))."
    }
    private func row(_ chat: AgentSession, _ state: OrchestratorState) -> String {
        var line = "- \(chat.title) — \(agent(chat)) on \(machineName(chat)), \(folderName(chat)) · \(stateText(chat)) \(ago(chat.updatedAt)) · id \(chat.id)"
        let children = state.chats.filter { $0.isSubagent == true && $0.parentSessionID != nil && chat.id.hasSuffix($0.parentSessionID!) }
        if !children.isEmpty {
            let working = children.filter { $0.state == .working }.count
            line += " · \(children.count) subagents" + (working > 0 ? " (\(working) working)" : "")
        }
        return line
    }
    private func sorted(_ chats: [AgentSession]) -> [AgentSession] {
        var seen = Set<String>()
        return chats.filter { seen.insert($0.id).inserted }.sorted { $0.updatedAt > $1.updatedAt }
    }
    private func needsYou(_ chat: AgentSession) -> Bool { chat.state == .waiting && chat.remote?.stale != true }
    private func machineName(_ chat: AgentSession) -> String { chat.remote?.hostName ?? "This Mac" }
    private func agent(_ chat: AgentSession) -> String { chat.provider == .codex ? "Codex" : "Claude Code" }
    private func folderName(_ chat: AgentSession) -> String {
        let name = URL(fileURLWithPath: chat.cwd).lastPathComponent
        return name.isEmpty ? "no folder" : name
    }
    private func stateText(_ chat: AgentSession) -> String {
        if needsYou(chat) { return "needs you" }
        if chat.state == .working { return "working" }
        if chat.state == .scheduled { return "scheduled" }
        if chat.isDone { return "ready to read" }
        return "idle"
    }
    /// Local chats by folder (the repository or any of its worktrees); remote chats by a folder named like the project.
    private func inProject(_ chat: AgentSession, _ path: String, _ state: OrchestratorState) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if chat.cwd.split(separator: "/").contains(where: { $0 == name }) { return true }
        guard chat.remote == nil else { return false }
        let roots = [path] + state.worktrees.filter { $0.repositoryPath == path }.map(\.path)
        return ([chat.cwd] + chat.attachedPaths).contains { cwd in roots.contains { cwd == $0 || cwd.hasPrefix($0 + "/") } }
    }
    func resolveProject(_ text: String, _ state: OrchestratorState) -> String? {
        let wanted = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        if let exact = state.projects.first(where: { $0.path.lowercased() == wanted || $0.name.lowercased() == wanted }) { return exact.path }
        if let tree = state.worktrees.first(where: { $0.path.lowercased() == wanted }) { return tree.path }
        return state.projects.first { $0.name.lowercased().contains(wanted) || URL(fileURLWithPath: $0.path).lastPathComponent.lowercased() == wanted }?.path
    }
    private func ago(_ date: Date) -> String {
        let seconds = max(0, now().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
    private func tokens(_ value: Double) -> String {
        value >= 1_000_000 ? String(format: "%.1fM", value / 1_000_000) : (value >= 1000 ? String(format: "%.0fk", value / 1000) : String(Int(value)))
    }
}
