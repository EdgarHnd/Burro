// The Orchestrator's briefing tools, served by burro-mcp next to the ones in OrchestratorTools.swift.
// All read Burro's snapshot or the Orchestrator's own folder and return compact text:
// `chat_digest` (the Brief's triage result for the chat when there is one, its last ask and answer,
// the question it ends on, and its worktree's state, without diff bodies), `read_shipped` (cached Shipped summaries only; it never runs gh), `usage`,
// `read_notes` (only when the user allows it), and `read_file` / `search_files` (project and worktree
// folders only, through OrchestratorFileAccess). Three change something: `remember` and `forget`
// edit its memory file, and `add_todo` / `complete_todo` record a local action that Burro applies at
// once with Undo (OrchestratorLocalActions.swift). None of them sends anything to an agent.
import CryptoKit
import Foundation

extension OrchestratorTools {
    static var moreDefinitions: [[String: Any]] { [
        moreTool("chat_digest", "A chat in a few lines: what the brief's triage says about it (headline, question, drafted reply) when it has an entry, its last user message, its last assistant message (clipped), the question it ends on if any, and its worktree (branch, changed, untracked, unpushed). Cheaper than read_chat.", [
            "id": ["type": "string", "description": "A chat id from brief, overview or list_chats."],
        ], required: ["id"]),
        moreTool("read_shipped", "What shipped on GitHub for the main project, from Burro's cached daily and weekly summaries (never fetched live).", [
            "period": ["type": "string", "enum": ["day", "week"], "description": "Default day."],
            "date": ["type": "string", "description": "yyyy-MM-dd; default today (for a week, the week containing it)."],
        ]),
        moreTool("usage", "How much of each Claude, Codex and Grok usage window is left, and when each resets.", [:]),
        moreTool("read_notes", "The user's notes (titles and text), only if they allowed the Orchestrator to read notes.", [
            "query": ["type": "string", "description": "Optional text to match."],
        ]),
        moreTool("read_file", "Read a text file inside one of the user's project or worktree folders (nothing else is readable).", [
            "path": ["type": "string", "description": "Absolute path."],
            "offset": ["type": "integer", "minimum": 1, "description": "First line, default 1."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 2000, "description": "Lines, default 400."],
        ], required: ["path"]),
        moreTool("search_files", "Find files by name pattern and/or lines containing text, in the project and worktree folders.", [
            "query": ["type": "string", "description": "Text to find (case-insensitive)."],
            "name": ["type": "string", "description": "File name pattern, e.g. *.swift."],
            "folder": ["type": "string", "description": "Limit to this project or worktree folder (absolute path)."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 300],
        ]),
        moreTool("add_todo", "Add a to-do to the user's list for today. Burro adds it at once, marked as yours, and the user can undo it.", [
            "text": ["type": "string"],
            "project": ["type": "string", "description": "Optional project name or path."],
        ], required: ["text"]),
        moreTool("complete_todo", "Tick off one of today's to-dos (ids from overview). Burro applies it at once; the user can undo it.", [
            "id": ["type": "string"],
        ], required: ["id"]),
        moreTool("remember", "Keep a short standing note you'll be given every turn: a preference or fact the user stated that will matter again.", [
            "text": ["type": "string", "description": "One short sentence."],
            "scope": ["type": "string", "description": "\"global\" (default) or a project path."],
        ], required: ["text"]),
        moreTool("forget", "Drop a memory note by its id (shown in your memory section).", [
            "id": ["type": "string"],
        ], required: ["id"]),
    ] }

