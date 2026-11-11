// Rule-based categories for tracked activity, no AI. First match wins: Private (set by the
// privacy rules), your host rule, a built-in host, your app rule, a built-in app, a title word,
// any other browser page (Browsing), then Other. An imported span's stored category comes after
// your host and app rules and before every built-in one. Host rules match subdomains and the most
// specific domain wins. Your rules live in Activity/rules.json (owner-only) and apply to past
// days too, since categories are worked out when a day is read, not stored.
import Foundation

public enum ActivityCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case build, agents, design, analytics, comms, docs, browsing, `break`, `private`, other
    public var id: String { rawValue }
    public var title: String { rawValue == "comms" ? "Comms" : rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    /// Rules can't hand anything to Private except through `privateHosts`.
    public static var assignable: [ActivityCategory] { allCases.filter { $0 != .private } }
}

public struct ActivityRules: Codable, Sendable, Equatable {
    public var version = 1
    /// Bundle id → category.
    public var apps: [String: ActivityCategory] = [:]
    /// Domain → category; `github.com` also covers `gist.github.com`.
    public var hosts: [String: ActivityCategory] = [:]
    /// Extra domains treated like banking sites: no title, host stored as "Private".
    public var privateHosts: [String] = []

    public init(apps: [String: ActivityCategory] = [:], hosts: [String: ActivityCategory] = [:], privateHosts: [String] = []) {
        self.apps = apps; self.hosts = hosts; self.privateHosts = privateHosts
    }

    /// Unknown category names are skipped rather than failing the whole file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let parse = { (raw: [String: String]?) in (raw ?? [:]).compactMapValues(ActivityCategory.init(rawValue:)).filter { $0.value != .private } }
        apps = parse(try c.decodeIfPresent([String: String].self, forKey: .apps))
        hosts = parse(try c.decodeIfPresent([String: String].self, forKey: .hosts))
        privateHosts = Array((try c.decodeIfPresent([String].self, forKey: .privateHosts) ?? []).prefix(500))
    }

    public func category(bundleID: String, host: String?, title: String?, isPrivate: Bool, stored: ActivityCategory? = nil) -> ActivityCategory {
        if isPrivate || host == ActivityPrivacy.privateHost { return .private }
        if let stored {
            if let host, let match = Self.match(host, hosts) { return match }
            return apps[bundleID] ?? stored
        }
        if let host {
            if let match = Self.match(host, hosts) ?? Self.match(host, ActivityDefaults.hosts) { return match }
        }
        if let match = apps[bundleID] ?? ActivityDefaults.app(bundleID) { return match }
        if let lower = title?.lowercased(), let word = ActivityDefaults.titleWords.first(where: { lower.contains($0.word) }) {
            return word.category
        }
        return ActivityPrivacy.browsers.contains(bundleID) ? .browsing : .other
    }

    /// Most specific domain first: `a.b.example.com`, `b.example.com`, `example.com`.
    static func match(_ host: String, _ table: [String: ActivityCategory]) -> ActivityCategory? {
        var labels = host.split(separator: ".")[...]
        while labels.count >= 1 {
            if let hit = table[labels.joined(separator: ".")] { return hit }
            labels = labels.dropFirst()
        }
        return nil
    }

    public static func load(from url: URL) -> ActivityRules {
        guard let data = ActivityLog.readRegularFile(url, limit: 512 * 1024),
              let rules = try? JSONDecoder().decode(ActivityRules.self, from: data) else { return ActivityRules() }
        return rules
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try ActivityLog.ensurePrivateFolder(url.deletingLastPathComponent())
        try ActivityLog.writePrivateFile(url, data: try encoder.encode(self))
    }
}

