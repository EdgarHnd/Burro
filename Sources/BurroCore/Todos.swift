// Today's to-dos, offline first. The visible list is the last server snapshot with pending
// changes applied on top; changes queue until Convex accepts them, so ticking a box never
// waits on the network and nothing typed while offline is lost.
import Foundation

public struct TodoItem: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var text: String
    public var day: String
    public var done: Bool
    public var doneAt: Double?
    public var order: Double
    public var source: String
    public var project: String?
    public var createdAt: Double
    public var updatedAt: Double
    /// Not on the server yet: the id is `local:<clientId>` until the add is accepted.
    public var isLocal: Bool { id.hasPrefix(TodoLedger.localPrefix) }
    public init(id: String, text: String, day: String, done: Bool = false, doneAt: Double? = nil, order: Double,
                source: String = "burro", project: String? = nil, createdAt: Double, updatedAt: Double) {
        self.id = id; self.text = text; self.day = day; self.done = done; self.doneAt = doneAt; self.order = order
        self.source = source; self.project = project; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public enum TodoOp: Codable, Sendable, Equatable {
    case add(clientId: String, text: String, day: String, project: String?)
    case setDone(id: String, done: Bool)
    case edit(id: String, text: String)
    case remove(id: String)
    var target: String {
        switch self {
        case .add(let clientId, _, _, _): TodoLedger.localPrefix + clientId
        case .setDone(let id, _), .edit(let id, _), .remove(let id): id
        }
    }
}

public enum TodoDay {
    public static func key(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    /// The calendar day's start in Convex's millisecond timestamps.
    public static func startMillis(_ date: Date = Date(), calendar: Calendar = .current) -> Double {
        (calendar.startOfDay(for: date).timeIntervalSince1970 * 1000).rounded()
    }
}

public enum TodoLedger {
    public static let localPrefix = "local:"

    /// Adds an op to the queue, folding it into earlier ops for the same to-do so the queue
    /// stays short: the last tick or edit wins, and removing an unsynced to-do erases it.
    public static func enqueue(_ op: TodoOp, into pending: [TodoOp]) -> [TodoOp] {
        var queue = pending
        switch op {
        case .add:
            queue.append(op)
        case .setDone(let id, _):
            queue.removeAll { if case .setDone(let other, _) = $0 { other == id } else { false } }
            queue.append(op)
        case .edit(let id, let text):
            if let index = queue.firstIndex(where: { if case .add = $0 { $0.target == id } else { false } }),
               case .add(let clientId, _, let day, let project) = queue[index] {
                queue[index] = .add(clientId: clientId, text: text, day: day, project: project)
            } else {
                queue.removeAll { if case .edit(let other, _) = $0 { other == id } else { false } }
                queue.append(op)
            }
        case .remove(let id):
            let unsynced = id.hasPrefix(localPrefix)
            queue.removeAll { $0.target == id }
            if !unsynced { queue.append(op) }
        }
        return queue
    }

    /// Once the server assigns an id to a local add, later ops address the real row.
    public static func remap(_ pending: [TodoOp], from local: String, to remote: String) -> [TodoOp] {
        pending.map { op in
            switch op {
            case .setDone(let id, let done) where id == local: .setDone(id: remote, done: done)
            case .edit(let id, let text) where id == local: .edit(id: remote, text: text)
            case .remove(let id) where id == local: .remove(id: remote)
            default: op
            }
        }
    }

    public static func apply(_ op: TodoOp, to items: [TodoItem], now: Double) -> [TodoItem] {
        var items = items
        switch op {
        case .add(let clientId, let text, let day, let project):
            let id = localPrefix + clientId
            guard !items.contains(where: { $0.id == id }) else { return items }
            items.append(TodoItem(id: id, text: text, day: day, order: now, project: project, createdAt: now, updatedAt: now))
        case .setDone(let id, let done):
            if let i = items.firstIndex(where: { $0.id == id }) {
                items[i].done = done; items[i].doneAt = done ? (items[i].doneAt ?? now) : nil; items[i].updatedAt = now
            }
        case .edit(let id, let text):
            if let i = items.firstIndex(where: { $0.id == id }) { items[i].text = text; items[i].updatedAt = now }
        case .remove(let id):
            items.removeAll { $0.id == id }
        }
        return items
    }

    /// What Home shows for `day`: open to-dos planned for it or earlier, then today's finished ones.
    public static func view(base: [TodoItem], pending: [TodoOp], day: String, doneSince: Double, now: Double) -> [TodoItem] {
        let items = pending.reduce(base) { apply($1, to: $0, now: now) }
        let open = items.filter { !$0.done && $0.day <= day }
            .sorted { $0.order != $1.order ? $0.order < $1.order : $0.createdAt < $1.createdAt }
        let done = items.filter { $0.done && ($0.doneAt ?? 0) >= doneSince }
            .sorted { ($0.doneAt ?? 0) < ($1.doneAt ?? 0) }
        return open + done
    }

    public static func clean(_ text: String) -> String? {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return clean.isEmpty ? nil : String(clean.prefix(500))
    }
}

/// The Convex side of to-dos (Maurice's `convex/todos.ts`).
public struct TodoRemote: Sendable {
    public let client: ConvexClient
    public init(client: ConvexClient) { self.client = client }

    private struct TodayArgs: Encodable, Sendable { let day: String; let doneSince: Double }
    private struct AddArgs: Encodable, Sendable { let text: String; let day: String; let clientId: String; let source = "burro"; let project: String? }
    private struct DoneArgs: Encodable, Sendable { let id: String; let done: Bool }
    private struct EditArgs: Encodable, Sendable { let id: String; let text: String }
    private struct IDArgs: Encodable, Sendable { let id: String }

    public func today(day: String, doneSince: Double) async throws -> [TodoItem] {
        try await client.query("todos:today", TodayArgs(day: day, doneSince: doneSince))
    }
    /// Returns the server id for an add.
    @discardableResult public func perform(_ op: TodoOp) async throws -> String? {
        switch op {
        case .add(let clientId, let text, let day, let project):
            return try await client.mutation("todos:add", AddArgs(text: text, day: day, clientId: clientId, project: project), as: String.self)
        case .setDone(let id, let done):
            _ = try await client.mutation("todos:setDone", DoneArgs(id: id, done: done), as: ConvexVoid.self)
        case .edit(let id, let text):
            _ = try await client.mutation("todos:edit", EditArgs(id: id, text: text), as: ConvexVoid.self)
        case .remove(let id):
            _ = try await client.mutation("todos:remove", IDArgs(id: id), as: ConvexVoid.self)
        }
        return nil
    }
}
