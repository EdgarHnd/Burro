// Delegate Grok refresh-token ownership to its CLI; coalesce and back off silent renewals.
import Foundation
import CryptoKit
import Darwin

actor UsageCredentialRenewal {
    static let shared = UsageCredentialRenewal()
    private struct Attempt {
        var id = UUID()
        var fingerprint: String
        var task: Task<Void, Error>?
        var retryAt: Date
        var issue: UsageIssue?
    }
    private var attempts: [String: Attempt] = [:]

    func renew(profile: String, fingerprint: String, now: Date = Date(),
               operation: @escaping @Sendable () async throws -> Void) async throws {
        if let previous = attempts[profile], previous.fingerprint == fingerprint {
            if let task = previous.task { return try await task.value }
            if now < previous.retryAt { throw previous.issue ?? .renewalRequired }
        }
        // A profile switch cannot borrow a different credential's renewal result.
        let task = Task { try await operation() }
        let attempt = Attempt(fingerprint: fingerprint, task: task, retryAt: now, issue: nil)
        attempts[profile] = attempt
        do {
            try await task.value
            if attempts[profile]?.id == attempt.id {
                attempts[profile] = Attempt(fingerprint: fingerprint, retryAt: now.addingTimeInterval(60))
            }
        } catch {
            let issue = error as? UsageIssue ?? .unavailable
            if attempts[profile]?.id == attempt.id {
                attempts[profile] = Attempt(fingerprint: fingerprint, retryAt: now.addingTimeInterval(60), issue: issue)
            }
            throw issue
        }
        if attempts.count > 32 { attempts = attempts.filter { $0.value.task != nil || $0.value.retryAt > now } }
    }
    static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// No shell, login, prompt, model turn, output capture, or copied refresh token.
// `grok models` initializes the official CLI's coordinated auth manager and exits.
enum GrokCredentialCommand {
    static func executable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.local/bin/grok", home + "/.grok/bin/grok", "/opt/homebrew/bin/grok", "/usr/local/bin/grok"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func environment(profile: String, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = base.filter { !$0.key.hasPrefix("GIT_") && !$0.key.hasPrefix("GROK_") && !$0.key.hasPrefix("XAI_") }
        result["GROK_HOME"] = profile
        result["NO_COLOR"] = "1"
        return result
    }
    static func run(executable: String?, profile: String, timeout: TimeInterval = 25) throws {
        guard let executable else { throw UsageIssue.notInstalled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["models"]
        process.environment = environment(profile: profile)
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.1, min(timeout, 30))
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.025) }
        if process.isRunning {
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.25
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw UsageIssue.timedOut
        }
        guard process.terminationStatus == 0 else { throw UsageIssue.unavailable }
    }
}

public enum UsageRetryPolicy {
    public static func delay(issue: UsageIssue?, failures: Int, interval: Int) -> TimeInterval {
        guard let issue else { return Double(interval) }
        switch issue {
        case .unavailable, .timedOut: return min(300, 30 * pow(2, Double(min(max(failures - 1, 0), 4))))
        case .renewalRequired: return 60
        case .rateLimited: return max(300, Double(interval))
        default: return max(300, Double(interval))
        }
    }
}
