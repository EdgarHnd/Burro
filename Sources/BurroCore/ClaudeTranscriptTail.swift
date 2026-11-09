// The model and reasoning effort a live Claude Code chat last ran with. Claude records both on each
// reply in the chat's transcript, so this reads only the transcript's last 64 KB, and reads it again
// only when the file has grown. Read-only.
import Foundation

public final class ClaudeTranscriptTail: @unchecked Sendable {
    public static let shared = ClaudeTranscriptTail()
    private let lock = NSLock()
    private var cache: [String: (size: UInt64, model: String?, effort: String?)] = [:]

    public func modelAndEffort(home: String, cwd: String, sessionID: String) -> (model: String?, effort: String?) {
        guard UUID(uuidString: sessionID) != nil else { return (nil, nil) }
        let path = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
            .appendingPathComponent(Self.projectFolder(cwd)).appendingPathComponent(sessionID + ".jsonl").path
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64 else { return (nil, nil) }
        lock.lock()
        if let hit = cache[path], hit.size == size { lock.unlock(); return (hit.model, hit.effort) }
        lock.unlock()
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, nil) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        let found = (model: Self.last("model", in: text), effort: Self.last("effort", in: text))
        lock.lock()
        if cache.count > 200 { cache.removeAll() }
        cache[path] = (size, found.model, found.effort)
        lock.unlock()
        return found
    }

    /// Claude Code names a project's folder after its path, with every other character a dash.
    static func projectFolder(_ cwd: String) -> String {
        String(cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
    }

    /// The last `"key":"value"` written as JSON (escaped copies inside strings don't match).
    static func last(_ key: String, in text: String) -> String? {
        guard let range = text.range(of: "\"\(key)\":\"", options: .backwards) else { return nil }
        let value = text[range.upperBound...].prefix { $0 != "\"" }
        guard !value.isEmpty, value.count <= 64, value.allSatisfy({ $0.isLetter || $0.isNumber || "-._".contains($0) }) else { return nil }
        return String(value)
    }
}
