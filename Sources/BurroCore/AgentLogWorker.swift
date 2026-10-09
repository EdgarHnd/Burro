// A supervised Rust child processes Codex and Claude lifecycle evidence, never retaining transcript bodies.
import Foundation
import Darwin

enum CodexEventState: String, Codable, Sendable {
    case working, idle, waiting
    var agentState: AgentState {
        switch self { case .working: .working; case .idle: .idle; case .waiting: .waiting }
    }
}

struct CodexLogEvidence: Codable, Sendable, Equatable {
    var readable: Bool
    var modified: Double?
    var last: CodexEventState?
    var completed: Bool

    func state(held: Int32, now: Date) -> AgentState {
        if held < 0 || !readable { return .unknown }
        let age = modified.map { now.timeIntervalSince1970 - $0 }
        if held == 1 {
            if let last { return last.agentState }
            return age.map { $0 >= 0 && $0 < SessionStatusPolicy.workingSeconds } == true ? .working : .unknown
        }
        if last == .idle { return .inactive }
        return age.map { $0 >= 0 && $0 < SessionStatusPolicy.recentSeconds } == true ? .recent : .inactive
    }

    static let unavailable = Self(readable: false, modified: nil, last: nil, completed: false)

    // The existing Swift parser remains the recovery path and parity oracle.
    static func swiftRead(_ path: String) -> Self {
        guard path.hasPrefix("/"), path.utf8.count <= 16 * 1024 else { return .unavailable }
        let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return .unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { return .unavailable }
        do {
            try handle.seek(toOffset: UInt64(max(0, before.st_size - 512 * 1024)))
            let bytes = try handle.read(upToCount: 512 * 1024) ?? Data()
            let tail = String(decoding: bytes, as: UTF8.self)
            let event = AgentParsing.codexEvent(tail: tail)
            var after = stat()
            guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { return .unavailable }
            return Self(readable: true,
                        modified: Double(before.st_mtimespec.tv_sec) + Double(before.st_mtimespec.tv_nsec) / 1e9,
                        last: event?.0, completed: event?.1 ?? false)
        } catch { return .unavailable }
    }
}

struct ClaudeLogSession: Encodable, Sendable {
    let sessionID: String
    let started: Double
    enum CodingKeys: String, CodingKey { case sessionID = "sessionId", started }
}
struct ClaudeLogRequest: Encodable, Sendable {
    let root: String
    let sessions: [ClaudeLogSession]
    let now: Double
}
enum ClaudeWorkerState: String, Decodable, Sendable {
    case working, unknown
    var agentState: AgentState { self == .working ? .working : .unknown }
}
struct ClaudeLogBatch: Decodable, Sendable {
    let results: [ClaudeWorkerState?]
    let reads: Int
    let cacheHits: Int
}
struct ClaudeCompletedBatch: Decodable, Sendable {
    let ids: [String]
    let reads, cacheHits: Int
    let partial: Bool
}
struct CodexLogBatch: Decodable, Sendable {
    let version: Int
    let id: String
    let results: [CodexLogEvidence]
    let reads: Int
    let cacheHits: Int
    let claude: ClaudeLogBatch?
    let usage: UsageLogBatch?
    let completed: ClaudeCompletedBatch?
}

// All child state and pipe I/O are serialized by lock. Callers already run on
// background scan tasks. No main-actor work or global signal policy is changed.
final class AgentLogWorker: @unchecked Sendable {
    static let shared = AgentLogWorker(executable: bundledExecutable())
    // History scans have a larger budget and must never hold up live status requests.
    static let usage = AgentLogWorker(executable: bundledExecutable(), timeout: 22)
    private let lock = NSLock()
    private let executable: URL?
    private let timeout: TimeInterval
    private let retryDelay: TimeInterval
    private var retryAfter: TimeInterval = 0
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?

    init(executable: URL?, timeout: TimeInterval = 2, retryDelay: TimeInterval = 30) {
        self.executable = executable; self.timeout = timeout; self.retryDelay = retryDelay
    }
    deinit { stopLocked() }

