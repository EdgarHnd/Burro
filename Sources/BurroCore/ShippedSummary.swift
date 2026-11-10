// A few plain lines on what a shipped day's work actually was, per person, written by a small
// Claude model through your signed-in Claude Code CLI (`claude -p`, headless, no tools, no saved
// session). It only sees what the Shipped section already shows: pull request titles and area
// tags, authors, branch names, line counts and production status. No diffs, no code.
//
// One model call per change in the day's items: the summary is cached per repository and day
// under a key made from exactly what was sent, so a refresh that finds the same items reuses it,
// and past days are written once and kept.
import CryptoKit
import Foundation

public enum ShippedSummary {
    public static let model = "claude-haiku-5-5"
    public static let modelTitle = "Haiku 5.5"
    public static let effort = "low"
    /// Bump when the instructions or input format change, so cached summaries are rewritten.
    static let version = 2

    public struct Entry: Codable, Sendable, Equatable {
        public var key: String
        /// Empty for a day with nothing to summarise (kept so a backfill knows it read that day).
        public var text: String
        public var model: String
        public var createdAt: Date
        /// The day's items, for weekly and monthly reports. Nil in entries from before digests.
        public var digest: ShippedDigest?
        /// Written after the day (or week, month) was over, from all of it: never rewritten.
        public var final: Bool?
        public init(key: String, text: String, model: String, createdAt: Date, digest: ShippedDigest? = nil, final: Bool = false) {
            self.key = key; self.text = text; self.model = model; self.createdAt = createdAt; self.digest = digest; self.final = final
        }
        public var isFinal: Bool { final == true }
        /// Final and in today's format: an empty day, or a brief (older plain lines get rewritten).
        public var isSettled: Bool { isFinal && (text.isEmpty || ShippedBrief(json: text) != nil) }
    }

    public enum Failure: Error, Equatable, Sendable {
        case noClaude, signedOut, failed(String)
        /// A few words for the header card's footnote.
        public var short: String {
            switch self {
            case .noClaude: "Install Claude Code for a written summary"
            case .signedOut: "Sign in to Claude Code for a written summary"
            case .failed: "Couldn't write a summary"
            }
        }
        public var detail: String {
            switch self {
            case .noClaude: "Burro writes the summary with your Claude Code CLI (claude). It wasn't found in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin."
            case .signedOut: "Run claude in a terminal and sign in with /login; Burro uses that sign-in."
            case .failed(let message): message
            }
        }
    }

    // MARK: What the model sees

    /// The day as plain lines for the model, or nil when there's nothing to summarise. Only
    /// titles, areas, people, branch names, line counts and production status; stable ordering,
    /// no push counts or times, so the same work always reads the same (and hashes the same).
    /// Work still in progress is listed only for people who merged nothing: for everyone else the
    /// merges say what they did, and a new branch alone doesn't need a new summary.
    public static func input(_ day: ShippedDay, calendar: Calendar = .current) -> String? {
        ShippedDigest(day, calendar: calendar).input
    }

    static func statusWords(_ status: ShippedDay.Release.Status?) -> String {
        switch status {
        case .live: "live"
        case .succeeded: "succeeded"
        case .running: "still running"
        case .waiting: "waiting for approval"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case nil: "status unknown"
        }
    }

