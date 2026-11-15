// The Orchestrator's runs log: one JSON object per line in `runs.jsonl` in its folder, for every
// model run Burro starts for it (a question you asked, or an automatic triage):
// {"at": seconds since 1970, "trigger", "model", "durationMs", "inputTokens", "outputTokens",
// "cacheReadTokens", "costUSD"}, the numbers taken from Claude Code's stream-json `result` line.
// Owner-only, appended under a lock, kept for 30 days and at most 2 MB (older lines are dropped
// when it is rewritten). Reads are tolerant: lines that don't parse are skipped, `at` may also be
// an ISO 8601 string, and missing numbers read as zero. The page shows today's count and cost.
import Foundation

public struct OrchestratorRun: Codable, Sendable, Equatable {
    public var at: Date
    /// "ask" for a question you typed; other writers use their own words ("triage", "morning").
    public var trigger: String
    public var model: String
    public var durationMs: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var costUSD: Double

    public init(at: Date, trigger: String, model: String, durationMs: Int = 0, inputTokens: Int = 0, outputTokens: Int = 0,
                cacheReadTokens: Int = 0, costUSD: Double = 0) {
        self.at = at; self.trigger = trigger; self.model = model; self.durationMs = durationMs; self.inputTokens = inputTokens
        self.outputTokens = outputTokens; self.cacheReadTokens = cacheReadTokens; self.costUSD = costUSD
    }

    /// The numbers in a stream-json (or json) `result` object; nil when it isn't one.
    public static func from(result object: [String: Any], at: Date, trigger: String, model: String) -> OrchestratorRun? {
        guard object["type"] as? String == "result" else { return nil }
        let usage = object["usage"] as? [String: Any] ?? [:]
        // Cache writes are input the model read for the first time.
        let input = int(usage["input_tokens"]) + int(usage["cache_creation_input_tokens"])
        return OrchestratorRun(at: at, trigger: trigger, model: model, durationMs: int(object["duration_ms"]), inputTokens: input,
                               outputTokens: int(usage["output_tokens"]), cacheReadTokens: int(usage["cache_read_input_tokens"]),
                               costUSD: double(object["total_cost_usd"]))
    }

    /// The numbers in the last `result` line of a whole json/stream-json output; nil when none.
    public static func from(output: String, at: Date, trigger: String, model: String) -> OrchestratorRun? {
        for line in output.split(whereSeparator: \.isNewline).reversed() where line.first == "{" {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let run = from(result: object, at: at, trigger: trigger, model: model) else { continue }
            return run
        }
        return nil
    }

    static func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return max(0, number.intValue) }
        if let text = value as? String, let number = Int(text) { return max(0, number) }
        return 0
    }
    static func double(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return max(0, number.doubleValue) }
        if let text = value as? String, let number = Double(text) { return max(0, number) }
        return 0
    }
}

public struct OrchestratorRuns: Sendable {
    public var url: URL
    public init(url: URL) { self.url = url }
    public static var standard: OrchestratorRuns { OrchestratorRuns(url: Orchestrator.runsURL) }
    public static let keep: TimeInterval = 30 * 86_400
    static let sizeLimit = 2 * 1024 * 1024

    /// Appends one run; drops lines older than 30 days (or beyond the size cap) when it rewrites.
    public func append(_ run: OrchestratorRun, now: Date = Date()) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(lock) }
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN) }
        let line = try Self.encode(run) + Data([0x0A])
        let existing = OrchestratorFileWriter.read(url, limit: Self.sizeLimit * 2)
        let runs = existing.map(Self.decode) ?? []
        let stale = runs.first.map { now.timeIntervalSince($0.at) >= Self.keep } ?? false
        if existing == nil || stale || (existing?.count ?? 0) + line.count > Self.sizeLimit {
            // Rewrite: keep what is recent and fits, then this run.
            var kept = runs.filter { now.timeIntervalSince($0.at) < Self.keep }
            var data = Data()
            while true {
                data = Data()
                for run in kept { data += try Self.encode(run) + Data([0x0A]) }
                if data.count + line.count <= Self.sizeLimit || kept.isEmpty { break }
                kept.removeFirst(max(1, kept.count / 4))
            }
            try OrchestratorFileWriter.write(data + line, to: url)
            return
        }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        fchmod(fd, 0o600)
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
        guard written == line.count else { throw CocoaError(.fileWriteUnknown) }
    }

    public func load() -> [OrchestratorRun] {
        OrchestratorFileWriter.read(url, limit: Self.sizeLimit * 2).map(Self.decode) ?? []
    }

    /// Runs since the start of `now`'s local day, oldest first.
    public func today(now: Date = Date(), calendar: Calendar = .current) -> [OrchestratorRun] {
        let start = calendar.startOfDay(for: now)
        return load().filter { $0.at >= start && $0.at <= now.addingTimeInterval(60) }
    }

    /// The latest runs, newest first.
    public func recent(_ limit: Int = 30) -> [OrchestratorRun] {
        Array(load().suffix(limit).reversed())
    }

    static func encode(_ run: OrchestratorRun) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(run)
    }

    static func decode(_ data: Data) -> [OrchestratorRun] {
        let iso = ISO8601DateFormatter()
        let isoFraction = ISO8601DateFormatter()
        isoFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return data.split(separator: 0x0A).compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return nil }
            let at: Date
            if let seconds = object["at"] as? NSNumber, !(object["at"] is Bool) {
                at = Date(timeIntervalSince1970: seconds.doubleValue)
            } else if let text = object["at"] as? String, let date = iso.date(from: text) ?? isoFraction.date(from: text) {
                at = date
            } else {
                return nil
            }
            return OrchestratorRun(at: at, trigger: object["trigger"] as? String ?? "run", model: object["model"] as? String ?? "",
                                   durationMs: OrchestratorRun.int(object["durationMs"]), inputTokens: OrchestratorRun.int(object["inputTokens"]),
                                   outputTokens: OrchestratorRun.int(object["outputTokens"]),
                                   cacheReadTokens: OrchestratorRun.int(object["cacheReadTokens"]), costUSD: OrchestratorRun.double(object["costUSD"]))
        }
    }
}
