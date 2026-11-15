// One plain line per remote machine for Settings and the Machines card: "Connected · checked 12 s ago",
// "Unreachable since 14:02 · retrying in 30 s", "Paused", "Last seen 14:02 · connecting…", plus what
// Tailscale says about the machine when Burro already has its peer list. Pure: every input, including
// the clock and time zone, is passed in.
import Foundation

public enum RemoteStatusLine {
    public static func text(snapshot: RemoteHostSnapshot, poll: RemotePollStatus, checking: Bool = false,
                            peer: TailscalePeer? = nil, now: Date, timeZone: TimeZone = .current) -> String {
        guard snapshot.host.enabled, snapshot.state != .disabled else { return "Paused" }
        var parts: [String]
        switch snapshot.state {
        case .disabled: return "Paused"
        case .online:
            parts = ["Connected", snapshot.sampledAt.map { "checked \(ago($0, now: now))" } ?? "checked"]
        case .notChecked:
            parts = snapshot.sampledAt.map { ["Last seen \(clock($0, now: now, timeZone: timeZone))", "connecting…"] } ?? ["Connecting…"]
        case .offline:
            let since = poll.failingSince ?? snapshot.attemptedAt
            parts = [since > .distantPast ? "Unreachable since \(clock(since, now: now, timeZone: timeZone))" : "Unreachable"]
            let wait = poll.nextDue.timeIntervalSince(now)
            parts.append(checking || wait <= 0.5 ? "retrying now" : "retrying in \(duration(wait))")
        }
        if snapshot.state != .online, let peer {
            if peer.online { parts.append("Tailscale sees it online") }
            else if let seen = peer.lastSeen { parts.append("offline on Tailscale since \(clock(seen, now: now, timeZone: timeZone))") }
            else { parts.append("offline on Tailscale") }
        }
        return parts.joined(separator: " · ")
    }

    /// "just now", "12 s ago", "3 min ago", "2 h ago", "4 d ago".
    public static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 2 { return "just now" }
        if seconds < 60 { return "\(seconds) s ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86_400 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86_400) d ago"
    }
    /// "30 s", "2 min".
    public static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(1, Int(interval.rounded(.up)))
        return seconds < 60 ? "\(seconds) s" : "\(Int((Double(seconds) / 60).rounded())) min"
    }
    /// "14:02" today, "Nov 12, 14:02" on another day, in `timeZone`.
    public static func clock(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "MMM d, HH:mm"
        return formatter.string(from: date)
    }
}

extension TailscalePeer {
    /// The tailnet device an SSH destination names (by host name or MagicDNS name), if any.
    public static func matching(_ destination: String, in peers: [TailscalePeer]) -> TailscalePeer? {
        let host = (destination.split(separator: "@").last.map(String.init) ?? destination).lowercased()
        return peers.first { peer in
            guard !peer.isSelf else { return false }
            let dns = peer.dnsName?.lowercased()
            return host == peer.hostName.lowercased() || host == dns || dns?.hasPrefix(host + ".") == true
        }
    }
}
