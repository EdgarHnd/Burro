// A short-lived client for Codex's shared app-server daemon. `codex app-server proxy` relays
// stdio to the daemon's control socket, which speaks JSON-RPC over WebSocket; this file
// implements just enough of RFC 6455 (masked text frames out, plain frames in, ping/pong) to
// call a few methods and disconnect. Work started here keeps running in the daemon.
import Darwin
import Foundation

enum WebSocketFrames {
    static func handshake(key: String) -> Data {
        Data("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8)
    }
    /// A client frame: FIN set, masked as RFC 6455 requires of clients.
    static func encode(_ payload: Data, opcode: UInt8 = 0x1, mask: [UInt8]) -> Data {
        var frame = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 { frame.append(0x80 | UInt8(count)) }
        else if count <= 0xFFFF { frame.append(0x80 | 126); frame.append(contentsOf: [UInt8(count >> 8), UInt8(count & 0xFF)]) }
        else { frame.append(0x80 | 127); frame.append(contentsOf: (0..<8).reversed().map { UInt8((UInt64(count) >> (UInt64($0) * 8)) & 0xFF) }) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return frame
    }
    struct Frame: Equatable { var fin: Bool; var opcode: UInt8; var payload: Data }
    /// Removes and returns one complete frame from the front of `buffer`, or nil if incomplete.
    static func decode(_ buffer: inout Data, limit: Int = 32 * 1024 * 1024) throws -> Frame? {
        let bytes = [UInt8](buffer.prefix(14))
        guard bytes.count >= 2 else { return nil }
        let masked = bytes[1] & 0x80 != 0
        var length = Int(bytes[1] & 0x7F), offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3]); offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            var value: UInt64 = 0
            for byte in bytes[2..<10] { value = value << 8 | UInt64(byte) }
            guard value <= UInt64(limit) else { throw LaunchError.failed("Codex sent an oversized message.") }
            length = Int(value); offset = 10
        }
        let maskBytes: [UInt8]
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            maskBytes = Array(bytes[offset..<offset + 4]); offset += 4
        } else { maskBytes = [] }
        guard buffer.count >= offset + length else { return nil }
        let start = buffer.startIndex
        var payload = buffer.subdata(in: (start + offset)..<(start + offset + length))
        if masked { payload = Data(payload.enumerated().map { $0.element ^ maskBytes[$0.offset % 4] }) }
        buffer.removeFirst(offset + length)
        return Frame(fin: bytes[0] & 0x80 != 0, opcode: bytes[0] & 0x0F, payload: payload)
    }
}

final class CodexAppServer {
    private let process = Process()
    private let toServer = Pipe()
    private let fromServer = Pipe()
    private var buffer = Data()
    private var nextID = 0
    private var timeout: TimeInterval

    /// Connects to the daemon, starting it first if it isn't running.
    static func connect(executable: String, timeout: TimeInterval = 30) throws -> CodexAppServer {
        if let server = try? CodexAppServer(executable: executable, timeout: 8) { server.timeout = timeout; return server }
        try LaunchShell.run(executable, ["app-server", "daemon", "start"], timeout: 30)
        return try CodexAppServer(executable: executable, timeout: timeout)
    }

