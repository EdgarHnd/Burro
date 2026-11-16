// Stopping and steering a chat that is working, and what the composer offers for each chat.
// Every provider call is built as plain data first (method and params, or argv) so it can be
// checked in tests; it runs only from the composer on the owner's click.
//
// Codex (app-server schema, generated from the installed CLI): the running turn's id comes from
// `thread/turns/list` (newest first, items not loaded); `turn/interrupt {threadId, turnId}` stops
// it and `turn/steer {threadId, expectedTurnId, input}` adds to it. Claude background sessions:
// `claude stop <short id>` (the conversation is kept), locally or through the fixed remote script,
// which finds the short id itself from the session id. Sessions the Claude app or a terminal owns
// can't be stopped from outside: the composer says so and offers to open them. An idle Claude
// background session takes a reply: Send stops it and continues it (ClaudeContinue.swift), and
// its help says so (`sendStopsFirst`). Triage drafts and Orchestrator reply cards send the same
// way, and their help says so for every Claude chat (`cardSendHelp`). A sub-agent's plan keeps
// only its Stop: no reply field, queue, steer or reply hand-off.
import Foundation

/// How a working chat can be stopped from Burro.
public enum ChatStop: Equatable, Sendable {
    /// `turn/interrupt` on the running Codex turn.
    case codex
    /// `claude stop <handle>` on this Mac.
    case claudeBackground(handle: String)
    /// The machine's fixed script stops its own background session for this session id.
    case claudeRemote
    /// Owned by the Claude app or a terminal: "Stop it in Claude" opens it there.
    case elsewhere
}

/// What the composer shows for one chat right now.
public struct ComposerPlan: Equatable, Sendable {
    /// The single right action beside the reason when a reply is impossible.
    public enum Action: Equatable, Sendable {
        case openInProvider
        case attachInTerminal(handle: String)
        case attachOnMachine(handle: String)
        case queue
    }
    /// Why a plain reply can't go now; replaces the access/model/effort pickers.
    public var reason: String?
    public var action: Action?
    public var canType = false
    public var showPickers = false
    public var canSend = false
    public var canQueue = false
    public var canSteer = false
    public var stop: ChatStop?
    public var attachments = false
    /// Send first stops this chat's idle Claude background session, then continues it.
    public var sendStopsFirst = false
    public init(reason: String? = nil, action: Action? = nil) { self.reason = reason; self.action = action }
}

extension ChatReply {
    // MARK: Composer

    /// The composer's choices. `check` is the Claude open-session check (nil until it has run or
    /// for Codex); `setupProblem` is a Codex machine that can't take replies; `queued` whether a
    /// message already waits for this chat (never more than one).
    public static func composerPlan(_ session: AgentSession, host: RemoteHost?, check: ClaudeCheck?, setupProblem: String?,
                                    queued: Bool, hasURL: Bool) -> ComposerPlan {
        // A sub-agent keeps only its Stop: never a reply field, queue, steer or hand-off to reply.
        if session.isSubagent == true {
            var parent = session
            parent.isSubagent = false
            var plan = ComposerPlan(reason: ChatReply.subagentReason)
            plan.stop = composerPlan(parent, host: host, check: check, setupProblem: setupProblem, queued: queued, hasURL: hasURL).stop
            return plan
        }
        let open: ComposerPlan.Action? = hasURL ? .openInProvider : nil
        guard ChatTranscripts.identity(of: session) != nil else { return ComposerPlan(reason: "Burro can't reply to this kind of chat.", action: open) }
        if session.remote != nil && host == nil { return ComposerPlan(reason: "That machine isn't configured in Burro any more.") }
        if session.remote?.stale == true { return ComposerPlan(reason: "\(session.remote?.hostName ?? "That machine") isn't answering right now.") }
        if let setupProblem { return ComposerPlan(reason: setupProblem) }
        let remote = session.remote != nil
        let attachments = !remote
        let check = session.provider == .claude ? check : nil
        let backgroundStop: ChatStop? = check?.background == true ? (remote ? .claudeRemote : check?.attach.map { .claudeBackground(handle: $0) }) : nil

        if session.state == .working || check?.busy == true {
            if session.provider == .codex {
                var plan = ComposerPlan()
                plan.canType = true; plan.canQueue = !queued; plan.canSteer = session.state == .working; plan.stop = .codex
                plan.attachments = attachments
                return plan
            }
            if check?.open == true && check?.background == false {
                var plan = ComposerPlan(reason: ChatReply.runsElsewhere, action: open)
                plan.stop = .elsewhere
                return plan
            }
            var plan = ComposerPlan()
            plan.canType = true; plan.canQueue = !queued; plan.stop = backgroundStop; plan.attachments = attachments
            if session.state != .working { plan.reason = check?.problem; plan.action = queued ? nil : .queue }
            return plan
        }
        if let check, let problem = check.problem {
            if check.background, let handle = check.attach {
                return ComposerPlan(reason: problem, action: remote ? .attachOnMachine(handle: handle) : .attachInTerminal(handle: handle))
            }
            return ComposerPlan(reason: problem, action: check.open ? open : nil)
        }
        var plan = ComposerPlan()
        plan.canType = true; plan.showPickers = true; plan.canSend = true; plan.attachments = attachments
        plan.sendStopsFirst = check?.continues == true
        return plan
    }

