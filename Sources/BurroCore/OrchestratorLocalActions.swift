// Local actions: the Orchestrator adding or completing one of today's to-dos. burro-mcp is a
// separate process without Burro's to-do list, so its `add_todo` and `complete_todo` tools only
// record the request in the actions file (status pending). Burro claims pending requests under the
// file's lock (marking them applied, so two refreshes never apply one twice), applies them through
// its to-do store at once, tagged as added by the Orchestrator, and shows a small card with Undo.
// Applying records whether it changed anything and which to-do it touched (`recordLocal`); Undo is
// offered only for a change that happened, marks the action undone, and the app reverses exactly
// that to-do by id (never by matching text). Nothing here sends anything to an agent.
import Foundation

extension OrchestratorAction {
    /// Applied by Burro at once (with Undo) rather than proposed for Send.
    public var isLocal: Bool { kind == .addTodo || kind == .completeTodo }
    /// Undo is offered for a day after a change that actually happened.
    public func canUndo(now: Date = Date()) -> Bool {
        isLocal && status == .applied && changed == true && todoID != nil && now.timeIntervalSince(appliedAt ?? createdAt) < Self.lifetime
    }
    /// The to-do Undo reverses: the one applying touched, only when it changed something.
    public var undoTarget: String? { changed == true ? todoID : nil }
    /// The to-do source Burro tags Orchestrator to-dos with.
    public static let todoSource = "orchestrator"

    public static func addTodo(text: String, project: String?, now: Date, conversation: String?) -> OrchestratorAction {
        var action = OrchestratorAction(kind: .addTodo, createdAt: now, text: text, conversation: conversation)
        action.project = project
        return action
    }
    public static func completeTodo(id: String, text: String, now: Date, conversation: String?) -> OrchestratorAction {
        var action = OrchestratorAction(kind: .completeTodo, createdAt: now, text: text, conversation: conversation)
        action.todoID = id
        return action
    }
}

extension OrchestratorActionStore {
    /// Records a local action for Burro to apply.
    public func request(_ action: OrchestratorAction, now: Date = Date()) throws -> OrchestratorAction {
        try update(now: now) { actions in
            actions.append(action)
            return action
        }
    }

    /// Takes every pending local action and marks it applied; an added to-do gets its local id
    /// (`local:<uuid>`) here, so the app adds it under that id. Returns what the app should apply.
    public func claimLocal(now: Date = Date(), newID: () -> String = { UUID().uuidString.lowercased() }) throws -> [OrchestratorAction] {
        try update(now: now) { actions in
            var claimed: [OrchestratorAction] = []
            for index in actions.indices where actions[index].isLocal && actions[index].status == .pending {
                if actions[index].kind == .addTodo && actions[index].todoID == nil { actions[index].todoID = TodoLedger.localPrefix + newID() }
                actions[index].status = .applied
                actions[index].appliedAt = now
                claimed.append(actions[index])
            }
            return claimed
        }
    }

    /// Marks an applied local action undone; returns it (as it was) when Undo is still possible.
    public func undoLocal(_ id: String, now: Date = Date()) throws -> OrchestratorAction? {
        try update(now: now) { actions in
            guard let index = actions.firstIndex(where: { $0.id == id }), actions[index].canUndo(now: now) else { return nil }
            let before = actions[index]
            actions[index].status = .undone
            actions[index].undoneAt = now
            return before
        }
    }

    /// Records what applying did: whether the list changed, and the to-do it touched.
    public func recordLocal(_ id: String, changed: Bool, todoID: String?) throws {
        try modify(id) { action in
            action.changed = changed
            if let todoID { action.todoID = todoID }
        }
    }

    /// Records why applying failed, so the card can say so.
    public func failLocal(_ id: String, error: String) throws {
        try modify(id) { $0.error = error }
    }
}