enum ActivityDefaults {
    static let apps: [String: ActivityCategory] = [
        // Build
        "com.apple.dt.Xcode": .build, "com.microsoft.VSCode": .build, "com.todesktop.230313mzl4w4u92": .build, "dev.zed.Zed": .build,
        "com.apple.Terminal": .build, "com.googlecode.iterm2": .build, "com.mitchellh.ghostty": .build, "dev.warp.Warp-Stable": .build,
        "com.sublimetext.4": .build, "com.github.GitHubClient": .build, "com.apple.iphonesimulator": .build, "org.godotengine.godot": .build,
        "com.google.android.studio": .build, "com.exafunction.windsurf": .build, "com.tower.Tower3": .build, "com.apple.dt.instruments": .build,
        // Agents
        "com.anthropic.claudefordesktop": .agents, "com.openai.codex": .agents, "com.openai.chat": .agents, "local.burro.worktrees": .agents,
        // Design
        "com.figma.Desktop": .design, "com.bohemiancoding.sketch3": .design, "com.adobe.Photoshop": .design, "com.adobe.illustrator": .design,
        "com.pixelmatorteam.pixelmator.x": .design, "org.blenderfoundation.blender": .design, "com.seriflabs.affinitydesigner2": .design,
        "app.rive.editor": .design, "com.apple.ColorSyncUtility": .design,
        // Comms
        "com.tinyspeck.slackmacgap": .comms, "com.hnc.Discord": .comms, "com.apple.mail": .comms, "com.apple.MobileSMS": .comms,
        "ru.keepcoding.Telegram": .comms, "com.tdesktop.Telegram": .comms, "net.whatsapp.WhatsApp": .comms, "us.zoom.xos": .comms,
        "com.microsoft.teams2": .comms, "com.apple.FaceTime": .comms, "com.readdle.smartemail-Mac": .comms, "com.superhuman.electron": .comms,
        "com.microsoft.Outlook": .comms, "com.apple.iCal": .comms, "com.cron.electron": .comms,
        // Docs
        "notion.id": .docs, "com.apple.Notes": .docs, "md.obsidian": .docs, "com.apple.iWork.Pages": .docs, "com.apple.iWork.Numbers": .docs,
        "com.apple.iWork.Keynote": .docs, "com.microsoft.Word": .docs, "com.microsoft.Excel": .docs, "com.microsoft.Powerpoint": .docs,
        "com.apple.Preview": .docs, "com.linear": .docs, "com.apple.TextEdit": .docs,
        // Break
        "com.spotify.client": .break, "com.apple.Music": .break, "com.apple.TV": .break, "com.apple.podcasts": .break,
        "com.valvesoftware.steam": .break, "com.apple.Photos": .break, "com.apple.news": .break,
    ]
    static let appPrefixes: [(prefix: String, category: ActivityCategory)] = [("com.jetbrains.", .build), ("com.adobe.", .design)]

    static func app(_ bundleID: String) -> ActivityCategory? {
        apps[bundleID] ?? appPrefixes.first { bundleID.hasPrefix($0.prefix) }?.category
    }

    static let hosts: [String: ActivityCategory] = [
        "github.com": .build, "gitlab.com": .build, "localhost": .build, "stackoverflow.com": .build, "vercel.com": .build,
        "expo.dev": .build, "console.firebase.google.com": .build, "console.cloud.google.com": .build, "dash.cloudflare.com": .build,
        "appstoreconnect.apple.com": .build, "play.google.com": .build, "sentry.io": .build, "developer.apple.com": .docs,
        "claude.ai": .agents, "chatgpt.com": .agents, "platform.openai.com": .agents, "console.anthropic.com": .agents,
        "figma.com": .design, "dribbble.com": .design, "rive.app": .design,
        "mixpanel.com": .analytics, "amplitude.com": .analytics, "analytics.google.com": .analytics, "lookerstudio.google.com": .analytics,
        "posthog.com": .analytics, "app.hex.tech": .analytics, "datadoghq.com": .analytics, "metabase.com": .analytics,
        "dashboard.stripe.com": .analytics, "revenuecat.com": .analytics, "superwall.com": .analytics,
        "mail.google.com": .comms, "app.slack.com": .comms, "discord.com": .comms, "meet.google.com": .comms,
        "calendar.google.com": .comms, "web.whatsapp.com": .comms, "linkedin.com": .comms, "outlook.office.com": .comms,
        "docs.google.com": .docs, "drive.google.com": .docs, "notion.so": .docs, "linear.app": .docs, "atlassian.net": .docs,
        "youtube.com": .break, "netflix.com": .break, "twitch.tv": .break, "reddit.com": .break, "x.com": .break,
        "twitter.com": .break, "instagram.com": .break, "facebook.com": .break, "tiktok.com": .break, "news.ycombinator.com": .break,
    ]

    static let titleWords: [(word: String, category: ActivityCategory)] = [
        ("pull request", .build), ("localhost", .build), ("xcode", .build), ("figma", .design), ("mixpanel", .analytics),
        ("dashboard", .analytics), ("inbox", .comms), ("youtube", .break),
    ]
}
