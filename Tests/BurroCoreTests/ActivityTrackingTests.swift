import XCTest
@testable import BurroCore

/// The activity tracker's contract: privacy rules, categories, span merging, storage and rollups.
final class ActivityTrackingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_150_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }
    private func key(_ bundle: String, _ title: String? = nil, address: String? = nil) -> ActivityKey {
        ActivityPrivacy.key(bundleID: bundle, app: bundle.components(separatedBy: ".").last ?? bundle, title: title, address: address)
    }

    // MARK: Privacy

    func testTitleSanitiserScrubsNumbersIbansCodesAndEmails() throws {
        let cases = [
            "Pay 4111 1111 1111 1111 now", "Card 4111-1111-1111-1111", "4111111111111111",
            "IBAN FR76 3000 6000 0112 3456 7890 189", "GB29 NWBK 6016 1331 9268 19 — transfer", "DE89370400440532013000",
            "Your code is 123456", "Code: 123-456", "Call +33 6 12 34 56 78", "Mail from edgar.h+burro@example.co.uk",
        ]
        for title in cases {
            let clean = try XCTUnwrap(ActivityPrivacy.sanitize(title: title))
            XCTAssertNil(clean.range(of: #"\d{6}|\d[ \-]\d{3}[ \-]\d{2}|NWBK|@"#, options: .regularExpression), "\(title) → \(clean)")
            XCTAssertFalse(clean.filter(\.isNumber).count >= 6, "\(title) → \(clean)")
        }
        XCTAssertEqual(ActivityPrivacy.sanitize(title: "Your code is 123456"), "Your code is [number]")
        XCTAssertEqual(ActivityPrivacy.sanitize(title: "Mail from a.b@example.com"), "Mail from [email]")
        XCTAssertEqual(ActivityPrivacy.sanitize(title: "PR #12345 — fix"), "PR #12345 — fix", "five digits stay")
        XCTAssertEqual(ActivityPrivacy.sanitize(title: "  line one\nline\ttwo  "), "line one line two")
        // An untitled page's title is its address: the query and fragment go, the page stays.
        XCTAssertEqual(ActivityPrivacy.sanitize(title: "app.example.com/oauth/callback?code=demo&state=xyz - Google Chrome"),
                       "app.example.com/oauth/callback - Google Chrome")
        XCTAssertEqual(ActivityPrivacy.sanitize(title: "https://example.com/reset#step=two"), "https://example.com/reset")
        // API keys and tokens, as in a terminal title showing the running command. The stand-in is
        // built here so no key-shaped literal sits in the repository for secret scanners to flag.
        let keyLike = "demo" + String(repeating: "x7", count: 14)
        XCTAssertEqual(ActivityPrivacy.sanitize(title: "curl -H 'x-api-key: \(keyLike)' api.example.com"),
                       "curl -H 'x-api-key: [token]' api.example.com")
        XCTAssertEqual(ActivityPrivacy.sanitize(title: "export DEMO_KEY=\(keyLike)"), "export DEMO_KEY=[token]")
        XCTAssertEqual(ActivityPrivacy.sanitize(title: "ActivityTrackingTests.swift — Burro"), "ActivityTrackingTests.swift — Burro", "ordinary long words stay")
        XCTAssertNil(ActivityPrivacy.sanitize(title: " \n "))
        let long = try XCTUnwrap(ActivityPrivacy.sanitize(title: String(repeating: "word ", count: 100)))
        XCTAssertEqual(long.count, ActivityPrivacy.titleLimit)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testOnlyTheHostOfAnAddressSurvives() {
        XCTAssertEqual(ActivityPrivacy.host(fromAddress: "https://dashboard.stripe.com/payments/pi_123?ref=abc#x"), "dashboard.stripe.com")
        XCTAssertEqual(ActivityPrivacy.host(fromAddress: "dashboard.stripe.com/acct_1/payments"), "dashboard.stripe.com")
        // Sign-in details in an address are dropped too (assembled here, for the same scanner reason).
        XCTAssertEqual(ActivityPrivacy.host(fromAddress: "https://" + ["name", "word"].joined(separator: ":") + "@Example.COM./path"), "example.com")
        XCTAssertEqual(ActivityPrivacy.host(fromAddress: "localhost:3000/admin"), "localhost")
        XCTAssertNil(ActivityPrivacy.host(fromAddress: "how to rotate a token"), "search terms aren't hosts")
        XCTAssertNil(ActivityPrivacy.host(fromAddress: "file:///Users/me/secrets.txt"))
        XCTAssertNil(ActivityPrivacy.host(fromAddress: "javascript:alert(1)"))
        XCTAssertNil(ActivityPrivacy.host(fromAddress: ""))
        let stored = key("com.google.Chrome", "Payments", address: "https://dashboard.stripe.com/payments?q=1")
        XCTAssertEqual(stored.host, "dashboard.stripe.com")
        XCTAssertFalse(stored.isPrivate, "Stripe's dashboard is work")
    }

    func testCredentialAppsPrivateWindowsAndBankingHostsKeepNoTitle() {
        for bundle in ["com.1password.1password", "com.bitwarden.desktop", "com.dashlane.Dashlane", "com.lastpass.LastPass",
                       "org.keepassxc.keepassxc", "com.apple.keychainaccess", "com.apple.Passwords", "com.example.PasswordVault"] {
            let k = key(bundle, "Visa ending 4242 — Edgar", address: "https://bank.example/login")
            XCTAssertTrue(k.isPrivate, bundle)
            XCTAssertNil(k.title, bundle)
            XCTAssertNil(k.host, bundle)
        }
        for title in ["New Incognito Tab", "Mozilla Firefox Private Browsing", "Bing [InPrivate]"] {
            let k = key("com.google.Chrome", title, address: "https://example.com/x")
            XCTAssertTrue(k.isPrivate); XCTAssertNil(k.title); XCTAssertNil(k.host)
        }
        let flagged = ActivityPrivacy.key(bundleID: "com.apple.Safari", app: "Safari", title: "Docs", address: "docs.google.com", privateWindow: true)
        XCTAssertTrue(flagged.isPrivate); XCTAssertNil(flagged.title); XCTAssertNil(flagged.host)
        for address in ["https://clients.boursobank.com/budget", "www.boursorama.com", "https://www.paypal.com/myaccount", "secure.mybank.co.uk",
                        "https://particuliers.societegenerale.fr"] {
            let k = key("com.apple.Safari", "Mes comptes — 30004 01234 56789", address: address)
            XCTAssertTrue(k.isPrivate, address); XCTAssertNil(k.title, address); XCTAssertEqual(k.host, ActivityPrivacy.privateHost, address)
        }
        let custom = ActivityPrivacy.key(bundleID: "com.apple.Safari", app: "Safari", title: "Payroll", address: "https://pay.acme.dev/run",
                                         privateHosts: ["acme.dev"])
        XCTAssertEqual(custom.host, ActivityPrivacy.privateHost); XCTAssertNil(custom.title)
        XCTAssertTrue(key("com.apple.Safari", "BoursoBank — Mes comptes").isPrivate, "a bank word in a browser title is enough without a host")
        XCTAssertFalse(ActivityPrivacy.isPrivateHost("notpaypal.com"))
        XCTAssertFalse(key("com.apple.Terminal", "bank-api — zsh").isPrivate, "only browser titles are judged by bank words")
        let plain = key("com.apple.Terminal", "ssh deploy@example.com — 1234567")
        XCTAssertEqual(plain.title, "ssh [email] — [number]")
    }

    func testRedactingAHostLaterHidesItsTitles() {
        let span = ActivitySpan(key("com.apple.Safari", "Payroll run", address: "https://pay.acme.dev"), start: at(0), end: at(60))
        let redacted = span.redacted(host: "acme.dev")
        XCTAssertNil(redacted.title); XCTAssertTrue(redacted.isPrivate); XCTAssertEqual(redacted.host, ActivityPrivacy.privateHost)
        XCTAssertEqual(span.redacted(host: "other.dev"), span)
    }

    // MARK: Categories

    func testCategoryRulesAndOrder() throws {
        let rules = ActivityRules(apps: ["com.google.Chrome": .build, "com.apple.dt.Xcode": .design], hosts: ["youtube.com": .docs])
        let base = ActivityRules()
        XCTAssertEqual(base.category(bundleID: "com.apple.dt.Xcode", host: nil, title: nil, isPrivate: false), .build)
        XCTAssertEqual(base.category(bundleID: "com.jetbrains.intellij", host: nil, title: nil, isPrivate: false), .build)
        XCTAssertEqual(rules.category(bundleID: "com.apple.dt.Xcode", host: nil, title: nil, isPrivate: false), .design, "your app rule wins")
        XCTAssertEqual(base.category(bundleID: "com.google.Chrome", host: "www.youtube.com", title: nil, isPrivate: false), .break)
        XCTAssertEqual(rules.category(bundleID: "com.google.Chrome", host: "m.youtube.com", title: nil, isPrivate: false), .docs, "your host rule wins")
        XCTAssertEqual(rules.category(bundleID: "com.google.Chrome", host: "mixpanel.com", title: nil, isPrivate: false), .analytics,
                       "a host rule beats an app rule")
        XCTAssertEqual(rules.category(bundleID: "com.google.Chrome", host: "unknown.example", title: nil, isPrivate: false), .build)
        XCTAssertEqual(base.category(bundleID: "com.google.Chrome", host: "unknown.example", title: nil, isPrivate: false), .browsing)
        XCTAssertEqual(base.category(bundleID: "com.google.Chrome", host: "gist.github.com", title: nil, isPrivate: false), .build)
        XCTAssertEqual(ActivityRules(hosts: ["github.com": .docs, "gist.github.com": .break])
            .category(bundleID: "x", host: "gist.github.com", title: nil, isPrivate: false), .break, "most specific domain wins")
        XCTAssertEqual(base.category(bundleID: "com.unknown.App", host: nil, title: "Open Pull Request #4", isPrivate: false), .build)
        XCTAssertEqual(base.category(bundleID: "com.unknown.App", host: nil, title: nil, isPrivate: false), .other)
        XCTAssertEqual(rules.category(bundleID: "com.apple.dt.Xcode", host: nil, title: nil, isPrivate: true), .private)
        XCTAssertEqual(base.category(bundleID: "com.apple.Safari", host: ActivityPrivacy.privateHost, title: nil, isPrivate: false), .private)
        XCTAssertFalse(ActivityCategory.assignable.contains(.private))

        let json = Data(#"{"version":1,"apps":{"a":"build","b":"nonsense","c":"private"},"hosts":{"x.com":"docs"},"privateHosts":["acme.dev"]}"#.utf8)
        let decoded = try JSONDecoder().decode(ActivityRules.self, from: json)
        XCTAssertEqual(decoded.apps, ["a": .build], "unknown and Private categories are dropped")
        XCTAssertEqual(decoded.hosts, ["x.com": .docs])
        XCTAssertEqual(decoded.privateHosts, ["acme.dev"])
    }

    // MARK: Recorder

    func testSpinnerTitlesAndFlicksDoNotSplitSpans() {
        var recorder = ActivityRecorder()
        var written: [ActivitySpan] = []
        written += recorder.observe(key("com.apple.dt.Xcode", "Burro — Build"), at: at(0))
        written += recorder.observe(key("com.apple.Terminal", "⠋ claude"), at: at(600))
        for i in 1..<600 { written += recorder.observe(key("com.apple.Terminal", ["⠋", "⠙", "⠹", "⠸"][i % 4] + " claude"), at: at(600 + Double(i) * 0.1)) }
        XCTAssertTrue(written.isEmpty, "nothing is written while the spinner spins")
        written += recorder.observe(key("com.apple.Safari", "Docs"), at: at(662))          // 2 s flick
        written += recorder.observe(key("com.apple.Terminal", "⠋ claude"), at: at(664))
        XCTAssertEqual(written.count, 1, "Xcode is final once Terminal outlasted five seconds")
        XCTAssertEqual(written.first?.bundleID, "com.apple.dt.Xcode")
        XCTAssertEqual(written.first?.duration, 600)
        written += recorder.observe(key("com.tinyspeck.slackmacgap", "general"), at: at(1200))
        written += recorder.observe(nil, at: at(1300))                                         // idle
        XCTAssertEqual(written.map(\.bundleID), ["com.apple.dt.Xcode", "com.apple.Terminal", "com.apple.Terminal", "com.tinyspeck.slackmacgap"])
        XCTAssertEqual(written[1].duration, 64, "the Safari flick folded into Terminal")
        XCTAssertEqual(written[1].end, written[2].start)
        XCTAssertEqual(written.reduce(0) { $0 + $1.duration }, 1300, "no time lost or double-counted")
        XCTAssertTrue(recorder.live(at: at(1400)).isEmpty, "idle time isn't counted")
    }

    func testTitlesThatHoldSplitAndCheckpointsSaveLongStays() {
        var recorder = ActivityRecorder()
        var written = recorder.observe(key("com.apple.Safari", "A", address: "github.com"), at: at(0))
        written += recorder.observe(key("com.apple.Safari", "B", address: "github.com"), at: at(30))
        written += recorder.observe(key("com.apple.Safari", "C", address: "github.com"), at: at(60))
        XCTAssertEqual(written.map(\.title), ["A"], "a title that held 30 s is its own span")
        written += recorder.checkpoint(at: at(400))
        XCTAssertEqual(written.map(\.title), ["A", "B", "C"])
        XCTAssertEqual(written.last?.end, at(400))
        XCTAssertEqual(recorder.live(at: at(450)).map(\.duration), [50])
        recorder.discard(at: at(500))
        XCTAssertEqual(recorder.live(at: at(510)).map(\.start), [at(500)])
        recorder.redact(host: "github.com")
        XCTAssertEqual(recorder.live(at: at(510)).first?.host, ActivityPrivacy.privateHost)
        XCTAssertNil(recorder.live(at: at(510)).first?.title)
    }

    // MARK: Storage

    private func temporaryLog() throws -> ActivityLog {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-activity-\(UUID().uuidString)/Activity")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        return ActivityLog(folder: folder)
    }

    func testLogRoundTripPermissionsAndMidnightSplit() throws {
        let log = try temporaryLog()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let midnight = t0 // 2026-11-09 00:00 in Seoul
        let span = ActivitySpan(key("com.apple.dt.Xcode", "Burro"), start: midnight.addingTimeInterval(-600), end: midnight.addingTimeInterval(300))
        try log.append([span], calendar: calendar)
        let before = log.read(day: midnight.addingTimeInterval(-1), calendar: calendar)
        let after = log.read(day: midnight, calendar: calendar)
        XCTAssertEqual(before.map(\.duration), [600]); XCTAssertEqual(after.map(\.duration), [300])
        XCTAssertEqual(after.first?.title, "Burro")
        let folderMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: log.folder.path)[.posixPermissions] as? Int)
        let fileMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: log.url(for: midnight, calendar: calendar).path)[.posixPermissions] as? Int)
        XCTAssertEqual(folderMode, 0o700); XCTAssertEqual(fileMode, 0o600)
    }

    func testLogToleratesTruncationAndRejectsSymlinksAndOversize() throws {
        let log = try temporaryLog()
        let day = t0
        try log.append([ActivitySpan(key("com.apple.Notes", "One"), start: at(0), end: at(60))])
        let url = log.url(for: day)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(#"{"start":1794150100,"end":17"#.utf8)); try handle.close()
        XCTAssertEqual(log.read(day: day).map(\.title), ["One"], "a truncated last line is skipped")
        try log.append([ActivitySpan(key("com.apple.Notes", "Two"), start: at(120), end: at(180))])
        XCTAssertEqual(log.read(day: day).map(\.title), ["One", "Two"], "the next append starts on a fresh line")

        let forged = #"{"start":1794150000,"end":1794150060,"bundle":"x","app":"x","title":"secret","private":true}"# + "\n"
        try (try String(contentsOf: url, encoding: .utf8) + forged).write(to: url, atomically: false, encoding: .utf8)
        XCTAssertEqual(log.read(day: day).count, 2, "a private span with a title is rejected")

        let target = log.folder.appendingPathComponent("elsewhere.txt")
        try FileManager.default.moveItem(at: url, to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertTrue(log.read(day: day).isEmpty, "symlinks are not followed")
        XCTAssertThrowsError(try log.append([ActivitySpan(key("com.apple.Notes", "Three"), start: at(200), end: at(260))]))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertTrue(log.read(day: day).isEmpty, "folders are not files")

        try FileManager.default.removeItem(at: url)
        try Data(count: ActivityLog.fileLimit).write(to: url)
        XCTAssertThrowsError(try log.append([ActivitySpan(key("com.apple.Notes", "Big"), start: at(0), end: at(60))]), "files stay bounded")
    }

    func testRetentionDeletionAndScrubKeepRules() throws {
        let log = try temporaryLog()
        let calendar = Calendar.current
        let now = Date()
        for back in [0, 1, 29, 30, 45] {
            let day = calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now))!.addingTimeInterval(3600)
            try log.append([ActivitySpan(key("com.apple.Safari", "Pay", address: "https://pay.acme.dev/x"), start: day, end: day.addingTimeInterval(60))])
        }
        try ActivityRules(apps: ["a": .build]).save(to: log.rulesURL)
        try Data("keep".utf8).write(to: log.folder.appendingPathComponent("notes.txt"))
        log.prune(now: now)
        XCTAssertEqual(log.dayFiles().count, 3, "today plus 29 earlier days are kept")
        log.scrub(host: "acme.dev")
        XCTAssertNil(log.read(day: now).first?.title)
        XCTAssertEqual(log.read(day: now).first?.host, ActivityPrivacy.privateHost)
        log.deleteDay(now)
        XCTAssertEqual(log.dayFiles().count, 2)
        log.deleteAll()
        XCTAssertTrue(log.dayFiles().isEmpty)
        XCTAssertEqual(ActivityRules.load(from: log.rulesURL).apps, ["a": .build], "rules survive delete everything")
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.folder.appendingPathComponent("notes.txt").path), "only day files are touched")
        let rulesMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: log.rulesURL.path)[.posixPermissions] as? Int)
        XCTAssertEqual(rulesMode, 0o600)
    }

    // MARK: Rollup

    func testDayRollup() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let spans = [
            ActivitySpan(key("com.apple.dt.Xcode", "Burro — A"), start: at(3600), end: at(3600 + 1200)),
            ActivitySpan(key("com.apple.dt.Xcode", "Burro — B"), start: at(3600 + 1200), end: at(3600 + 1500)),
            ActivitySpan(key("com.apple.dt.Xcode", "Burro — B"), start: at(3600 + 1400), end: at(3600 + 1500)), // duplicate tail
            ActivitySpan(key("com.google.Chrome", "Video", address: "youtube.com/watch?v=1"), start: at(7200), end: at(7800)),
            ActivitySpan(key("com.google.Chrome", "Login", address: "boursobank.com"), start: at(7800), end: at(7900)),
            ActivitySpan(key("com.apple.Notes", "Yesterday"), start: at(-600), end: at(-300)),
        ]
        let day = ActivityDay.build(spans: spans, rules: ActivityRules(), day: t0, calendar: calendar)
        XCTAssertEqual(day.total, 1500 + 600 + 100, "overlaps trimmed, other days clipped")
        XCTAssertEqual(day.focused, 1600, "Break isn't focus")
        XCTAssertEqual(day.categories.first?.category, .build)
        XCTAssertEqual(day.apps.map(\.name), ["Xcode", "Chrome"])
        XCTAssertEqual(day.sites.map(\.name), ["youtube.com"], "private hosts never show as sites")
        XCTAssertEqual(day.hourly[1], .build); XCTAssertEqual(day.hourly[2], .break); XCTAssertNil(day.hourly[3])
        XCTAssertEqual(day.entries.count, 3)
        XCTAssertEqual(day.entries[0].label, "Burro — A", "an activity is named by its longest title")
        XCTAssertEqual(day.entries[2].label, ActivityPrivacy.privateHost)
        XCTAssertEqual(day.entries[2].category, .private)
    }

    // MARK: Boundaries

    /// Activity data must never reach the orchestrator snapshot, burro-mcp, remote probes or the network.
    func testActivityDataStaysOutOfSharedSurfaces() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var files = ["Sources/BurroCore/Orchestrator.swift", "Sources/BurroCore/OrchestratorTools.swift",
                     "Sources/Burro/Stores/AppStore+Orchestrator.swift", "Sources/Burro/Stores/OrchestratorStore.swift",
                     "Sources/BurroCore/RemoteAgentMonitor.swift", "Sources/BurroCore/UsageHTTP.swift", "Sources/BurroCore/ConvexClient.swift"]
        for folder in ["Sources/BurroMCP", "Sources/BurroInspect", "Sources/BurroCore/Resources"] {
            files += try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path).map { "\(folder)/\($0)" }
        }
        for file in files {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for marker in ["ActivityLog", "ActivitySpan", "ActivityDay", "ActivityKey", "ActivityTracker", "activityTracker", "Burro/Activity"] {
                XCTAssertFalse(text.contains(marker), "\(file) mentions \(marker)")
            }
        }
        let tracking = try ["ActivityPrivacy", "ActivityLog", "ActivityRecorder", "ActivitySummary", "ActivityCategories", "ActivityTimeline"].map {
            try String(contentsOf: root.appendingPathComponent("Sources/BurroCore/\($0).swift"), encoding: .utf8)
        } + ["Stores/ActivityTracker", "Support/ActivitySampler", "Views/Today/TodayActivity", "Views/Today/TodayDayView", "Views/Home/HomeActivity"].map {
            try String(contentsOf: root.appendingPathComponent("Sources/Burro/\($0).swift"), encoding: .utf8)
        }
        for text in tracking {
            for marker in ["URLSession", "print(", "NSLog", "os_log", "Logger(", "CommandRunner", "Process("] {
                XCTAssertFalse(text.contains(marker), "activity tracking code must not use \(marker)")
            }
        }
    }
}
