// Independent provider quota models and bounded native usage/account decoders.
import Foundation
import CryptoKit

public enum UsageProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex, claude, grok
    public var id: String { rawValue }
    public var title: String { switch self { case .codex: "Codex"; case .claude: "Claude"; case .grok: "Grok" } }
    public var symbol: String { switch self { case .codex: "terminal"; case .claude: "sparkle"; case .grok: "bolt" } }
    public var dashboardURL: URL {
        let value = switch self {
        case .codex: "https://chatgpt.com/codex/cloud/settings/analytics#usage"
        case .claude: "https://claude.ai/settings/usage"
        case .grok: "https://grok.com/?_s=usage"
        }
        return URL(string: value)!
    }
    public var statusURL: URL {
        let value = switch self {
        case .codex: "https://status.openai.com"
        case .claude: "https://status.claude.com"
        case .grok: "https://status.x.ai"
        }
        return URL(string: value)!
    }
}
public struct UsageIdentity: Sendable, Equatable, Codable {
    public var account: String
    public var plan: String?
    public var scope: String
    public init(account: String, plan: String? = nil, owner: String) {
        self.account = account; self.plan = plan
        scope = SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
public struct UsageBalance: Sendable, Equatable {
    public var title: String
    public var used: Double?
    public var limit: Double?
    public var currency: String
    public var enabled: Bool
}
public struct UsageWindow: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var remainingPercent: Double?
    public var resetsAt: Date?
    public var duration: TimeInterval? = nil
    public var model: String? = nil
    public func resetLabel(now: Date) -> String {
        guard let resetsAt else { return "Reset time unavailable" }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return "Awaiting reset update" }
        let minutes = max(1, Int(ceil(min(seconds, 366 * 86400) / 60)))
        if minutes >= 1440 { return "Resets in \(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "Resets in \(minutes / 60)h \(minutes % 60)m" }
        return "Resets in \(minutes)m"
    }
    public func isExpired(now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }
}
public enum UsageIssue: String, Sendable, Equatable, Error {
    case notInstalled, signInRequired, permissionRequired, expired, renewalRequired, unavailable, timedOut, rateLimited, unsupported
    public var requiresSignIn: Bool { self == .signInRequired || self == .expired }
    public var accountLabel: String {
        switch self {
        case .signInRequired, .expired: "Sign-in needs attention"
        case .permissionRequired: "Keychain access needed"
        case .renewalRequired: "Session renewal needed"
        case .notInstalled: "Coding app not installed"
        default: "Limits temporarily unavailable"
        }
    }
    public var message: String {
        switch self {
        case .notInstalled: "Install this provider’s command-line app to connect an account."
        case .signInRequired: "Sign in to this provider’s coding app to see subscription limits."
        case .permissionRequired: "Connect Claude to use its existing sign-in. Choose Always Allow in the macOS prompt to remember access."
        case .expired: "The provider rejected this session. Open its coding app to reconnect."
        case .renewalRequired: "Waiting for the coding app to renew its session. Open the app; Burro will retry automatically."
        case .unavailable: "Couldn’t fetch limits. Retrying automatically."
        case .timedOut: "The provider took too long to respond. Retrying automatically."
        case .rateLimited: "The provider asked us to slow down. Retrying in a few minutes."
        case .unsupported: "This account or provider version did not report supported limits."
        }
    }
}
public struct UsageProductShare: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var usedPercent: Double
}
public struct ProviderUsage: Identifiable, Sendable, Equatable {
    public var id: UsageProvider
    public var updatedAt: Date?
    public var windows: [UsageWindow]
    public var issue: UsageIssue?
    public var identity: UsageIdentity? = nil
    public var balance: UsageBalance? = nil
    public var isLoading = false
    public var resetCredits: Int? = nil
    public var products: [UsageProductShare] = []
    public var title: String { id.title }
    public func isStale(now: Date) -> Bool {
        guard let updatedAt else { return true }
        return now.timeIntervalSince(updatedAt) > 600 || updatedAt.timeIntervalSince(now) > 60
    }
    public static func loading(_ provider: UsageProvider) -> Self { Self(id: provider, windows: [], isLoading: true) }
    public static func failure(_ provider: UsageProvider, _ issue: UsageIssue) -> Self {
        Self(id: provider, windows: [], issue: issue)
    }
}
public struct ProviderUsageSnapshot: Sendable, Equatable {
    public enum Availability: Sendable { case loading, available, disabled }
    public var availability: Availability
    public var providers: [ProviderUsage]
    public static let loading = Self(availability: .loading, providers: [])
    public static let disabled = Self(availability: .disabled, providers: [])
    public init(availability: Availability, providers: [ProviderUsage]) {
        self.availability = availability; self.providers = providers
    }
}
public enum UsageDecoding {
    static let maxBytes = 2 * 1024 * 1024
    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maxBytes,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageIssue.unsupported }
        return value
    }
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    static func remaining(_ used: Any?) -> Double? {
        guard let used = number(used), (0...100).contains(used) else { return nil }
        return 100 - used
    }
    static func timestamp(_ value: Any?) -> Date? {
        guard let seconds = number(value), (0...253402300799).contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
    static func isoDate(_ value: Any?) -> Date? {
        guard let text = value as? String, text.count <= 64 else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func label(_ value: Any?, fallback: String) -> String {
        guard let text = value as? String, !text.isEmpty, text.count <= 60,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return fallback }
        return text
    }
    public static func codex(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        let object = try object(data)
        let buckets: [(String, [String: Any])]
        if let map = object["rateLimitsByLimitId"] as? [String: Any] {
            guard map.count <= 32, map.values.allSatisfy({ $0 is [String: Any] }) else { throw UsageIssue.unsupported }
            buckets = map.keys.sorted { a, b in a == "codex" ? b != "codex" : (b == "codex" ? false : a < b) }.map { ($0, map[$0] as! [String: Any]) }
        } else if let legacy = object["rateLimits"] as? [String: Any] { buckets = [("codex", legacy)] }
        else { throw UsageIssue.unsupported }
        var windows: [UsageWindow] = []
        for (key, bucket) in buckets {
            for slot in ["primary", "secondary"] {
                guard let window = bucket[slot] as? [String: Any] else { continue }
                let cadence: String
                switch number(window["windowDurationMins"]) {
                case 300: cadence = "5 hours"
                case 10080: cadence = "Weekly"
                case 1440: cadence = "Daily"
                case let duration? where duration > 0 && duration < 525600: cadence = "\(Int(duration)) minutes"
                default: cadence = slot == "primary" ? "Primary limit" : "Additional limit"
                }
                let title = key == "codex" ? cadence : "\(label(bucket["limitName"], fallback: "Additional quota")) · \(cadence)"
                windows.append(UsageWindow(id: "\(key):\(slot)", title: title,
                    remainingPercent: remaining(window["usedPercent"]), resetsAt: timestamp(window["resetsAt"]),
                    duration: number(window["windowDurationMins"]).flatMap { $0 > 0 && $0 <= 525600 ? $0 * 60 : nil }))
            }
        }
        var result = ProviderUsage(id: .codex, updatedAt: now, windows: windows, issue: windows.isEmpty ? .unsupported : nil)
        let credits = object["rateLimitResetCredits"] as? [String: Any]
        result.resetCredits = number(credits?["availableCount"]).flatMap { $0 >= 0 && $0 < 100000 ? Int($0) : nil }
        return result
    }
    public static func claude(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        let object = try object(data)
        var windows: [UsageWindow] = []
        let native = object["limits"] as? [[String: Any]]
        if let native {
            guard native.count <= 64 else { throw UsageIssue.unsupported }
            var seen = Set<String>()
            for entry in native {
                let kind = entry["kind"] as? String ?? ""
                guard ["session", "weekly_all", "weekly_scoped"].contains(kind) else { continue }
                let model = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])
                let name = label(model?["display_name"], fallback: "All models")
                let scoped = kind == "weekly_scoped" && name.lowercased() != "all models"
                let id = scoped ? "weekly-model:" + label(model?["id"], fallback: name.lowercased()) : (kind == "session" ? "session" : "weekly")
                guard seen.insert(id).inserted else { continue }
                windows.append(UsageWindow(id: id, title: kind == "session" ? "Session" : (scoped ? "\(name) weekly" : "Weekly"),
                    remainingPercent: remaining(entry["percent"]), resetsAt: isoDate(entry["resets_at"]),
                    duration: kind == "session" ? 5 * 3600 : 7 * 86400, model: scoped ? name : nil))
            }
        } else {
            for (key, title, duration) in [("five_hour", "Session", 5 * 3600), ("seven_day", "Weekly", 7 * 86400),
                                          ("seven_day_sonnet", "Sonnet weekly", 7 * 86400), ("seven_day_opus", "Opus weekly", 7 * 86400)] {
                guard let window = object[key] as? [String: Any] else { continue }
                windows.append(UsageWindow(id: key, title: title, remainingPercent: remaining(window["utilization"]),
                    resetsAt: isoDate(window["resets_at"]), duration: Double(duration)))
            }
        }
        var result = ProviderUsage(id: .claude, updatedAt: now, windows: windows, issue: windows.isEmpty ? .unsupported : nil)
        if let extra = object["extra_usage"] as? [String: Any] {
            result.balance = UsageBalance(title: "Extra usage", used: number(extra["used_credits"]).map { $0 / 100 },
                limit: number(extra["monthly_limit"]).map { $0 / 100 }, currency: label(extra["currency"], fallback: "USD"),
                enabled: extra["is_enabled"] as? Bool ?? false)
        }
        return result
    }
    public static func claudeIdentity(_ data: Data) throws -> UsageIdentity? {
        let object = try object(data)
        guard let account = object["account"] as? [String: Any], let id = account["uuid"] as? String,
              let email = account["email"] as? String, !email.isEmpty else { return nil }
        let org = object["organization"] as? [String: Any] ?? [:]
        let plan = label(org["subscription_type"], fallback: account["has_claude_max"] as? Bool == true ? "Max" : (account["has_claude_pro"] as? Bool == true ? "Pro" : "Claude"))
        return UsageIdentity(account: label(email, fallback: "Claude account"), plan: plan,
            owner: "claude:" + id + ":" + (org["uuid"] as? String ?? ""))
    }
}
import CoreFoundation
