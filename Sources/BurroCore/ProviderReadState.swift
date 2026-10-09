// Mirror provider-owned unread markers; Burro never writes or acknowledges them.
import Foundation
import CryptoKit

public struct ProviderReadState: Sendable {
    public var codexUnread: Set<String> = []
    public var claudeUnread: Set<String> = []
    public var warnings: [String] = []
    public static let empty = Self()

    public func applying(to session: AgentSession) -> AgentSession {
        var value = session
        let unread: Bool
        switch session.provider {
        case .codex: unread = codexUnread.contains(String(session.id.split(separator: ":").last ?? ""))
        case .claude:
            let ids = [session.claudeDesktopSessionID, session.claudeBridgeSessionID].compactMap { $0 }
            // A remote local_ ID belongs to another installation; only its bridge ID is shared.
            unread = ids.contains { claudeUnread.contains($0) && (session.remote == nil || !$0.hasPrefix("local_")) }
        }
        value.hasUnreadResult = unread && session.turnCompleted == true && session.isSubagent != true
        return value
    }
    static func codexIdentity(account: String, user: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["chatgpt", account, user], options: .withoutEscapingSlashes)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func codexIDs(data: Data, identity: String?) throws -> Set<String> {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = root["electron-thread-read-state-v1"] as? [String: Any],
              state["version"] as? Int == 1,
              let identities = state["unreadByIdentity"] as? [String: [String: [String]]] else {
            throw CocoaError(.coderReadCorrupt)
        }
        // Never union accounts or revive the legacy migration snapshot.
        let selected = identity ?? (identities.count == 1 ? identities.keys.first : nil)
        guard let selected, let hosts = identities[selected] else { throw CocoaError(.coderValueNotFound) }
        return Set(hosts.values.flatMap { $0 }.filter { UUID(uuidString: $0) != nil })
    }
    static func claudeIDs(data: Data) throws -> Set<String> {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["version"] as? Int == 0,
              let state = root["state"] as? [String: Any], let ids = state["unreadIds"] as? [String] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return Set(ids + (state["explicitUnreadIds"] as? [String] ?? []))
    }
    public static func read(home: String) -> Self {
        let root = URL(fileURLWithPath: home), fm = FileManager.default
        var result = Self()
        let codex = root.appendingPathComponent(".codex")
        let stateURL = codex.appendingPathComponent(".codex-global-state.json")
        if fm.fileExists(atPath: stateURL.path) {
            do {
                // Creator IDs are non-secret identity metadata. Prefer the newest attributed
                // chat, because old accounts remain in the persisted read-state dictionary.
                let dbURL = try fm.contentsOfDirectory(at: codex, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
                    .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }.first
                var identity: String?
                if let dbURL, let db = try? SQLiteReader(path: dbURL.path),
                   let row = try? db.rows("SELECT creator_account_id,creator_user_id FROM threads WHERE creator_account_id IS NOT NULL AND creator_user_id IS NOT NULL ORDER BY created_at DESC LIMIT 1").first,
                   let account = row["creator_account_id"], let user = row["creator_user_id"] {
                    identity = codexIdentity(account: account, user: user)
                }
                result.codexUnread = try codexIDs(data: Data(ChromiumReadState.read(stateURL)), identity: identity)
            } catch { result.warnings.append("Codex unread status could not be read; Done badges may be missing.") }
        }
        let claude = root.appendingPathComponent("Library/Application Support/Claude/Local Storage/leveldb")
        if fm.fileExists(atPath: claude.appendingPathComponent("CURRENT").path) {
            do {
                if let data = try ChromiumReadState.value(directory: claude, key: "epitaxy-unread-v1") {
                    result.claudeUnread = try claudeIDs(data: data)
                }
            } catch { result.warnings.append("Claude unread status could not be read; Done badges may be missing.") }
        }
        return result
    }

    static func claudeCompletedSessions(home: String) -> Set<String> {
        let root = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        if let result = AgentLogWorker.shared.exchange([], completed: root.path)?.completed, !result.partial {
            return Set(result.ids)
        }
        return autoreleasepool { swiftClaudeCompletedSessions(root: root) }
    }
    static func swiftClaudeCompletedSessions(root: URL) -> Set<String> {
        let fm = FileManager.default
        var result = Set<String>()
        // Exactly two account directories; never walk transcripts or arbitrary user paths.
        for account in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                for file in (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)) ?? []
                    where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1024 * 1024,
                          let data = try? Data(contentsOf: file), let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          (record["completedTurns"] as? Int ?? 0) > 0, record["isArchived"] as? Bool != true,
                          let id = record["sessionId"] as? String else { continue }
                    result.insert(id)
                }
            }
        }
        return result
    }
}
