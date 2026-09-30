import Foundation

/// Refresh remote-tracking refs once per repository every five minutes, without touching checkouts.
public actor GitReferenceRefresh {
    public static let shared = GitReferenceRefresh()
    private var attempts: [String: (Date, String?)] = [:]
    public init() {}
    public func invalidate() { attempts.removeAll() }
    public func refresh(_ path: String, identity: String, now: Date = Date()) async -> String? {
        if let previous = attempts[identity], now.timeIntervalSince(previous.0) < 300 { return previous.1 }
        attempts[identity] = (now, "Remote refs are being refreshed")
        let error: String? = await Task.detached(priority: .utility) {
            let runner = CommandRunner()
            guard runner.git(path, ["remote", "get-url", "origin"]).succeeded else { return nil }
            let result = runner.git(path, ["-c", "credential.interactive=false", "fetch", "--no-tags", "--no-recurse-submodules",
                "--no-write-fetch-head", "origin", "+refs/heads/*:refs/remotes/origin/*"], timeout: 10)
            return result.succeeded ? nil : "Cannot refresh origin refs; merge status is unverified"
        }.value
        attempts[identity] = (now, error)
        return error
    }
}
