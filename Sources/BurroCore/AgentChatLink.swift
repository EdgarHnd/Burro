// Build navigation-only provider links from validated session IDs, never arbitrary metadata URLs.
// `claudeDesktopURL` is the one place a Claude app desktop ID (`local_…`) becomes a link; the
// closed-chat lookup (ClosedChatLink) uses it too.
import Foundation

extension AgentSession {
    public var chatURL: URL? {
        switch provider {
        case .codex:
            var identity = id
            if let remote {
                let prefix = "remote:\(remote.hostID.uuidString):"
                guard identity.hasPrefix(prefix) else { return nil }
                identity.removeFirst(prefix.count)
            }
            guard identity.hasPrefix("codex:") else { return nil }
            let threadID = String(identity.dropFirst("codex:".count))
            guard UUID(uuidString: threadID) != nil else { return nil }
            // Codex resolves known remote threads through its connected-host catalog.
            return Self.link(scheme: "codex", host: "threads", path: "/\(threadID)")
        case .claude:
            // A desktop ID is machine-local. Never send the other Mac's ID to this Mac.
            if remote == nil, let desktopID = claudeDesktopSessionID, let url = Self.claudeDesktopURL(desktopID) {
                return url
            }
            if let bridgeID = claudeBridgeSessionID,
               Self.matches(bridgeID, pattern: "(?:cse|session)_[A-Za-z0-9_-]{1,100}") {
                // Claude resolves a local twin when present, otherwise opens its remote viewer.
                return Self.link(scheme: "claude", host: "code", path: "/\(bridgeID)")
            }
            // CLI UUIDs are not desktop IDs. Import/resume links could duplicate an active chat.
            return nil
        }
    }

    /// `claude://code/continue?session=local_…` for this Mac's Claude app desktop ID, or nil when
    /// the ID isn't one. Never pass another machine's desktop ID.
    public static func claudeDesktopURL(_ desktopID: String) -> URL? {
        guard matches(desktopID, pattern: "local_[A-Za-z0-9-]{1,64}") else { return nil }
        return link(scheme: "claude", host: "code", path: "/continue", query: [URLQueryItem(name: "session", value: desktopID)])
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        guard let range = value.range(of: pattern, options: .regularExpression) else { return false }
        return range == value.startIndex..<value.endIndex
    }

    private static func link(scheme: String, host: String, path: String, query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = scheme; components.host = host; components.path = path
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }
}