    static func bundledExecutable() -> URL? {
        if let main = Bundle.main.executableURL {
            let sibling = main.deletingLastPathComponent().appendingPathComponent("burro-log-worker")
            if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        #if DEBUG
        // Development/test builds only. Packaged release apps use their signed sibling.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let built = root.appendingPathComponent(".build/rust/release/burro-log-worker")
        if FileManager.default.isExecutableFile(atPath: built.path) { return built }
        #endif
        return nil
    }

    func read(_ paths: [String]) -> [CodexLogEvidence] {
        if paths.isEmpty { return [] }
        var results: [CodexLogEvidence] = []
        for start in stride(from: 0, to: paths.count, by: 2048) {
            let batch = Array(paths[start..<min(start + 2048, paths.count)])
            results += exchange(batch)?.results ?? batch.map(CodexLogEvidence.swiftRead)
        }
        return results
    }

    func readClaude(root: String, sessions: [ClaudeLogSession], now: Date) -> [AgentState?]? {
        if sessions.isEmpty { return [] }
        let request = ClaudeLogRequest(root: root, sessions: sessions, now: now.timeIntervalSince1970)
        return exchange([], claude: request)?.claude?.results.map { $0?.agentState }
    }

    func exchange(_ paths: [String], claude: ClaudeLogRequest? = nil, usage: UsageLogRequest? = nil, completed: String? = nil) -> CodexLogBatch? {
        lock.lock(); defer { lock.unlock() }
        guard (!paths.isEmpty || claude != nil || usage != nil || completed != nil), paths.count <= 2048,
              (usage == nil || (paths.isEmpty && claude == nil && completed == nil)), (claude?.sessions.count ?? 0) <= 256, executable != nil,
              ProcessInfo.processInfo.systemUptime >= retryAfter else { return nil }
        do {
            struct Request: Encodable { let version = 3; let id: String; let paths: [String]; let claude: ClaudeLogRequest?; let usage: UsageLogRequest?; let completed: String? }
            let id = UUID().uuidString
            var request = try JSONEncoder().encode(Request(id: id, paths: paths, claude: claude, usage: usage, completed: completed)); request.append(10)
            guard request.count <= 2 * 1024 * 1024 else { return nil }
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            try startLocked()
            guard let input, let output else { throw WorkerError.channel }
            try write(request, to: input.fileDescriptor, deadline: deadline)
            let response = try readLine(from: output.fileDescriptor, deadline: deadline)
            let batch = try JSONDecoder().decode(CodexLogBatch.self, from: response)
            guard batch.version == 3, batch.id == id, batch.results.count == paths.count,
                  (0...paths.count).contains(batch.reads), (0...paths.count).contains(batch.cacheHits),
                  batch.reads + batch.cacheHits <= paths.count,
                  batch.results.allSatisfy({ evidence in
                      if !evidence.readable { return evidence.modified == nil && evidence.last == nil && !evidence.completed }
                      return evidence.modified?.isFinite == true && (!evidence.completed || evidence.last == .idle)
                  }) else { throw WorkerError.protocolMismatch }
            if let claude {
                guard let evidence = batch.claude, evidence.results.count == claude.sessions.count,
                      (0...(claude.sessions.count * 256)).contains(evidence.reads),
                      (0...(claude.sessions.count * 256)).contains(evidence.cacheHits),
                      evidence.reads + evidence.cacheHits <= claude.sessions.count * 256 else { throw WorkerError.protocolMismatch }
            } else if batch.claude != nil { throw WorkerError.protocolMismatch }
            if let usage {
                guard let result = batch.usage, result.valid(for: usage) else { throw WorkerError.protocolMismatch }
            } else if batch.usage != nil { throw WorkerError.protocolMismatch }
            if completed != nil {
                guard let result = batch.completed, result.ids.count <= 2048,
                      result.ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
                      Set(result.ids).count == result.ids.count,
                      (0...8192).contains(result.reads), (0...8192).contains(result.cacheHits),
                      result.reads + result.cacheHits <= 8192 else { throw WorkerError.protocolMismatch }
            } else if batch.completed != nil { throw WorkerError.protocolMismatch }
            return batch
        } catch {
            stopLocked()
            retryAfter = ProcessInfo.processInfo.systemUptime + retryDelay
            return nil
        }
    }

    func stop() { lock.lock(); defer { lock.unlock() }; stopLocked() }

    private enum WorkerError: Error { case channel, timedOut, protocolMismatch }

    private func startLocked() throws {
        if process?.isRunning == true { return }
        stopLocked()
        guard let executable else { throw WorkerError.channel }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable; child.arguments = ["--stdio-v3"]
        child.currentDirectoryURL = URL(fileURLWithPath: "/")
        child.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        try child.run()
        try? stdin.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close()
        process = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        for handle in [input!, output!] {
            let fd = handle.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) >= 0,
                  fcntl(fd, F_SETNOSIGPIPE, 1) >= 0 else { throw WorkerError.channel }
        }
    }

    private func stopLocked() {
        try? input?.close(); try? output?.close(); input = nil; output = nil
        if let process, process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 0.1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(5_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process = nil
    }

    private func ready(_ fd: Int32, event: Int16, deadline: TimeInterval) throws {
        while true {
            let left = deadline - ProcessInfo.processInfo.systemUptime
            guard left > 0 else { throw WorkerError.timedOut }
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(left * 1000 + 1, 2000)))
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw WorkerError.timedOut }
            guard descriptor.revents & event != 0 else { throw WorkerError.channel }
            return
        }
    }

    private func write(_ data: Data, to fd: Int32, deadline: TimeInterval) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try ready(fd, event: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw WorkerError.channel }
                offset += count
            }
        }
    }

    private func readLine(from fd: Int32, deadline: TimeInterval) throws -> Data {
        var response = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while response.count <= 512 * 1024 {
            try ready(fd, event: Int16(POLLIN), deadline: deadline)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw WorkerError.channel }
            response.append(contentsOf: buffer.prefix(count))
            guard response.count <= 512 * 1024 else { throw WorkerError.protocolMismatch }
            if let newline = response.firstIndex(of: 10) {
                guard newline == response.count - 1 else { throw WorkerError.protocolMismatch }
                return response
            }
        }
        throw WorkerError.protocolMismatch
    }
}
