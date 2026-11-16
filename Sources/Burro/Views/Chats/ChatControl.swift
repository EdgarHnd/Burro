// What a chat's header and composer share on the Chats page: the Claude open-session check, a
// Codex machine's setup problem and model list, and Stop. The header shows Stop (⌘.) or "Stop it
// in Claude" from the same `ComposerPlan` the composer uses, so the two never disagree; the
// composer runs the checks (on appear and whenever the chat's state changes) and shows Stop's
// result line. Stop runs only on the owner's click (`ChatReply.stop`, off the main thread).
// A Claude chat's composer isn't offered before its first check has answered (`awaitingCheck`),
// so a chat open in the Claude app never flashes a reply field that then turns into the "open in
// Claude" bar; the last answer for each chat is remembered while Burro runs, so going back to a
// chat shows its composer at once (and checks again behind it). Codex chats never wait.
import AppKit
import SwiftUI
import BurroCore

@MainActor @Observable final class ChatControl {
    /// Whether something has this Claude session open (and how), rechecked as its state changes.
    var check: ChatReply.ClaudeCheck?
    /// Codex setup on the chat's machine that prevents replies, found when the composer appears.
    var setupProblem: String?
    var remoteModels: [LaunchModel]?
    var stopping = false
    /// The last confirmation or failure, shown above the composer.
    var notice: String?
    var error: String?

    /// The latest check for each chat, kept while Burro runs, so a chat you come back to doesn't
    /// wait for its check again before showing what it last allowed.
    private static var known: [String: ChatReply.ClaudeCheck] = [:]

    init(check: ChatReply.ClaudeCheck? = nil) { self.check = check }

    func plan(_ session: AgentSession, host: RemoteHost?, queued: Bool) -> ComposerPlan {
        ChatReply.composerPlan(session, host: host, check: check ?? Self.known[session.id], setupProblem: setupProblem,
                               queued: queued, hasURL: session.chatURL != nil)
    }

    /// True while `plan` offers a reply field that this Claude chat's first check could still take
    /// away (nothing has answered for it yet). Never for Codex, nor when the plan already offers
    /// no field for a reason the check can't change (a sub-agent, an unreachable machine…).
    func awaitingCheck(_ session: AgentSession, plan: ComposerPlan) -> Bool {
        plan.canType && session.provider == .claude && check == nil && Self.known[session.id] == nil
    }

    /// Stops the running turn or background session, or opens the chat where only it can stop.
    func halt(_ stop: ChatStop, session: AgentSession, host: RemoteHost?, onStopped: @escaping () -> Void) {
        if stop == .elsewhere { if let url = session.chatURL { NSWorkspace.shared.open(url) }; return }
        guard !stopping else { return }
        stopping = true; error = nil; notice = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                Result { try ChatReply.stop(session, host: host) }
            }.value
            stopping = false
            switch result {
            case .success(let confirmation): notice = confirmation; onStopped()
            case .failure(let failure): error = (failure as? LocalizedError)?.errorDescription ?? "Couldn't stop it."
            }
        }
    }

    /// Whether something has this Claude session open, again whenever its state changes.
    func recheckClaude(_ session: AgentSession, host: RemoteHost?) async {
        guard session.provider == .claude else { return }
        let result = await Task.detached(priority: .userInitiated) { ChatReply.claudeCheck(session, host: host) }.value
        check = result
        Self.known[session.id] = result
    }
}
