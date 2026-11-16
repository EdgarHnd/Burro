// "Cost so far" for one chat on this Mac: the chat's token counts from its own transcript, valued at
// the same API list prices the Usage page uses (`ReferenceTokenPrices`), never a bill. Only token
// metadata is read (lines carrying "usage" or Codex's token counts); conversation text is skipped
// and nothing is kept but the counters. The file is found by the chat's id (Claude: one folder down
// in its projects folder; Codex: the day folders around when the chat started, then the archive)
// and read incrementally: each call parses only what was appended since the last one, so a working
// chat costs a few bytes per refresh. The answer is nil ("—" on the page) when the file can't be
// found, is over 64 MB, or holds a model without a known price. Call off the main thread.
import Foundation

/// The running token tally of one transcript.
public struct ChatCostTally: Sendable {
    var records: [String: LocalUsageRecord] = [:]
    var codexModel = "Unknown model"
    var codexPrevious: Double?
    public let provider: AgentProvider
    public init(provider: AgentProvider) { self.provider = provider }

    /// Adds the usage records in `data`, which must hold whole lines.
    public mutating func consume(_ data: Data) {
        let marker = Data((provider == .claude ? "\"usage\"" : "token_count").utf8), context = Data("turn_context".utf8)
        for line in data.split(separator: 10) {
            guard line.range(of: marker) != nil || (provider == .codex && line.range(of: context) != nil) else { continue }
            guard line.count <= UsageDecoding.maxBytes, let object = try? UsageDecoding.object(Data(line)) else { continue }
            let record = provider == .claude ? LocalUsageScanner.claudeRecord(object)
                : LocalUsageScanner.codexRecord(object, model: &codexModel, previousTotal: &codexPrevious)
            guard let record, records.count < 100_000 else { continue }
            if records[record.key].map({ $0.total <= record.total }) ?? true { records[record.key] = record }
        }
    }

    /// Dollars at list prices, or nil when there is nothing to price or a model has no known price.
    public var dollars: Double? {
        guard !records.isEmpty else { return nil }
        var sum = 0.0
        for record in records.values {
            guard let value = record.apiValue else { return nil }
            sum += value
        }
        return sum
    }
}

public enum ChatCost {
    static let fileLimit = 64 * 1024 * 1024

    /// "$3.84", "<$0.01", or "—".
    public static func label(_ dollars: Double?) -> String {
        guard let dollars, dollars.isFinite, dollars >= 0 else { return "—" }
        if dollars > 0 && dollars < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", dollars)
    }

    /// The chat's transcript on this Mac. `root` is the provider's folder (`~/.claude` or
    /// `~/.codex`, or a profile's); `startedAt` narrows the Codex search to its day folders.
    public static func transcript(provider: AgentProvider, id: String, root: URL, startedAt: Date?, calendar: Calendar = .current) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        let files = FileManager.default
        func regular(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
        if provider == .claude {
            let projects = root.appendingPathComponent("projects")
            guard let folders = try? files.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
            for folder in folders.prefix(5000) {
                let file = folder.appendingPathComponent("\(id).jsonl")
                if regular(file) { return file }
            }
            return nil
        }
        let suffix = "-\(id).jsonl"
        func search(_ folder: URL) -> URL? {
            guard let names = try? files.contentsOfDirectory(atPath: folder.path) else { return nil }
            return names.prefix(20_000).first { $0.hasSuffix(suffix) }.map { folder.appendingPathComponent($0) }.flatMap { regular($0) ? $0 : nil }
        }
        if let startedAt {
            for offset in [0, -1, 1] {
                guard let day = calendar.date(byAdding: .day, value: offset, to: startedAt) else { continue }
                let parts = calendar.dateComponents([.year, .month, .day], from: day)
                guard let year = parts.year, let month = parts.month, let date = parts.day else { continue }
                let folder = root.appendingPathComponent("sessions").appendingPathComponent(String(format: "%04d/%02d/%02d", year, month, date))
                if let found = search(folder) { return found }
            }
        }
        return search(root.appendingPathComponent("archived_sessions"))
    }

    /// Reads transcripts incrementally and remembers each one's tally. Thread-safe.
    public final class Reader: @unchecked Sendable {
        public static let shared = Reader()
        private struct Entry { var offset: UInt64; var tally: ChatCostTally; var file: UInt64 }
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        private var locations: [String: URL] = [:]
        public init() {}

        /// The chat's cost so far, or nil when it can't be computed (see the file header).
        public func dollars(provider: AgentProvider, id: String, root: URL, startedAt: Date?) -> Double? {
            let key = "\(provider.rawValue):\(id)"
            lock.lock(); var url = locations[key]; lock.unlock()
            if url.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
                url = ChatCost.transcript(provider: provider, id: id, root: root, startedAt: startedAt)
                lock.lock(); locations[key] = url; if locations.count > 512 { locations = [:] }; lock.unlock()
            }
            guard let url else { return nil }
            return dollars(file: url, provider: provider)
        }

        /// The tally of the file at `url`, reading only what was added since the last call.
        public func dollars(file url: URL, provider: AgentProvider) -> Double? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value, size <= UInt64(ChatCost.fileLimit) else { return nil }
            let file = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            lock.lock()
            var entry = entries[url.path] ?? Entry(offset: 0, tally: ChatCostTally(provider: provider), file: file)
            lock.unlock()
            // A replaced or shortened file starts over.
            if entry.file != file || size < entry.offset || entry.tally.provider != provider {
                entry = Entry(offset: 0, tally: ChatCostTally(provider: provider), file: file)
            }
            if size > entry.offset {
                do {
                    try handle.seek(toOffset: entry.offset)
                    let data = try handle.read(upToCount: Int(size - entry.offset)) ?? Data()
                    // Only whole lines; a line still being written is read next time.
                    if let last = data.lastIndex(of: 10) {
                        let whole = data[data.startIndex...last]
                        entry.tally.consume(Data(whole))
                        entry.offset += UInt64(whole.count)
                    }
                } catch { return nil }
            }
            lock.lock()
            entries[url.path] = entry
            if entries.count > 64 { entries = [url.path: entry] }
            lock.unlock()
            return entry.tally.dollars
        }
    }
}