    /// The Send button's help.
    public static func sendHelp(_ plan: ComposerPlan) -> String {
        plan.sendStopsFirst ? "Stops the idle background session and continues it with your message (Return)" : "Send (Return)"
    }

    /// The Send help on a triage draft or Orchestrator reply card. Those cards don't run the slow
    /// open-session check, and their Send stops an idle Claude background session the same way the
    /// composer's does, so a Claude chat gets the general sentence.
    public static func cardSendHelp(provider: AgentProvider?) -> String {
        provider == .claude
            ? "Send this reply to the chat. If its idle background session is still open, Burro stops it and continues it with your message."
            : "Send this reply to the chat"
    }

    // MARK: Requests (pure)

    /// The newest turn, without its items: enough to find the running turn's id.
    static func codexTurnsListParams(threadID: String) -> [String: Any] {
        ["threadId": threadID, "limit": 1, "itemsView": "notLoaded"]
    }
    /// The running turn's id from a `thread/turns/list` result, or nil when nothing is running.
    static func codexActiveTurn(_ result: [String: Any]) -> String? {
        guard let turns = result["data"] as? [[String: Any]] else { return nil }
        return turns.first { $0["status"] as? String == "inProgress" }.flatMap { $0["id"] as? String }.flatMap { $0.isEmpty ? nil : $0 }
    }
    static func codexInterruptParams(threadID: String, turnID: String) -> [String: Any] {
        ["threadId": threadID, "turnId": turnID]
    }
    static func codexSteerParams(threadID: String, turnID: String, _ request: ReplyRequest) -> [String: Any] {
        ["threadId": threadID, "expectedTurnId": turnID, "input": ChatAttachments.codexInput(text: request.trimmed, paths: request.attachments)]
    }
    /// `claude stop <short id>`; nil unless the id is the hex handle `claude agents` prints.
    static func claudeStopArguments(handle: String) -> [String]? {
        handle.range(of: #"^[0-9a-f]{6,36}$"#, options: .regularExpression) != nil ? ["stop", handle] : nil
    }
    /// How a Claude session found by `claude agents --json` can be stopped.
    static func claudeStop(_ live: ClaudeLive?, remote: Bool) -> ChatStop? {
        guard let live else { return nil }
        guard live.background else { return .elsewhere }
        if remote { return .claudeRemote }
        return live.handle.map { .claudeBackground(handle: $0) }
    }

    // MARK: Running (explicit click only)

    /// Stops the running turn or background session. The conversation is kept.
    public static func stop(_ session: AgentSession, host: RemoteHost?) throws -> String {
        guard let (provider, id) = ChatTranscripts.identity(of: session) else { throw LaunchError.failed("Burro can't stop this kind of chat.") }
        if session.remote != nil && host == nil { throw LaunchError.failed("That machine isn't configured in Burro any more.") }
        if provider == "codex" {
            let server = try codexServer(host)
            defer { server.close() }
            _ = try? server.request("thread/resume", ["threadId": id, "excludeTurns": true])
            guard let turn = codexActiveTurn(try server.request("thread/turns/list", codexTurnsListParams(threadID: id))) else {
                throw LaunchError.failed("Codex isn't running a turn in this chat now.")
            }
            _ = try server.request("turn/interrupt", codexInterruptParams(threadID: id, turnID: turn))
            return "Stopped. The conversation is kept."
        }
        if let host {
            _ = try remoteClaude(["stop": id], host: host)
            return "Stopped on \(host.name). The conversation is kept."
        }
        guard let claude = ClaudeLaunch.executable() else { throw LaunchError.notInstalled(.claude) }
        switch claudeStop(claudeLive(id, claude: claude), remote: false) {
        case .claudeBackground(let handle)?:
            guard let arguments = claudeStopArguments(handle: handle) else { throw LaunchError.failed("Claude gave this session an unexpected id.") }
            let result = try LaunchShell.run(claude, arguments, folder: NSHomeDirectory(), timeout: 30)
            guard result.code == 0 else { throw LaunchError.failed("Claude didn't stop it: \(result.text.split(whereSeparator: \.isNewline).last.map(String.init) ?? "unknown error")") }
            return "Stopped. The conversation is kept."
        case .elsewhere?: throw LaunchError.failed("This chat runs in the Claude app or a terminal. Stop it there.")
        default: throw LaunchError.failed("Claude isn't running this chat as a background session now.")
        }
    }

    /// Adds the message to the Codex turn that is running now (`turn/steer`). Fails, without
    /// sending, when that turn has already ended.
    public static func steer(_ request: ReplyRequest, to session: AgentSession, host: RemoteHost?) throws -> String {
        guard !request.trimmed.isEmpty else { throw LaunchError.failed("Write a message first.") }
        guard request.trimmed.count <= 100_000 else { throw LaunchError.failed("That message is too long.") }
        guard session.provider == .codex, let (_, id) = ChatTranscripts.identity(of: session) else { throw LaunchError.failed("Only Codex chats can be steered.") }
        if session.remote != nil && host == nil { throw LaunchError.failed("That machine isn't configured in Burro any more.") }
        if session.remote != nil && !request.attachments.isEmpty { throw LaunchError.failed(ChatAttachments.localOnly) }
        let server = try codexServer(host)
        defer { server.close() }
        _ = try? server.request("thread/resume", ["threadId": id, "excludeTurns": true])
        guard let turn = codexActiveTurn(try server.request("thread/turns/list", codexTurnsListParams(threadID: id))) else {
            throw LaunchError.failed("That turn already ended. Send it as a normal reply.")
        }
        _ = try server.request("turn/steer", codexSteerParams(threadID: id, turnID: turn, request))
        return "Sent. Codex takes it into the turn it's on."
    }

    static func codexServer(_ host: RemoteHost?) throws -> CodexAppServer {
        try host.map { try CodexAppServer.remote($0) }
            ?? CodexAppServer.connect(executable: CodexUsageReader.executable() ?? { throw LaunchError.notInstalled(.codex) }())
    }

    // MARK: Remote Claude check

    /// The machine's answer to `{"check": id}`: whether something has the session open there and,
    /// for a background session, its short id (hex only) for "Attach on <machine>".
    static func remoteClaudeCheck(_ id: String, host: RemoteHost) -> ClaudeCheck {
        do {
            let data = try RemoteScript.run("remote_reply", request: ["check": id], host: host, timeout: 90)
            return remoteCheck(data, host: host.name)
        } catch { return ClaudeCheck(problem: (error as? LocalizedError)?.errorDescription) }
    }
    static func remoteCheck(_ data: Data, host: String) -> ClaudeCheck {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ClaudeCheck(problem: "\(host) didn't answer as expected.")
        }
        if let live = object["live"] as? [String: Any] {
            let handle = (live["handle"] as? String).flatMap { $0.range(of: #"^[0-9a-f]{6,36}$"#, options: .regularExpression) != nil ? $0 : nil }
            return claudePlan(ClaudeLive(handle: handle, background: live["kind"] as? String == "background", busy: live["busy"] as? Bool == true,
                                         idle: live["idle"] as? Bool == true, waiting: live["waiting"] as? Bool == true),
                              attached: live["attached"] as? Bool == true)
        }
        if object["ok"] as? Bool == true { return ClaudeCheck() }
        return ClaudeCheck(problem: (object["error"] as? String) ?? "Claude can't take a reply on \(host).")
    }
}

/// "Attach on <machine>": a Terminal `.command` file that runs `ssh -t` with remote monitoring's
/// strict options to that host and `claude attach <hex>` there. Only the validated destination
/// and the hex short id vary; everything else is fixed.
public enum RemoteAttach {
    public static func arguments(host: RemoteHost, handle: String) -> [String]? {
        guard host.validationError == nil, handle.range(of: #"^[0-9a-f]{6,36}$"#, options: .regularExpression) != nil else { return nil }
        var args = RemoteAgentMonitor.arguments(for: host)
        guard args.first == "-T", args.last == "python3 -" else { return nil }
        args[0] = "-t"
        args.removeLast()
        return args + [#"sh -c 'PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; exec claude attach "# + handle + "'"]
    }
    /// The `.command` file's text: every argument single-quoted for zsh.
    public static func script(host: RemoteHost, handle: String) -> String? {
        guard let args = arguments(host: host, handle: handle) else { return nil }
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
        return "#!/bin/zsh\nexec /usr/bin/ssh " + args.map(quoted).joined(separator: " ") + "\n"
    }
}