    static func stamp(_ day: Date, _ format: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: day)
    }

    /// Whether a day is over for good: half an hour after its midnight (late merges), as the
    /// Shipped section stops re-reading it then. A summary written after that never changes.
    public static func isClosed(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) ?? day
        return now >= end.addingTimeInterval(1800)
    }

    /// What a cached summary is filed under: one entry per repository and day.
    public static func cacheID(repository: String, day: Date, calendar: Calendar = .current) -> String {
        return repository + " " + stamp(calendar.startOfDay(for: day), "yyyy-MM-dd", calendar: calendar)
    }

    /// Changes whenever anything sent to the model changes (or the model or instructions do).
    public static func key(input: String) -> String {
        let material = "\(version)\n\(model)\n\(effort)\n\(instructions)\n\(input)"
        return SHA256.hash(data: Data(material.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// What Haiku is asked for a day: a brief (headline, tagged themes per person, production).
    public static var instructions: String { ShippedBrief.dayInstructions }

    // MARK: Asking Claude

    /// `claude -p` arguments: the small model at low effort, no tools, no MCP servers, no settings,
    /// hooks or CLAUDE.md, and nothing saved as a session. The input follows `--` so it is never a flag.
    public static func arguments(input: String, instructions: String = instructions) -> [String] {
        ["-p", "--output-format", "json", "--model", model, "--effort", effort,
         "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--setting-sources", "",
         "--system-prompt", instructions, "--", input]
    }

    /// Burro's own folder for the call (and the cache), so no project's CLAUDE.md is read.
    public static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Burro/Shipped", isDirectory: true)
    }

    /// Runs Claude once and returns the cleaned summary. Blocks for a few seconds: call it from a
    /// detached task.
    public static func generate(for day: ShippedDay, input: String, executable: String? = ClaudeLaunch.executable(),
                                folder: URL = folder) -> Result<String, Failure> {
        ask(input: input, shape: .day, names: Set(day.contributors.map(\.displayName)), production: !day.production.isEmpty,
            executable: executable, folder: folder).result
    }

    /// One `claude -p` call with these instructions: the brief it returns as JSON (only people in
    /// `names`; a production line only when `production`), and what Claude Code says it cost.
    static func ask(input: String, instructions: String = instructions, shape: ShippedBrief.Shape, names: Set<String>, production: Bool,
                    executable: String? = ClaudeLaunch.executable(), folder: URL = folder) -> (result: Result<String, Failure>, cost: Double?) {
        guard let executable else { return (.failure(.noClaude), nil) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let output = try LaunchShell.run(executable, arguments(input: input, instructions: instructions), folder: folder.path, timeout: 120)
            let result = parse(output.text, code: output.code).flatMap { text in
                ShippedBrief.parse(text, shape: shape, names: names, production: production).map { .success($0.json) }
                    ?? .failure(.failed("Claude's answer wasn't a summary Burro could read."))
            }
            return (result, cost(output.text))
        } catch LaunchError.failed {
            return (.failure(.failed("Claude took too long to answer.")), nil)
        } catch {
            return (.failure(.failed((error as? LocalizedError)?.errorDescription ?? "Claude didn't run.")), nil)
        }
    }

    /// `total_cost_usd` from Claude Code's JSON result.
    static func cost(_ output: String) -> Double? {
        for line in output.split(whereSeparator: \.isNewline).reversed() where line.first == "{" {
            if let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], object["type"] as? String == "result" {
                return object["total_cost_usd"] as? Double
            }
        }
        return nil
    }

    /// The `result` of `claude -p --output-format json`, or why there isn't one. Output and errors
    /// share one stream, so the JSON line is looked for among any warnings.
    static func parse(_ output: String, code: Int32) -> Result<String, Failure> {
        let object = output.split(whereSeparator: \.isNewline).reversed().lazy.compactMap { line -> [String: Any]? in
            guard line.first == "{" else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }.first { $0["type"] as? String == "result" }
        let message = (object?["result"] as? String) ?? output
        if let object, object["is_error"] as? Bool != true, let text = object["result"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .success(text)
        }
        let lower = message.lowercased()
        if lower.contains("/login") || lower.contains("not logged in") || lower.contains("invalid api key")
            || lower.contains("oauth token") || lower.contains("authentication") {
            return .failure(.signedOut)
        }
        let line = message.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        return .failure(.failed(line.map { "Claude: " + String($0.prefix(200)) } ?? "Claude exited with \(code)."))
    }

    /// Keeps the lines that start with someone from the day (or "Production:" when something went to
    /// production), joins wrapped lines back on, and strips any markdown. Nil when nothing usable is left.
    public static func clean(_ text: String, day: ShippedDay) -> String? {
        clean(text, names: Set(day.contributors.map(\.displayName)), production: !day.production.isEmpty)
    }

    static func clean(_ text: String, names: Set<String>, production: Bool) -> String? {
        var kept: [String] = []
        var keeping = false
        for raw in normalized(text).split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "-*•#>".contains(first) { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            guard !line.isEmpty else { continue }
            if let label = label(of: line) {
                keeping = names.contains(label) || (label == "Production" && production)
                if keeping { kept.append(line) }
            } else if keeping, let last = kept.popLast() {
                kept.append(last + " " + line)
            }
        }
        let result = kept.prefix(names.count + 1).joined(separator: "\n")
        return result.isEmpty ? nil : String(result.prefix(1200))
    }

    /// "Dante" for "Dante: …".
    static func label(of line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let label = line[..<colon].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.count <= 40, label.split(separator: " ").count <= 3 else { return nil }
        return label
    }

    /// Puts a "Production:" the model ran onto the end of someone's line back on its own line.
    public static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?<=\S)\s+(Production:)"#, with: "\n$1", options: .regularExpression)
    }

    /// A summary as (name, what they did) lines, for showing names apart from the text.
    public static func lines(_ text: String) -> [(label: String?, text: String)] {
        normalized(text).split(whereSeparator: \.isNewline).map { raw in
            let line = String(raw)
            guard let label = label(of: line), let colon = line.firstIndex(of: ":") else { return (nil, line) }
            return (label, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
    }
}

// MARK: Cache

/// Summaries kept on disk, one per repository and day (and week and month), so they show
/// instantly after a relaunch and a past day is only ever written once. Kept for good: a year of
/// days with their digests is about a megabyte.
public struct ShippedSummaryCache: Codable, Sendable, Equatable {
    public var entries: [String: ShippedSummary.Entry] = [:]
    public init(entries: [String: ShippedSummary.Entry] = [:]) { self.entries = entries }

    public static var url: URL { ShippedSummary.folder.appendingPathComponent("summaries.json") }

    /// The cached summary for this id when it was written from exactly this input.
    public func fresh(_ id: String, key: String) -> ShippedSummary.Entry? {
        guard let entry = entries[id], entry.key == key else { return nil }
        return entry
    }

    public mutating func store(_ entry: ShippedSummary.Entry, for id: String) {
        entries[id] = entry
    }

    /// Saves entries without losing anyone else's: reads the file, lays these over it (and keeps
    /// whichever copy of every other entry is newer than `known`'s), writes it back. The app and a
    /// backfill can both write while the other runs. Returns the merged cache.
    @discardableResult
    public static func save(_ updates: [String: ShippedSummary.Entry], known: ShippedSummaryCache? = nil, to url: URL = url) throws -> ShippedSummaryCache {
        var cache = read(from: url)
        for (id, entry) in known?.entries ?? [:] where (cache.entries[id]?.createdAt ?? .distantPast) < entry.createdAt { cache.entries[id] = entry }
        for (id, entry) in updates { cache.entries[id] = entry }
        try cache.write(to: url)
        return cache
    }

    public static func read(from url: URL = url) -> ShippedSummaryCache {
        guard let data = try? Data(contentsOf: url) else { return ShippedSummaryCache() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(ShippedSummaryCache.self, from: data)) ?? ShippedSummaryCache()
    }

    public func write(to url: URL = url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
