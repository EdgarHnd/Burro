// What the activity tracker may keep about a moment, decided before anything is stored or shown.
// Credential apps and private windows keep only app time; banking hosts keep neither the title
// nor the real host; every title is clipped and scrubbed of long numbers, IBANs and email
// addresses. `ActivityPrivacy.key` is the only way an observation becomes an `ActivityKey`.
import Foundation

/// The frontmost window after the privacy rules. The recorder and the log accept nothing else.
public struct ActivityKey: Sendable, Hashable {
    public var bundleID: String
    public var app: String
    public var title: String?
    /// Host only (`dashboard.stripe.com`), never a path or query; `Private` for banking hosts.
    public var host: String?
    /// Credential app, private window or banking host: no title, category Private.
    public var isPrivate: Bool

    /// Same app and site: title changes inside it don't start a new activity.
    func sameApp(_ other: ActivityKey) -> Bool {
        bundleID == other.bundleID && host == other.host && isPrivate == other.isPrivate
    }
}

public enum ActivityPrivacy {
    public static let privateHost = "Private"
    public static let titleLimit = 120

    /// Password managers and credential apps: app time only.
    static let credentialApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx", "com.bitwarden.desktop",
        "com.dashlane.Dashlane", "com.dashlane.dashlanephonefinal", "com.lastpass.LastPass", "com.lastpass.lastpassmacdesktop",
        "org.keepassxc.keepassxc", "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.systempreferences",
        "com.apple.SecurityAgent", "com.apple.LocalAuthentication.UIAgent", "com.apple.loginwindow", "in.sinew.Enpass-Desktop",
        "me.proton.pass.electron", "com.nordpass.macos.NordPass", "com.keepersecurity.passwordmanager", "com.siber.roboform",
    ]
    static let credentialFragments = ["password", "keychain", "1password", "bitwarden", "lastpass", "dashlane", "keepass",
                                      "enpass", "nordpass", "keeper", "roboform", "proton.pass"]

    /// The lock screen, login window, screen saver and system authentication prompts. Not activity:
    /// the sampler records nothing while one is in front, and a day drops spans already stored for one.
    public static let systemScreens: Set<String> = [
        "com.apple.loginwindow", "com.apple.ScreenSaver.Engine", "com.apple.ScreenSaver.Engine.legacyScreenSaver",
        "com.apple.SecurityAgent", "com.apple.LocalAuthentication.UIAgent",
    ]

    public static func isSystemScreen(_ bundleID: String) -> Bool { systemScreens.contains(bundleID) }

    /// Browsers whose address bar the sampler may read (host only).
    public static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "org.mozilla.firefox",
    ]
    /// Chromium-family browsers. Arc builds its accessibility tree only when asked (`AXManualAccessibility`);
    /// the others are asked too when their address field can't be found. The sampler then reads the page's
    /// `AXURL` from the window's web area (never anything inside it), and only its host is kept.
    public static let chromiumBrowsers: Set<String> = [
        "company.thebrowser.Browser", "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
    ]
    static let privateWindowMarkers = ["private browsing", "incognito", "inprivate", "private window"]

    /// Banking and payment sites (subdomains included), plus any host label containing a bank word.
    static let bankingHosts = [
        "boursorama.com", "boursobank.com", "paypal.com", "paypal.me", "bnpparibas", "credit-agricole.fr",
        "societegenerale.fr", "labanquepostale.fr", "lcl.fr", "caisse-epargne.fr", "banquepopulaire.fr", "creditmutuel.fr",
        "cic.fr", "hellobank.fr", "fortuneo.fr", "revolut.com", "n26.com", "wise.com", "qonto.com", "shine.fr", "lydia-app.com",
        "chase.com", "wellsfargo.com", "citi.com", "capitalone.com", "americanexpress.com", "discover.com", "usbank.com",
        "hsbc.com", "hsbc.fr", "hsbc.co.uk", "barclays.co.uk", "monzo.com", "starlingbank.com", "ing.com", "ing.fr", "ing.de",
        "schwab.com", "fidelity.com", "vanguard.com", "robinhood.com", "coinbase.com", "kraken.com", "binance.com",
        "mercury.com", "brex.com", "venmo.com", "cash.app", "klarna.com",
    ]
    static let bankingWords = ["bank", "banque", "banca", "banco", "sparkasse"]

    public static func isCredentialApp(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        return credentialApps.contains(bundleID) || credentialFragments.contains { lower.contains($0) }
    }

    public static func isPrivateWindow(title: String?) -> Bool {
        guard let lower = title?.lowercased() else { return false }
        return privateWindowMarkers.contains { lower.contains($0) }
    }

    /// Banking host, a host label containing a bank word, or one of the user's private hosts.
    public static func isPrivateHost(_ host: String, extra: [String] = []) -> Bool {
        if (bankingHosts + extra).contains(where: { matches(host: host, domain: $0) }) { return true }
        let labels = host.split(separator: ".").dropLast()
        return labels.contains { label in bankingWords.contains { label.contains($0) } }
    }

    /// `www.paypal.com` matches `paypal.com`; `notpaypal.com` doesn't.
    public static func matches(host: String, domain: String) -> Bool {
        let domain = domain.lowercased()
        return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
    }

    /// The host of an address bar's text, or nil for search terms and non-web schemes. Paths,
    /// queries, fragments, ports and credentials are dropped.
    public static func host(fromAddress text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 8192, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: candidate), ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              var host = components.host?.lowercased() else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard (1...253).contains(host.count), host.allSatisfy(allowed.contains), !host.hasPrefix("."), !host.contains(".."),
              host.contains(".") || host == "localhost" else { return nil }
        return host
    }

    /// The stored form of a window title: one line, emails/IBANs/long numbers replaced, at most 120 characters.
    public static func sanitize(title: String) -> String? {
        var text = String(title.prefix(2000)).components(separatedBy: .controlCharacters).joined(separator: " ")
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Emails first (they contain digits). Then web addresses lose their query and fragment (an
        // untitled page's title is its address, `?code=\u2026` included). Then IBANs, then long mixed
        // letter-and-digit runs (API keys and tokens, as in a terminal title showing a command),
        // then six or more digits with optional spaces or dashes: cards, accounts, codes, phones.
        let patterns = [(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "[email]"),
                        (#"((?:https?://)?[A-Za-z0-9.\-]+\.[A-Za-z]{2,}(?::\d+)?(?:/[^\s?#]*)?)[?#]\S*"#, "$1"),
                        (#"\b[A-Z]{2}\d{2}(?:[ \-]?[A-Z0-9]{4}){2,8}(?:[ \-]?[A-Z0-9]{1,3})?\b"#, "[number]"),
                        (#"(?<![A-Za-z0-9_\-])(?=[A-Za-z0-9_\-]*\d)(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{24,}(?![A-Za-z0-9_\-])"#, "[token]"),
                        (#"\d(?:[ \u00A0\-]?\d){5,}"#, "[number]")]
        for (source, placeholder) in patterns {
            guard let pattern = try? NSRegularExpression(pattern: source) else { return nil }
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: placeholder)
        }
        if text.count > titleLimit { text = String(text.prefix(titleLimit - 1)) + "…" }
        return text.isEmpty ? nil : text
    }

    /// Applies every rule to one observation. `address` is a browser's address-bar text (only its
    /// host survives); `privateWindow` is the sampler's own private-window signal.
    public static func key(bundleID: String, app: String, title: String?, address: String? = nil,
                           privateWindow: Bool = false, privateHosts: [String] = []) -> ActivityKey {
        let bundle = String(bundleID.prefix(200)), name = String(app.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(80))
        let hidden = ActivityKey(bundleID: bundle, app: name, title: nil, host: nil, isPrivate: true)
        if isCredentialApp(bundle) || privateWindow || isPrivateWindow(title: title) { return hidden }
        let host = address.flatMap(host(fromAddress:))
        if let host, isPrivateHost(host, extra: privateHosts) {
            return ActivityKey(bundleID: bundle, app: name, title: nil, host: privateHost, isPrivate: true)
        }
        // A browser whose address couldn't be read: a banking word in the title is enough.
        if host == nil, browsers.contains(bundle), let lower = title?.lowercased(),
           (bankingWords + ["paypal", "boursorama"]).contains(where: lower.contains) { return hidden }
        return ActivityKey(bundleID: bundle, app: name, title: title.flatMap(sanitize), host: host, isPrivate: false)
    }

    /// A key on a host the user just marked private, made private the same way a banking host is.
    public static func redacted(_ key: ActivityKey, host domain: String) -> ActivityKey {
        guard let host = key.host, matches(host: host, domain: domain) else { return key }
        return ActivityKey(bundleID: key.bundleID, app: key.app, title: nil, host: privateHost, isPrivate: true)
    }
}
