// Provider metadata is indexed in Rust; native lock/process checks remain live.
import Foundation

struct CodexCatalog: Decodable, Sendable, Equatable {
    let threads: [[String: String]]
    let roots: [String]
    let attachments: [[String: String]]

    static func swiftRead(_ path: String) throws -> Self {
        let db = try SQLiteReader(path: path)
        let columns = Set(try db.rows("PRAGMA table_info(threads)").compactMap { $0["name"] })
        let pinned = columns.contains("is_pinned") ? "is_pinned" : "0 AS is_pinned"
        let name = columns.contains("name") ? "name" : "NULL AS name"
        let source = columns.contains("source") ? "source" : "NULL AS source"
        let threads = try db.rows("SELECT id,cwd,title,updated_at,rollout_path,\(pinned),\(name),\(source) FROM threads WHERE archived=0 ORDER BY updated_at DESC")
        let tables = Set(try db.rows("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"] })
        let roots = tables.contains("project_roots") ? try db.rows("SELECT path FROM project_roots").compactMap { $0["path"] } : []
        let attachments = tables.contains("thread_attachments") ? try db.rows("SELECT thread_id,identity_key,payload FROM thread_attachments WHERE attachment_type='worktree'") : []
        return Self(threads: threads, roots: roots, attachments: attachments)
    }

    func filtered(_ scope: CodexCatalogScope?) -> Self {
        guard let scope else { return self }
        var byID: [String: [String: String]] = [:]
        for row in threads { if let id = row["id"] { byID[id] = row } }
        var selected = Set(scope.ids)
        for row in threads {
            if let id = row["id"], row["is_pinned"] == "1" || (Int64(row["updated_at"] ?? "0") ?? 0) >= scope.since { selected.insert(id) }
        }
        var pending = Array(selected)
        while let id = pending.popLast() {
            if let row = byID[id], let parent = AgentParsing.codexParentID(source: row["source"]) {
                let raw = String(parent.dropFirst("codex:".count))
                if selected.insert(raw).inserted { pending.append(raw) }
            }
        }
        return Self(threads: threads.filter { $0["id"].map(selected.contains) == true }, roots: roots, attachments: attachments)
    }
}

struct CodexCatalogScope: Codable, Sendable, Equatable {
    let since: Int64
    let ids: [String]
}
struct CodexCatalogRequest: Encodable, Sendable {
    let path: String
    let revision: UInt64?
    let scope: CodexCatalogScope?
    init(path: String, revision: UInt64?, scope: CodexCatalogScope? = nil) {
        self.path = path; self.revision = revision; self.scope = scope
    }
}
struct CodexCatalogBatch: Decodable, Sendable {
    let revision: UInt64
    let snapshot: CodexCatalog?
    let delta: CodexCatalogDelta?
    let queried: Bool
}

struct CodexCatalogDelta: Decodable, Sendable {
    let baseRevision: UInt64
    let threads: [[String: String]]
    let order: [String]
    let roots: [String]
    let attachments: [[String: String]]

    var withinLimits: Bool {
        order.count <= 20_000 && threads.count <= order.count
            && roots.count <= 20_000 && attachments.count <= 20_000
    }
    func applying(to previous: CodexCatalog) -> CodexCatalog? {
        guard withinLimits else { return nil }
        var rows: [String: [String: String]] = [:]
        for row in previous.threads {
            guard let id = row["id"], !id.isEmpty, rows.updateValue(row, forKey: id) == nil else { return nil }
        }
        let ids = Set(order)
        guard ids.count == order.count else { return nil }
        var updated: Set<String> = []
        for row in threads {
            guard let id = row["id"], !id.isEmpty, ids.contains(id), updated.insert(id).inserted else { return nil }
            rows[id] = row
        }
        var result: [[String: String]] = []
        result.reserveCapacity(order.count)
        for id in order {
            guard let row = rows[id] else { return nil }
            result.append(row)
        }
        return CodexCatalog(threads: result, roots: roots, attachments: attachments)
    }
}

// This cache lives for one native snapshot only. Repeated session/process paths
// resolve once, while the next refresh still sees moved folders and symlinks.
struct SnapshotPaths {
    private var values: [String: String] = [:]
    mutating func canonical(_ path: String) -> String {
        if let value = values[path] { return value }
        let value = Paths.canonical(path); values[path] = value
        return value
    }
}
