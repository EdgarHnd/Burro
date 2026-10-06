// Read Claude Code's existing sign-in in memory and request only Anthropic's usage endpoint.
import Foundation
import Security
import LocalAuthentication
import Darwin

public enum ClaudeUsageReader {
    public static func read(allowKeychainPrompt: Bool = false, profile: String? = nil) async -> ProviderUsage {
        await read(allowKeychainPrompt: allowKeychainPrompt,
                   load: { try await ClaudeUsageCredential.loadAsync(allowPrompt: $0, profile: profile) }, fetch: fetch)
    }
    static func read(allowKeychainPrompt: Bool = false,
                     load: @Sendable (Bool) async throws -> ClaudeUsageCredential,
                     fetch: @Sendable (ClaudeUsageCredential) async throws -> ProviderUsage) async -> ProviderUsage {
        do {
            let token: ClaudeUsageCredential
            do { token = try await load(allowKeychainPrompt) }
            catch UsageIssue.expired { throw UsageIssue.renewalRequired }
            do { return try await fetch(token) }
            catch UsageIssue.expired {
                // Claude Code owns renewal. If it rotated during our request, retry once
                // with a fresh read of the SAME selected profile, never a cached account.
                let fresh = try await load(false)
                guard fresh.accessToken != token.accessToken else { throw UsageIssue.renewalRequired }
                return try await fetch(fresh)
            }
        } catch let issue as UsageIssue { return .failure(.claude, issue == .expired ? .renewalRequired : issue) }
        catch let error as URLError { return .failure(.claude, error.code == .timedOut ? .timedOut : .unavailable) }
        catch { return .failure(.claude, .unavailable) }
    }
    private static func fetch(_ token: ClaudeUsageCredential) async throws -> ProviderUsage {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: UsageNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = request(token: token.accessToken)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageIssue.unavailable }
        try validate(status: http.statusCode)
        var data = Data()
        for try await byte in bytes {
            guard data.count < UsageDecoding.maxBytes else { throw UsageIssue.unsupported }
            data.append(byte)
        }
        var result = try UsageDecoding.claude(data)
        var identityRequest = Self.request(token: token.accessToken)
        identityRequest.url = URL(string: "https://api.anthropic.com/api/oauth/profile")!
        identityRequest.timeoutInterval = 5
        if let identityData = try? await UsageHTTP.get(identityRequest, session: session) {
            result.identity = try? UsageDecoding.claudeIdentity(identityData)
        }
        return result
    }
    static func request(token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Burro/0.6.0", forHTTPHeaderField: "User-Agent")
        return request
    }
    static func validate(status: Int) throws {
        switch status {
        case 200: break
        case 401: throw UsageIssue.expired
        case 403: throw UsageIssue.signInRequired
        case 429: throw UsageIssue.rateLimited
        default: throw UsageIssue.unavailable
        }
    }
}
final class UsageNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward a credential to a redirect destination.
    }
}
struct ClaudeUsageCredential: Sendable {
    let accessToken: String
    // Keychain/file reads are synchronous. Keep them off the cooperative executor,
    // where long-running worktree scans can otherwise delay the first usage request.
    private static let queue = DispatchQueue(label: "local.burro.claude-credentials", qos: .userInitiated)
    static func loadAsync(allowPrompt: Bool, profile: String? = nil) async throws -> Self {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try load(allowPrompt: allowPrompt, profile: profile) })
            }
        }
    }
    static func decode(_ data: Data, now: Date = Date()) throws -> Self {
        let value = try UsageDecoding.object(data)
        guard let oauth = value["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty, token.utf8.count <= 16384,
              token.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { throw UsageIssue.signInRequired }
        guard let scopes = oauth["scopes"] as? [String], scopes.contains("user:profile") else { throw UsageIssue.signInRequired }
        guard let expires = UsageDecoding.number(oauth["expiresAt"]), expires / 1000 > now.timeIntervalSince1970 + 30 else { throw UsageIssue.expired }
        return Self(accessToken: token)
    }
    static func authenticationContext(allowPrompt: Bool) -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = !allowPrompt
        return context
    }
    static func load(allowPrompt: Bool, profile: String? = nil) throws -> Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let custom = profile ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let folder = custom.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        let fd = open(folder.appendingPathComponent(".credentials.json").path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd >= 0 {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  info.st_size > 0, info.st_size <= UsageDecoding.maxBytes else { throw UsageIssue.unavailable }
            return try decode(handle.read(upToCount: UsageDecoding.maxBytes + 1) ?? Data())
        }
        guard errno == ENOENT else { throw UsageIssue.unavailable }
        // Custom profiles must not fall back to another account's default Keychain item.
        guard custom == nil else { throw UsageIssue.signInRequired }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecAttrAccount as String: NSUserName(),
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: authenticationContext(allowPrompt: allowPrompt)
        ]
        var result: CFTypeRef?
        let status = try KeychainAccess.perform(allowPrompt: allowPrompt) {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw UsageIssue.unavailable }
            return try decode(data)
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled: throw UsageIssue.permissionRequired
        case errSecItemNotFound: throw UsageIssue.signInRequired
        default: throw UsageIssue.unavailable
        }
    }
}
