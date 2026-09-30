import Foundation

public struct ChatEdits: Codable, Sendable, Equatable {
    public var hasEdits: Bool
    public var added: Int
    public var removed: Int
    public var commit: ChatCommit? = nil
    public var exact: Bool
}

public struct ChatCommit: Codable, Sendable, Equatable {
    public var sha: String
    public var onRemote: Bool
}

/// Cache derived counts by log modification time; transcript contents never leave this host.
final class ChatEditReader: @unchecked Sendable {
    static let shared = ChatEditReader()
    private let lock = NSLock()
    private var cache: [String: (String, ChatEdits)] = [:]
    func read(_ paths: [String]) -> [String: ChatEdits] {
        lock.lock(); defer { lock.unlock() }
        var stamps: [String: String] = [:]
        for path in Set(paths) where !path.isEmpty {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            stamps[path] = "\(attributes?[.size] ?? 0):\(attributes?[.modificationDate] ?? Date.distantPast):\(Int(Date().timeIntervalSince1970 / 60))"
        }
        let changed = stamps.keys.filter { cache[$0]?.0 != stamps[$0] }
        if !changed.isEmpty, let input = try? JSONEncoder().encode(changed) {
            let result = CommandRunner().run("/usr/bin/env", ["python3", RemoteAgentMonitor.probeURL.path, "--edit-stats"], timeout: 5, input: input)
            if result.succeeded, let decoded = try? JSONDecoder().decode([String: ChatEdits].self, from: Data(result.output.utf8)) {
                for (path, edits) in decoded { cache[path] = (stamps[path] ?? "", edits) }
            }
        }
        return Dictionary(uniqueKeysWithValues: stamps.keys.compactMap { path in
            guard let entry = cache[path], entry.0 == stamps[path] else { return nil }
            return (path, entry.1)
        })
    }
}
