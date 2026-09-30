// Query only account metadata and quota over a short-lived Codex app-server stdio connection.
import Foundation
import Darwin

public enum CodexUsageReader {
    public static func executable(home: String = FileManager.default.homeDirectoryForCurrentUser.path, bundled: String? = nil) -> String? {
        let candidates = [bundled, home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          "/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex"]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public static func read(executable: String?, timeout: TimeInterval = 20, home: String? = nil) -> ProviderUsage {
        guard let executable else { return .failure(.codex, .notInstalled) }
        do {
            let rpc = try UsageRPC(executable: executable, timeout: timeout, home: home)
            defer { rpc.close() }
            _ = try rpc.request(id: 1, method: "initialize", params: ["clientInfo": ["name": "burro", "version": "0.6.0"]])
            try rpc.send(["method": "initialized"])
            var account = try UsageDecoding.object(rpc.request(id: 2, method: "account/read", params: ["refreshToken": false]))
            guard let initial = account["account"] as? [String: Any] else { throw UsageIssue.signInRequired }
            guard initial["type"] as? String == "chatgpt" else { throw UsageIssue.unsupported }
            let data: Data
            do { data = try rpc.request(id: 3, method: "account/rateLimits/read", params: ["excludeResetCreditDetails": true]) }
            catch UsageIssue.unavailable {
                // The provider manages rotation/locking. Refresh only after a failed read,
                // then pair the retried limits with the refreshed account identity.
                account = try UsageDecoding.object(rpc.request(id: 4, method: "account/read", params: ["refreshToken": true]))
                guard (account["account"] as? [String: Any])?["type"] as? String == "chatgpt" else { throw UsageIssue.signInRequired }
                data = try rpc.request(id: 5, method: "account/rateLimits/read", params: ["excludeResetCreditDetails": true])
            }
            let identity = account["account"] as? [String: Any] ?? [:]
            var result = try UsageDecoding.codex(data)
            let payload = try UsageDecoding.object(data)
            if let email = identity["email"] as? String {
                result.identity = UsageIdentity(account: email, plan: identity["planType"] as? String,
                    owner: "codex:" + (payload["accountId"] as? String ?? (home ?? "default") + ":" + email))
            }
            return result
        } catch let issue as UsageIssue { return .failure(.codex, issue) }
        catch { return .failure(.codex, .unavailable) }
    }
}
// No transcripts, credential export, shell, listener, or model turn is involved. Responses stay in memory.
private final class UsageRPC {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let deadline: TimeInterval
    private var buffer = Data()
    private var total = 0
    init(executable: String, timeout: TimeInterval, home: String?) throws {
        deadline = ProcessInfo.processInfo.systemUptime + max(0.1, min(timeout, 30))
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-s", "read-only", "-a", "never", "app-server"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        if let home { environment["CODEX_HOME"] = home }
        process.environment = environment
        try process.run()
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        _ = fcntl(output.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
    func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    func request(id: Int, method: String, params: [String: Any]) throws -> Data {
        try send(["id": id, "method": method, "params": params])
        while ProcessInfo.processInfo.systemUptime < deadline {
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                guard !line.isEmpty else { continue }
                let value = try UsageDecoding.object(line)
                guard value["id"] as? Int == id else { continue }
                // Never show arbitrary provider error strings: they may contain account data.
                if value["error"] != nil { throw UsageIssue.unavailable }
                guard let result = value["result"] as? [String: Any] else { throw UsageIssue.unsupported }
                return try JSONSerialization.data(withJSONObject: result)
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 50)
            if ready < 0 { if errno == EINTR { continue }; throw UsageIssue.unavailable }
            if ready > 0 {
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
                if count > 0 {
                    total += count
                    guard total <= UsageDecoding.maxBytes else { throw UsageIssue.unsupported }
                    buffer.append(contentsOf: bytes.prefix(count))
                } else if count == 0 { throw UsageIssue.unavailable }
                else if errno != EAGAIN && errno != EINTR { throw UsageIssue.unavailable }
            }
        }
        throw UsageIssue.timedOut
    }
    func close() {
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        guard process.isRunning else { return }
        process.terminate()
        let grace = ProcessInfo.processInfo.systemUptime + 0.25
        while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