    private init(executable: String, timeout: TimeInterval) throws {
        self.timeout = timeout
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "proxy"]
        process.standardInput = toServer
        process.standardOutput = fromServer
        process.standardError = FileHandle.nullDevice
        process.environment = LaunchShell.environment()
        try process.run()
        do {
            try write(WebSocketFrames.handshake(key: Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()))
            try readHandshake()
            _ = try request("initialize", ["clientInfo": ["name": "burro", "title": "Burro", "version": "1"]])
            try send(["method": "initialized"])
        } catch { close(); throw error }
    }

    func close() {
        try? toServer.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    /// Sends one JSON-RPC request and waits for its response, skipping notifications and any
    /// server-initiated requests (approvals belong to the Codex app, not to this connection).
    func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        nextID += 1
        let id = nextID
        try send(["id": id, "method": method, "params": params])
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            let message = try readMessage(until: deadline)
            guard message["method"] == nil, (message["id"] as? Int) == id else { continue }
            if let error = message["error"] as? [String: Any] {
                throw LaunchError.failed("Codex: " + ((error["message"] as? String) ?? "request failed"))
            }
            return message["result"] as? [String: Any] ?? [:]
        }
    }

    private func send(_ object: [String: Any]) throws {
        let payload = try JSONSerialization.data(withJSONObject: object)
        try write(WebSocketFrames.encode(payload, mask: (0..<4).map { _ in UInt8.random(in: 0...255) }))
    }
    private func write(_ data: Data) throws {
        do { try toServer.fileHandleForWriting.write(contentsOf: data) }
        catch { throw LaunchError.failed("Couldn't reach the Codex app server.") }
    }
    private func readHandshake() throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            try fill(until: deadline)
            if buffer.count > 16 * 1024 { throw LaunchError.failed("Codex's app server answered unexpectedly.") }
        }
        let end = buffer.range(of: Data("\r\n\r\n".utf8))!
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex..<end.upperBound)
        guard head.hasPrefix("HTTP/1.1 101") else { throw LaunchError.failed("Codex's app server refused the connection.") }
    }
    private func readMessage(until deadline: TimeInterval) throws -> [String: Any] {
        var text = Data()
        while true {
            guard let frame = try WebSocketFrames.decode(&buffer) else { try fill(until: deadline); continue }
            switch frame.opcode {
            case 0x9: try write(WebSocketFrames.encode(frame.payload, opcode: 0xA, mask: [1, 2, 3, 4]))
            case 0x8: throw LaunchError.failed("Codex's app server closed the connection.")
            case 0x1, 0x0:
                text.append(frame.payload)
                guard frame.fin else { continue }
                guard let object = try JSONSerialization.jsonObject(with: text) as? [String: Any] else { text = Data(); continue }
                return object
            default: continue
            }
        }
    }
    private func fill(until deadline: TimeInterval) throws {
        let fd = fromServer.fileHandleForReading.fileDescriptor
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw LaunchError.failed("Codex's app server didn't answer in time.") }
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&poller, 1, Int32(min(remaining, 5) * 1000))
        guard ready > 0 else { if ready < 0 && errno != EINTR { throw LaunchError.failed("Lost the Codex app server.") }; return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else { throw LaunchError.failed("Codex's app server isn't running.") }
        buffer.append(contentsOf: chunk[0..<count])
    }
}

/// Runs a tool through your login shell so agents get your normal PATH and environment.
enum LaunchShell {
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("GIT_") || key.hasPrefix("CLAUDE_CODE_") || key == "CLAUDECODE" || key.hasPrefix("CODEX_") {
            env.removeValue(forKey: key)
        }
        return env
    }
    struct Output { var code: Int32; var text: String }
    /// `zsh -lc 'cd -- "$1" && exec "${@:2}"' burro <folder> <tool> <args…>`: arguments stay
    /// positional, so nothing (prompts included) is ever parsed by the shell.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], folder: String = "/", timeout: TimeInterval) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", #"cd -- "$1" || exit 70; shift; exec "$@""#, "burro", folder, executable] + arguments
        process.environment = environment()
        // Output goes to a private file, not a pipe: a background session or daemon the tool
        // leaves running could hold a pipe open and stall the read.
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("burro-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let outputURL = folderURL.appendingPathComponent("output")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        process.standardOutput = handle; process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw LaunchError.failed("\(URL(fileURLWithPath: executable).lastPathComponent) didn't finish starting in time.")
        }
        let data = (try? FileHandle(forReadingFrom: outputURL).readToEnd()) ?? nil
        if process.terminationStatus == 70 { throw LaunchError.missingFolder }
        return Output(code: process.terminationStatus, text: String(decoding: (data ?? Data()).prefix(1024 * 1024), as: UTF8.self))
    }
}