    private static func moreTool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }

    var memoryStore: OrchestratorMemory {
        OrchestratorMemory(url: stateURL.deletingLastPathComponent().appendingPathComponent("memory.json"))
    }

    /// Handles the tools in this file; nil for any other name.
    func callMore(_ name: String, _ arguments: [String: Any]) -> (String, Bool)? {
        switch name {
        case "remember": return remember(arguments)
        case "forget": return forget(arguments)
        case "chat_digest", "read_shipped", "usage", "read_notes", "read_file", "search_files", "add_todo", "complete_todo": break
        default: return nil
        }
        guard let state = Orchestrator.readState(from: stateURL) else {
            return ("Burro hasn't shared a snapshot yet. Open Burro and try again.", true)
        }
        switch name {
        case "chat_digest": return chatDigest(state, arguments)
        case "read_shipped": return (readShipped(state, arguments), false)
        case "usage": return (usage(state), false)
        case "read_notes": return readNotes(state, arguments)
        case "read_file": return readFile(state, arguments)
        case "search_files": return searchFiles(state, arguments)
        case "add_todo": return addTodo(state, arguments)
        default: return completeTodo(state, arguments)
        }
    }

    // MARK: Chats

    func chatDigest(_ state: OrchestratorState, _ arguments: [String: Any]) -> (String, Bool) {
        guard let raw = (arguments["id"] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return ("Pass a chat id.", true) }
        guard let chat = state.chats.first(where: { $0.id == raw }) ?? state.chats.first(where: { $0.id.hasSuffix(":" + raw.lowercased()) }) else {
            return ("No chat with the id \"\(raw)\". Use an id from brief, overview or list_chats.", true)
        }
        var lines = ["# \(chat.title)",
                     "\(chat.provider == .codex ? "Codex" : "Claude Code") on \(chat.remote?.hostName ?? "This Mac"), \(URL(fileURLWithPath: chat.cwd).lastPathComponent) · \(Self.digestState(chat)) · updated \(Self.digestAgo(chat.updatedAt, now: now())) · id \(chat.id)"]
        let brief = briefLines(for: chat, file: briefFile)
        if let brief { lines += brief.lines }
        if let tree = Self.worktree(for: chat, in: state.worktrees) {
            var parts = [tree.branch.isEmpty ? "detached" : tree.branch, "\(tree.changed) changed", "\(tree.untracked) untracked"]
            if let unpushed = tree.unpushed { parts.append("\(unpushed) unpushed") }
            if tree.readyToRemove { parts.append("safe to clean") }
            lines.append("Worktree: " + parts.joined(separator: " · "))
        }
        do {
            let transcript = try readChat(chat.id, state.hosts, state.usageProfiles, 40)
            let messages = transcript.messages
            if let user = messages.last(where: { $0.kind == .user }) {
                lines.append("Last from the user\(Self.time(user.at)): " + OrchestratorEvent.clip(user.text.replacingOccurrences(of: "\n", with: " "), 600))
            }
            // With a current brief entry the question is already above; keep the answer short.
            let current = brief?.current == true
            if let reply = messages.last(where: { $0.kind == .assistant }) {
                lines.append("Last from the agent\(Self.time(reply.at)): " + OrchestratorEvent.clip(reply.text, current ? 500 : 1500))
            }
            if !current, let question = Self.pendingQuestion(messages, waiting: chat.state == .waiting) { lines.append("Ends on: " + question) }
            if let last = messages.last { lines.append("cursor: \(Self.cursor(last))") }
            if messages.isEmpty { lines.append("No messages yet.") }
        } catch {
            lines.append((error as? LocalizedError)?.errorDescription ?? "Couldn't read that chat.")
        }
        return (lines.joined(separator: "\n"), false)
    }

    /// The question a transcript ends on: an ask tool, or the last assistant message's last question.
    public static func pendingQuestion(_ messages: [ChatMessage], waiting: Bool) -> String? {
        guard let last = messages.last(where: { !($0.kind == .tool && $0.tool == "TodoWrite") }) else { return waiting ? "waiting for the user" : nil }
        switch last.kind {
        case .user: return nil
        case .tool:
            if ["AskUserQuestion", "request_user_input", "ExitPlanMode"].contains(last.tool ?? "") {
                return "asks the user: " + OrchestratorEvent.clip(last.text.replacingOccurrences(of: "\n", with: " "), 300)
            }
            return waiting ? "waiting for the user (a permission prompt or a question)" : nil
        case .assistant:
            let paragraph = last.text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
            guard paragraph.contains("?") else { return waiting ? "waiting for the user" : nil }
            let sentences = paragraph.split(omittingEmptySubsequences: true) { ".!".contains($0) }.map { $0.trimmingCharacters(in: .whitespaces) }
            let question = sentences.last { $0.contains("?") } ?? paragraph
            return OrchestratorEvent.clip(question, 300)
        }
    }

    /// A short, stable id for a message, for `read_chat`'s `since`.
    public static func cursor(_ message: ChatMessage) -> String {
        let material = "\(message.kind.rawValue)|\(message.at.map { String(Int($0.timeIntervalSince1970)) } ?? "")|\(message.tool ?? "")|\(message.text.prefix(400))"
        return SHA256.hash(data: Data(material.utf8)).prefix(5).map { String(format: "%02x", $0) }.joined()
    }

    /// The messages after `since` (a cursor, an ISO 8601 time or seconds since 1970), and whether it was found.
    public static func messages(_ messages: [ChatMessage], since: String) -> (messages: [ChatMessage], found: Bool) {
        let since = since.trimmingCharacters(in: .whitespaces)
        if let index = messages.lastIndex(where: { cursor($0) == since.lowercased() }) { return (Array(messages[(index + 1)...]), true) }
        let date = ISO8601DateFormatter().date(from: since) ?? Double(since).map { Date(timeIntervalSince1970: $0) }
        if let date { return (messages.filter { ($0.at ?? .distantPast) > date }, true) }
        return (messages, false)
    }

    static func worktree(for chat: AgentSession, in trees: [OrchestratorState.WorktreeRow]) -> OrchestratorState.WorktreeRow? {
        guard chat.remote == nil else { return nil }
        return trees.filter { chat.cwd == $0.path || chat.cwd.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
    }

    // MARK: Shipped, usage, notes

    func readShipped(_ state: OrchestratorState, _ arguments: [String: Any]) -> String {
        let period = arguments["period"] as? String == "week" ? "week" : "day"
        let rows = (state.shipped ?? []).filter { $0.period == period }
        guard !rows.isEmpty else { return "Burro has no cached Shipped \(period == "week" ? "week" : "days") for the main project yet (it fills in when the Today page has been open)." }
        let wanted = (arguments["date"] as? String)?.trimmingCharacters(in: .whitespaces)
        let row: OrchestratorState.ShippedRow?
        if let wanted, !wanted.isEmpty {
            row = period == "week" ? rows.filter { $0.date <= wanted }.max { $0.date < $1.date } : rows.first { $0.date == wanted }
        } else {
            row = rows.max { $0.date < $1.date }
        }
        guard let row else { return "Nothing cached for \(wanted ?? "that day"). Cached: " + rows.map(\.date).sorted().joined(separator: ", ") }
        var lines = ["Shipped, \(period == "week" ? "week of " : "")\(row.date)" + (row.repository.map { " · \($0)" } ?? "")]
        if let summary = row.summary, !summary.isEmpty { lines.append(OrchestratorEvent.clip(summary, 3000)) }
        if !row.production.isEmpty { lines.append("Production: " + row.production.prefix(10).joined(separator: "; ")) }
        if !row.merged.isEmpty { lines.append("Merged (\(row.merged.count)):"); lines += row.merged.prefix(30).map { "- " + $0 } }
        if row.inProgress > 0 { lines.append("\(row.inProgress) people with work in progress") }
        if row.summary == nil && row.merged.isEmpty && row.production.isEmpty { lines.append("Nothing shipped.") }
        return lines.joined(separator: "\n")
    }

    func usage(_ state: OrchestratorState) -> String {
        let rows = state.usage ?? []
        guard !rows.isEmpty else { return "Burro hasn't read any usage windows yet (usage may be off in Settings)." }
        return rows.map { row in
            var line = "- \(row.provider) \(row.window)" + (row.model.map { " (\($0))" } ?? "") + ": "
            line += row.remainingPercent.map { "\(Int($0.rounded()))% left" } ?? "unknown"
            if let reset = row.resetsAt { line += ", resets " + (reset > now() ? "in " + Self.digestIn(reset, now: now()) : "now") }
            return line
        }.joined(separator: "\n")
    }

    func readNotes(_ state: OrchestratorState, _ arguments: [String: Any]) -> (String, Bool) {
        guard state.notesAccess == true else {
            return ("The user hasn't allowed the Orchestrator to read notes. They can turn it on from the Orchestrator page's settings.", true)
        }
        let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let notes = (state.notes ?? []).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query) }
        guard !notes.isEmpty else { return (query.isEmpty ? "No notes." : "No notes match.", false) }
        return (notes.prefix(30).map { "## \($0.title) (edited \(Self.digestAgo($0.updatedAt, now: now())))\n" + OrchestratorEvent.clip($0.text, 2000) }
            .joined(separator: "\n\n"), false)
    }

    // MARK: Files

    func readFile(_ state: OrchestratorState, _ arguments: [String: Any]) -> (String, Bool) {
        guard let path = arguments["path"] as? String, !path.isEmpty else { return ("Pass a path.", true) }
        switch OrchestratorFileAccess.standard(state: state).read(path, offset: arguments["offset"] as? Int ?? 1, limit: arguments["limit"] as? Int ?? 400) {
        case .success(let text): return (text, false)
        case .failure(let refusal): return (refusal.errorDescription ?? "Couldn't read that file.", true)
        }
    }

    func searchFiles(_ state: OrchestratorState, _ arguments: [String: Any]) -> (String, Bool) {
        let folder = (arguments["folder"] as? String).flatMap { $0.hasPrefix("/") || $0.hasPrefix("~") ? $0 : resolveProject($0, state) }
        let text = OrchestratorFileAccess.standard(state: state).search(query: arguments["query"] as? String, name: arguments["name"] as? String,
                                                                        under: folder, limit: arguments["limit"] as? Int ?? 80)
        return (text, false)
    }

    // MARK: Changes

    func addTodo(_ state: OrchestratorState, _ arguments: [String: Any]) -> (String, Bool) {
        guard let text = TodoLedger.clean(arguments["text"] as? String ?? "") else { return ("Write the to-do.", true) }
        let project = (arguments["project"] as? String).flatMap { resolveProject($0, state) }
        if let open = state.todos.first(where: { !$0.done && $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
            return ("That to-do is already on the list" + (open.id.map { " (id \($0))" } ?? "") + ". Nothing added.", false)
        }
        return requestLocal(.addTodo(text: text, project: project, now: now(), conversation: conversation),
                            summary: "Burro adds “\(text)” to today's to-dos" + (project.map { " for \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? ""))
    }

    func completeTodo(_ state: OrchestratorState, _ arguments: [String: Any]) -> (String, Bool) {
        guard let id = (arguments["id"] as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return ("Pass a to-do id from overview.", true) }
        guard let todo = state.todos.first(where: { $0.id == id }) else { return ("No to-do with the id \"\(id)\". Use an id from overview.", true) }
        guard !todo.done else { return ("“\(todo.text)” is already done.", false) }
        return requestLocal(.completeTodo(id: id, text: todo.text, now: now(), conversation: conversation), summary: "Burro ticks off “\(todo.text)”")
    }

    private func requestLocal(_ action: OrchestratorAction, summary: String) -> (String, Bool) {
        do {
            let saved = try actions.request(action, now: now())
            return ("To-do action \(saved.id): \(summary) right away (or as soon as Burro is open), and shows it with Undo. "
                    + "Tell the user what you changed.", false)
        } catch {
            return ("Couldn't record that: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)", true)
        }
    }

    func remember(_ arguments: [String: Any]) -> (String, Bool) {
        let text = arguments["text"] as? String ?? ""
        let scope = arguments["scope"] as? String ?? OrchestratorMemoryEntry.global
        do {
            guard let entry = try memoryStore.remember(text, scope: scope, source: .orchestrator, now: now()) else { return ("Write the note.", true) }
            return ("Remembered [\(entry.id.prefix(8))] (\(entry.isGlobal ? "global" : entry.scope)): \(entry.text). The user can see and edit it on the Memory tab.", false)
        } catch {
            return ("Couldn't save that note.", true)
        }
    }

    func forget(_ arguments: [String: Any]) -> (String, Bool) {
        let id = arguments["id"] as? String ?? ""
        do {
            guard let entry = try memoryStore.forget(id) else { return ("No single memory note matches \"\(id)\".", true) }
            return ("Forgot: \(entry.text)", false)
        } catch {
            return ("Couldn't change the memory.", true)
        }
    }

    // MARK: Formatting

    static func digestState(_ chat: AgentSession) -> String {
        if chat.state == .waiting && chat.remote?.stale != true { return "needs you" }
        if chat.state == .working { return "working" }
        if chat.state == .scheduled { return "scheduled" }
        return chat.isDone ? "ready to read" : "idle"
    }
    static func digestAgo(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
    static func digestIn(_ date: Date, now: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 3600 { return "\(max(1, Int(seconds / 60)))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))m" }
        return "\(Int(seconds / 86_400))d \(Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3600))h"
    }
    private static func time(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return " (\(formatter.string(from: date)))"
    }
}
