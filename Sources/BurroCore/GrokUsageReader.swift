// Read Grok credits, letting the official CLI silently renew its own saved sign-in.
import Foundation

public enum GrokUsageReader {
    public static func read(profile: String? = nil) async -> ProviderUsage {
        do {
            let folder = profile ?? ProcessInfo.processInfo.environment["GROK_HOME"] ??
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok").path
            let auth = try await loadCredential(folder: folder)
            do { return try await fetch(auth: auth) }
            catch UsageIssue.expired {
                let fresh = try await loadCredential(folder: folder)
                guard fresh.token != auth.token else { throw UsageIssue.expired }
                return try await fetch(auth: fresh)
            }
        } catch let issue as UsageIssue { return .failure(.grok, issue) }
        catch let error as URLError { return .failure(.grok, error.code == .timedOut ? .timedOut : .unavailable) }
        catch { return .failure(.grok, .unavailable) }
    }
    private static func fetch(auth: Credential) async throws -> ProviderUsage {
        let session = UsageHTTP.session(); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!)
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var result: ProviderUsage
        do { result = try decode(await UsageHTTP.get(request, session: session)) }
        catch let issue as UsageIssue where issue == .expired || issue == .signInRequired || issue == .rateLimited { throw issue }
        catch { result = .failure(.grok, .unavailable) }
        if result.issue != nil {
            let fallback = try await GrokWebUsage.read(token: auth.token, session: session)
            result.windows = fallback.windows; result.updatedAt = fallback.updatedAt
            result.issue = fallback.issue; result.products = fallback.products
        }
        result.identity = UsageIdentity(account: auth.email, plan: auth.plan,
            owner: "grok:\(auth.owner)")
        request.url = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
        request.timeoutInterval = 3
        if let data = try? await UsageHTTP.get(request, session: session),
           let value = try? UsageDecoding.object(data), let plan = value["subscription_tier_display"] as? String {
            result.identity?.plan = UsageDecoding.label(plan, fallback: "Grok")
        }
        return result
    }
    struct Credential {
        var token: String; var email: String; var owner: String; var plan: String?
        var expiresAt: Date; var canRenew: Bool
        var fingerprint: String { UsageCredentialRenewal.fingerprint(token) }
    }
    static func credential(_ data: Data, now: Date = Date(), requireValid: Bool = true) throws -> Credential {
        let object = try UsageDecoding.object(data)
        let keys = object.keys.filter { $0.hasPrefix("https://auth.x.ai::") }.sorted()
        // Multiple OAuth clients are ambiguous; do not choose an arbitrary account.
        guard keys.count <= 1 else { throw UsageIssue.unsupported }
        guard let entry = object[keys.first ?? "https://accounts.x.ai/sign-in"] as? [String: Any],
              let token = entry["key"] as? String, !token.isEmpty, token.utf8.count <= 16384,
              token.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { throw UsageIssue.signInRequired }
        guard let expires = UsageDecoding.isoDate(entry["expires_at"]) else { throw UsageIssue.expired }
        if requireValid && expires <= now.addingTimeInterval(30) { throw UsageIssue.expired }
        let email = UsageDecoding.label(entry["email"], fallback: "Grok CLI account")
        guard let owner = entry["user_id"] as? String, !owner.isEmpty else { throw UsageIssue.unsupported }
        return Credential(token: token, email: email, owner: owner + ":" + (entry["team_id"] as? String ?? ""), plan: nil, expiresAt: expires,
            canRenew: keys.count == 1 && entry["oidc_issuer"] as? String == "https://auth.x.ai" &&
                (entry["refresh_token"] as? String)?.isEmpty == false)
    }
    static func loadCredential(folder: String, now: Date = Date(),
                               coordinator: UsageCredentialRenewal = .shared,
                               read: (@Sendable () throws -> Data)? = nil,
                               renew: (@Sendable () async throws -> Void)? = nil) async throws -> Credential {
        let url = URL(fileURLWithPath: folder).appendingPathComponent("auth.json")
        let load: @Sendable () throws -> Data = read ?? { try UsageFile.read(url) }
        let initial = try credential(load(), now: now, requireValid: false)
        guard initial.expiresAt <= now.addingTimeInterval(300) else { return initial }
        guard initial.canRenew else {
            if initial.expiresAt > now.addingTimeInterval(30) { return initial }
            throw UsageIssue.renewalRequired
        }
        do {
            try await coordinator.renew(profile: url.standardizedFileURL.path, fingerprint: initial.fingerprint, now: now) {
                if let renew { try await renew() }
                else {
                    try await Task.detached(priority: .utility) {
                        try GrokCredentialCommand.run(executable: GrokCredentialCommand.executable(), profile: folder)
                    }.value
                }
            }
        } catch {
            // A sibling CLI may have refreshed even if this utility timed out.
            if let fresh = try? credential(load(), now: now) { return fresh }
            throw error
        }
        do { return try credential(load(), now: now) }
        catch UsageIssue.expired { throw UsageIssue.renewalRequired }
    }
    public static func decode(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        let object = try UsageDecoding.object(data)
        guard let config = object["config"] as? [String: Any] else { throw UsageIssue.unsupported }
        let period = config["currentPeriod"] as? [String: Any] ?? [:]
        let end = UsageDecoding.isoDate(period["end"] ?? config["billingPeriodEnd"])
        let start = UsageDecoding.isoDate(period["start"] ?? config["billingPeriodStart"])
        let duration = start.flatMap { start in end.flatMap { $0 > start ? $0.timeIntervalSince(start) : nil } }
        let title = duration.map { $0 <= 8 * 86400 ? "Weekly credits" : "Monthly credits" } ?? "Subscription credits"
        var windows: [UsageWindow] = []
        if config["creditUsagePercent"] != nil {
            windows.append(UsageWindow(id: "credits", title: title,
                remainingPercent: UsageDecoding.remaining(config["creditUsagePercent"]), resetsAt: end, duration: duration))
        }
        var result = ProviderUsage(id: .grok, updatedAt: now, windows: windows, issue: windows.isEmpty ? .unsupported : nil)
        if let used = UsageDecoding.number(config["creditUsagePercent"]), let products = config["productUsage"] as? [[String: Any]], products.count <= 32 {
            let shares = products.compactMap { product -> UsageProductShare? in
                guard let percent = UsageDecoding.number(product["usagePercent"]), (0...100).contains(percent),
                      let name = product["product"] as? String else { return nil }
                return UsageProductShare(id: name, title: UsageDecoding.label(name, fallback: "Other product"), usedPercent: percent)
            }
            if shares.count == products.count && Set(shares.map(\.id)).count == shares.count && abs(shares.reduce(0) { $0 + $1.usedPercent } - used) <= 0.1 { result.products = shares }
        }
        let cap = UsageDecoding.number((config["onDemandCap"] as? [String: Any])?["val"])
        let used = UsageDecoding.number((config["onDemandUsed"] as? [String: Any])?["val"])
        if cap != nil || used != nil {
            result.balance = UsageBalance(title: "On-demand usage", used: used.map { $0 / 100 },
                limit: cap.map { $0 / 100 }, currency: "USD", enabled: (cap ?? 0) > 0)
        }
        return result
    }
}
