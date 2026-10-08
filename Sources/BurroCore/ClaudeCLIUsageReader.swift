// Ask Claude's built-in /usage command for quotas without exporting its credentials.
// Zero model turns, hooks/tools/MCP disabled, and no saved conversation.
import Foundation
import Darwin

public enum ClaudeCLIUsageReader {
    public static func read(profile: String? = nil) -> ProviderUsage {
        guard KeychainAccess.defaultKeychainUnlocked() == true else { return .failure(.claude, .keychainLocked) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let executable = [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        do { return try decode(run(executable: executable, profile: profile)) }
        catch let issue as UsageIssue { return .failure(.claude, issue) }
        catch { return .failure(.claude, .unavailable) }
    }

    static let arguments = ["-p", "/usage", "--output-format", "stream-json", "--verbose",
                            "--max-turns", "0", "--tools", "", "--strict-mcp-config",
                            "--mcp-config", "{\"mcpServers\":{}}", "--settings",
                            "{\"disableAllHooks\":true,\"remoteControlAtStartup\":false}",
                            "--setting-sources", "", "--no-session-persistence"]
    static func environment(profile: String?, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        // Keep only OS/runtime essentials and the user's nonessential-traffic policy.
        // No API key, alternate endpoint, injected agent configuration, or debug dump.
        let keep = Set(["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
                        "TZ", "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS",
                        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"])
        var env = base.filter { keep.contains($0.key) }
        if let selected = profile ?? base["CLAUDE_CONFIG_DIR"], !selected.isEmpty { env["CLAUDE_CONFIG_DIR"] = selected }
        env["NO_COLOR"] = "1"; env["DISABLE_AUTOUPDATER"] = "1"
        env["DISABLE_TELEMETRY"] = "1"; env["DISABLE_ERROR_REPORTING"] = "1"
        return env
    }

    static func run(executable: String?, profile: String?, timeout: TimeInterval = 25) throws -> Data {
        guard let executable else { throw UsageIssue.notInstalled }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.environment = environment(profile: profile)
        process.currentDirectoryURL = folder
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        try? pipe.fileHandleForWriting.close()
        defer {
            try? pipe.fileHandleForReading.close()
            if process.isRunning {
                process.terminate()
                let end = ProcessInfo.processInfo.systemUptime + 0.25
                while process.isRunning && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
        }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.1, min(timeout, 30))
        var output = Data(), finished = false
        while !finished && ProcessInfo.processInfo.systemUptime < deadline {
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 50)
            if ready < 0 { if errno == EINTR { continue }; throw UsageIssue.unavailable }
            if ready > 0 {
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count == 0 { finished = true }
                else if count > 0 {
                    guard output.count + count <= UsageDecoding.maxBytes else { throw UsageIssue.unsupported }
                    output.append(contentsOf: bytes.prefix(count))
                } else if errno != EAGAIN && errno != EINTR { throw UsageIssue.unavailable }
            }
        }
        guard finished else { throw UsageIssue.timedOut }
        // EOF need not mean the process exited. Never wait indefinitely for a child.
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else { throw UsageIssue.timedOut }
        guard process.terminationStatus == 0 else { throw UsageIssue.unavailable }
        return output
    }

    static func decode(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard data.count <= UsageDecoding.maxBytes else { throw UsageIssue.unsupported }
        var quota: [String: Any]?, completed = false
        for line in data.split(separator: 10) where !line.isEmpty {
            let event = try UsageDecoding.object(Data(line))
            if event["type"] as? String == "assistant", let report = event["usage_report"] as? [String: Any] {
                guard quota == nil, !completed else { throw UsageIssue.unsupported }
                quota = report["rate_limits"] as? [String: Any]
            }
            if event["type"] as? String == "result" {
                guard !completed, event["subtype"] as? String == "success", event["is_error"] as? Bool == false,
                      event["local_command"] as? String == "usage", UsageDecoding.number(event["num_turns"]) == 0,
                      UsageDecoding.number(event["total_cost_usd"]) == 0,
                      UsageDecoding.number(event["duration_api_ms"]) == 0 else { throw UsageIssue.unsupported }
                completed = true
            }
        }
        guard completed, let quota else { throw UsageIssue.unsupported }
        var result = try UsageDecoding.claude(JSONSerialization.data(withJSONObject: quota), now: now)
        guard result.issue == nil, result.windows.contains(where: { $0.remainingPercent != nil }) else { throw UsageIssue.unsupported }
        // No account identity is present in this report. Do not borrow one from a
        // previous token or an independent auth-status read and misattribute history.
        result.usesClaudeCLI = true
        return result
    }
}
