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

    func testIdleNoticedLateCutsPendingTimeAtTheLastInput() {
        // Pending span straddling the idle start: cut there, and the open span after it is dropped.
        var recorder = ActivityRecorder()
        var written = recorder.observe(key("com.apple.dt.Xcode", "Burro"), at: at(0))
        written += recorder.observe(key("com.apple.Terminal", "zsh"), at: at(100))
        written += recorder.observe(key("com.apple.Safari", "Docs"), at: at(200))
        XCTAssertEqual(written.map(\.bundleID), ["com.apple.dt.Xcode"])
        written += recorder.observe(nil, at: at(150))                 // idle since 150, noticed later
        XCTAssertEqual(written.map(\.bundleID), ["com.apple.dt.Xcode", "com.apple.Terminal"])
        XCTAssertEqual(written.last?.start, at(100))
        XCTAssertEqual(written.last?.end, at(150), "nothing runs past the last input")
        XCTAssertTrue(recorder.live(at: at(300)).isEmpty)

        // A pending span with a flick folded into it, cut inside the flick.
        recorder = ActivityRecorder()
        written = recorder.observe(key("com.apple.Terminal", "zsh"), at: at(0))
        written += recorder.observe(key("com.apple.Safari", "Docs"), at: at(100))   // 3 s flick folds into Terminal
        written += recorder.observe(key("com.apple.Notes", "Notes"), at: at(103))
        XCTAssertTrue(written.isEmpty)
        written += recorder.observe(nil, at: at(101))
        XCTAssertEqual(written.map(\.bundleID), ["com.apple.Terminal"], "Notes started after the idle start")
        XCTAssertEqual(written.first?.start, at(0))
        XCTAssertEqual(written.first?.end, at(101))
    }

    func testIdleBeforeAPendingSpanDropsIt() {
        var recorder = ActivityRecorder()
        var written = recorder.observe(key("com.apple.dt.Xcode", "Burro"), at: at(0))
        written += recorder.observe(nil, at: at(60))
        XCTAssertEqual(written.map(\.duration), [60])
        // Back, then an agent switches apps while you're away again; the check notices late.
        written = recorder.observe(key("com.apple.Terminal", "zsh"), at: at(1000))
        written += recorder.observe(key("com.apple.Safari", "Docs"), at: at(1030))
        XCTAssertTrue(written.isEmpty)
        XCTAssertEqual(recorder.pending?.bundleID, "com.apple.Terminal")
        written = recorder.observe(nil, at: at(990))
        XCTAssertTrue(written.isEmpty, "the pending and open spans both started after the idle start: \(written)")
        XCTAssertTrue(recorder.live(at: at(1100)).isEmpty)
    }

    func testIdleNowEndsSpansAsBefore() {
        var recorder = ActivityRecorder()
        var written = recorder.observe(key("com.apple.dt.Xcode", "Burro"), at: at(0))
        written += recorder.observe(key("com.apple.Terminal", "zsh"), at: at(100))
        written += recorder.observe(nil, at: at(200))
        XCTAssertEqual(written.map(\.bundleID), ["com.apple.dt.Xcode", "com.apple.Terminal"])
        XCTAssertEqual(written.map(\.duration), [100, 100])
        XCTAssertEqual(written.last?.end, at(200))
        written = recorder.observe(nil, at: at(300))
        XCTAssertTrue(written.isEmpty, "a second idle has nothing to end")
    }

    func testSpansThatRoundToNothingAreNeverHandedOutOrWritten() throws {
        var recorder = ActivityRecorder()
        // A prompt that flashes up on unlock and is gone at once.
        var written = recorder.observe(key("com.example.Prompt"), at: at(0))
        written += recorder.observe(nil, at: at(0.04))
        XCTAssertTrue(written.isEmpty)
        let span = ActivitySpan(key("com.apple.Notes", "One"), start: at(0.01), end: at(0.04))
        XCTAssertFalse(span.isRecordable)
        XCTAssertTrue(ActivitySpan(key("com.apple.Notes", "One"), start: at(0), end: at(0.1)).isRecordable)
        let log = try temporaryLog()
        try log.append([span, ActivitySpan(key("com.apple.Notes", "Two"), start: at(1), end: at(61))])
        XCTAssertEqual(log.read(day: t0).map(\.title), ["Two"])
    }

    func testSystemPromptHelperIsASystemScreen() throws {
        for id in ["com.apple.SecurityAgent", "com.apple.SecurityAgentHelper", "com.apple.SecurityAgentHelper.arm64",
                   "com.apple.SecurityAgentHelper.x86_64", "com.apple.loginwindow"] {
            XCTAssertTrue(ActivityPrivacy.isSystemScreen(id), id)
        }
        for id in ["com.apple.SecurityAgentHelperX", "com.example.com.apple.SecurityAgentHelper.arm64", "com.apple.Safari"] {
            XCTAssertFalse(ActivityPrivacy.isSystemScreen(id), id)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let helper = ActivityPrivacy.key(bundleID: "com.apple.SecurityAgentHelper.arm64", app: "SecurityAgentHelper", title: nil)
        let spans = [ActivitySpan(helper, start: at(3600), end: at(3660)),
                     ActivitySpan(key("com.apple.dt.Xcode", "Burro"), start: at(3660), end: at(3720))]
        let day = ActivityDay.build(spans: spans, rules: ActivityRules(), day: t0, calendar: calendar)
        XCTAssertEqual(day.total, 60, "a stored helper span isn't shown")
        XCTAssertEqual(day.apps.map(\.name), ["Xcode"])
    }

    // MARK: Presence

    func testOnlyInputEndsIdleness() {
        var presence = ActivityPresence(idleAfter: 120)
        presence.reset(quiet: 3)
        XCTAssertFalse(presence.idle)
        XCTAssertNil(presence.update(quiet: 60, at: at(60)))
        XCTAssertEqual(presence.update(quiet: 140, at: at(140)), .away(since: at(0)), "dated from the last input")
        // An agent brings apps to the front every few seconds: no input, still away.
        for t in stride(from: 148.0, through: 1400, by: 8) { XCTAssertNil(presence.update(quiet: t, at: at(t))) }
        XCTAssertTrue(presence.idle)
        XCTAssertEqual(presence.update(quiet: 2, at: at(1500)), .back(since: at(1498)))
        XCTAssertFalse(presence.idle)
        XCTAssertNil(presence.update(quiet: 1, at: at(1505)), "a switch right after a click is just a switch")
        presence.reset(quiet: 600)
        XCTAssertTrue(presence.idle, "waking up with no input starts away")
        XCTAssertNil(presence.update(quiet: 605, at: at(2000)))
    }

    func testIdleThresholdPreferenceIsTwoFiveOrTenMinutes() {
        XCTAssertEqual(ActivityPresence.idleChoices, [120, 300, 600])
        XCTAssertEqual(ActivityPresence.idleAfter(preference: nil), 120, "the default stays two minutes")
        XCTAssertEqual(ActivityPresence.idleAfter(preference: 300), 300)
        XCTAssertEqual(ActivityPresence.idleAfter(preference: 600.0), 600)
        XCTAssertEqual(ActivityPresence.idleAfter(preference: 5), 300, "small numbers are minutes")
        XCTAssertEqual(ActivityPresence.idleAfter(preference: "10"), 600)
        XCTAssertEqual(ActivityPresence.idleAfter(preference: 3600), 600, "clamped to the longest choice")
        XCTAssertEqual(ActivityPresence.idleAfter(preference: 30), 120, "clamped to the shortest choice")
        XCTAssertEqual(ActivityPresence.idleAfter(preference: 400), 300, "snapped to the nearest choice")
        for junk: Any in [0, -5, Double.nan, Double.infinity, true, "soon", [120]] {
            XCTAssertEqual(ActivityPresence.idleAfter(preference: junk), 120, "\(junk)")
        }
        // A longer threshold applies at the next check: four quiet minutes are away at 2, back at 5.
        var presence = ActivityPresence()
        XCTAssertEqual(presence.update(quiet: 240, at: at(240)), .away(since: at(0)))
        presence.idleAfter = 300
        XCTAssertEqual(presence.update(quiet: 245, at: at(245)), .back(since: at(0)))
        XCTAssertNil(presence.update(quiet: 290, at: at(290)))
        XCTAssertEqual(presence.update(quiet: 301, at: at(301)), .away(since: at(0)))
    }

    // MARK: Day shown

    func testShownDayFollowsTodayAcrossMidnightAndStaysOnAPickedDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let midnight = t0 // 2026-11-09 00:00 in Seoul
        let friday = midnight.addingTimeInterval(-3600) // 23:00 the day before
        var shown = ShownDay(now: friday, calendar: calendar)
        XCTAssertEqual(shown.day, midnight.addingTimeInterval(-86_400))
        XCTAssertFalse(shown.update(now: friday.addingTimeInterval(1800), calendar: calendar))
        XCTAssertTrue(shown.update(now: midnight.addingTimeInterval(60), calendar: calendar), "left on today, it moves on")
        XCTAssertEqual(shown.day, midnight)
        XCTAssertTrue(shown.following)

        // A past day you picked stays shown across midnight.
        XCTAssertTrue(shown.show(midnight.addingTimeInterval(-3 * 86_400), now: midnight.addingTimeInterval(60), calendar: calendar))
        XCTAssertFalse(shown.following)
        XCTAssertFalse(shown.update(now: midnight.addingTimeInterval(86_400 + 60), calendar: calendar))
        XCTAssertEqual(shown.day, midnight.addingTimeInterval(-3 * 86_400))

        // Back to today follows again; a future day is clamped to today.
        let nextDay = midnight.addingTimeInterval(86_400 + 60)
        XCTAssertTrue(shown.show(nextDay.addingTimeInterval(5 * 86_400), now: nextDay, calendar: calendar))
        XCTAssertEqual(shown.day, midnight.addingTimeInterval(86_400))
        XCTAssertTrue(shown.following)
        XCTAssertTrue(shown.update(now: nextDay.addingTimeInterval(86_400), calendar: calendar))
        XCTAssertEqual(shown.day, midnight.addingTimeInterval(2 * 86_400))

        // The clock going back never leaves a day later than today.
        XCTAssertTrue(shown.update(now: midnight.addingTimeInterval(60), calendar: calendar))
        XCTAssertEqual(shown.day, midnight)
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
        for back in [0, 1, 364, 365, 400] {
            let day = calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now))!.addingTimeInterval(3600)
            try log.append([ActivitySpan(key("com.apple.Safari", "Pay", address: "https://pay.acme.dev/x"), start: day, end: day.addingTimeInterval(60))])
        }
        try ActivityRules(apps: ["a": .build]).save(to: log.rulesURL)
        try Data("keep".utf8).write(to: log.folder.appendingPathComponent("notes.txt"))
        log.prune(now: now)
        XCTAssertEqual(ActivityLog.retentionDays, 365)
        XCTAssertEqual(log.dayFiles().count, 3, "today plus 364 earlier days are kept")
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

    // MARK: Coverage

    private func seoul() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        return calendar
    }
    private func span(_ from: Date, _ to: Date) -> ActivitySpan { ActivitySpan(key("com.apple.dt.Xcode", "Burro"), start: from, end: to) }

    func testALateStartIsNotRecordedBeforeIt() throws {
        let calendar = try seoul()
        let day = calendar.startOfDay(for: t0)
        let clock = { (h: Double, m: Double) in day.addingTimeInterval(h * 3600 + m * 60) }
        let now = clock(17, 5)
        let built = ActivityDay.build(spans: [span(clock(16, 43), clock(17, 5))], rules: ActivityRules(), day: day,
                                      coverage: [DateInterval(start: clock(16, 42), end: now)], now: now, calendar: calendar)
        XCTAssertTrue(built.coverageKnown)
        XCTAssertEqual(built.notRecorded, [DateInterval(start: day, end: clock(16, 42))])
        XCTAssertEqual(built.notRecordedNote, "Not recorded 0:00–16:42")
        // Up to now only: the rest of today isn't a gap yet.
        XCTAssertFalse(built.notRecorded.contains { $0.end > now })
    }

    func testTheDayCoverageBeganClaimsNothingBeforeIt() throws {
        // Spans from before the first recording interval: the day this started being recorded.
        let calendar = try seoul()
        let day = calendar.startOfDay(for: t0)
        let clock = { (h: Double, m: Double) in day.addingTimeInterval(h * 3600 + m * 60) }
        let spans = [span(clock(14, 22), clock(15, 0)), span(clock(17, 0), clock(17, 30)), span(clock(23, 30), clock(23, 40))]
        let built = ActivityDay.build(spans: spans, rules: ActivityRules(), day: day,
                                      coverage: [DateInterval(start: clock(23, 28), end: clock(23, 50))], now: clock(23, 50), calendar: calendar)
        XCTAssertEqual(built.notRecorded, [], "idle gaps between earlier spans aren't unrecorded time")
        XCTAssertNil(built.notRecordedNote)
        // A later stop on that day is still a gap.
        let stopped = ActivityDay.build(spans: spans, rules: ActivityRules(), day: day,
                                        coverage: [DateInterval(start: clock(23, 28), end: clock(23, 41))], now: nil, calendar: calendar)
        XCTAssertEqual(stopped.notRecorded, [DateInterval(start: clock(23, 41), end: clock(24, 0))])
    }

    func testAPauseInTheMiddleAndSeveralGaps() throws {
        let calendar = try seoul()
        let day = calendar.startOfDay(for: t0)
        let clock = { (h: Double, m: Double) in day.addingTimeInterval(h * 3600 + m * 60) }
        let coverage = [DateInterval(start: clock(0, 0), end: clock(12, 0)), DateInterval(start: clock(13, 10), end: clock(13, 12)),
                        DateInterval(start: clock(13, 15), end: clock(24, 0))]
        let built = ActivityDay.build(spans: [], rules: ActivityRules(), day: day, coverage: coverage, now: nil, calendar: calendar)
        XCTAssertEqual(built.notRecorded, [DateInterval(start: clock(12, 0), end: clock(13, 10))], "a 3-minute gap is ignored")
        XCTAssertEqual(built.notRecordedNote, "Not recorded 12:00–13:10")
        // A past day Burro quit early ends at 24:00; two gaps read as a total.
        let early = ActivityDay.build(spans: [], rules: ActivityRules(), day: day, coverage: [DateInterval(start: clock(9, 0), end: clock(18, 0))],
                                      calendar: calendar)
        XCTAssertEqual(early.notRecorded.count, 2)
        XCTAssertEqual(early.notRecordedNote, "Not recorded for 15h 0m")
        let quit = ActivityDay.build(spans: [], rules: ActivityRules(), day: day, coverage: [DateInterval(start: clock(0, 0), end: clock(18, 0))],
                                     calendar: calendar)
        XCTAssertEqual(quit.notRecordedNote, "Not recorded 18:00–24:00")
        let full = ActivityDay.build(spans: [], rules: ActivityRules(), day: day, coverage: [DateInterval(start: clock(0, 0), end: clock(24, 0))],
                                     calendar: calendar)
        XCTAssertEqual(full.notRecorded, [])
        XCTAssertNil(full.notRecordedNote)
    }

    func testUnknownCoverageClaimsNothingAndSpansCountAsRecorded() throws {
        let calendar = try seoul()
        let day = calendar.startOfDay(for: t0)
        let clock = { (h: Double, m: Double) in day.addingTimeInterval(h * 3600 + m * 60) }
        let spans = [span(clock(9, 0), clock(10, 0)), span(clock(15, 0), clock(16, 0))]
        let old = ActivityDay.build(spans: spans, rules: ActivityRules(), day: day, calendar: calendar)
        XCTAssertFalse(old.coverageKnown)
        XCTAssertEqual(old.notRecorded, [])
        XCTAssertNil(old.notRecordedNote)
        // Imported time in the morning, coverage from the afternoon: nothing is claimed before coverage began.
        let mixed = ActivityDay.build(spans: spans, rules: ActivityRules(), day: day,
                                      coverage: [DateInterval(start: clock(14, 0), end: clock(24, 0))], calendar: calendar)
        XCTAssertEqual(mixed.notRecorded, [])
        // A span inside a gap between two recording intervals still counts as recorded.
        let between = ActivityDay.build(spans: [span(clock(12, 0), clock(13, 0))], rules: ActivityRules(), day: day,
                                        coverage: [DateInterval(start: clock(0, 0), end: clock(11, 0)), DateInterval(start: clock(14, 0), end: clock(24, 0))],
                                        calendar: calendar)
        XCTAssertEqual(between.notRecorded, [DateInterval(start: clock(11, 0), end: clock(12, 0)), DateInterval(start: clock(13, 0), end: clock(14, 0))])
    }

    func testCoverageSurvivesAKillSleepAndMidnight() throws {
        let log = try temporaryLog(), calendar = try seoul()
        let day = calendar.startOfDay(for: t0)
        let clock = { (h: Double, m: Double) in day.addingTimeInterval(h * 3600 + m * 60) }
        XCTAssertNil(log.readCoverage(day: day, calendar: calendar), "no sidecar: unknown")

        // Opened at 9:00, heartbeats every 30 s, killed at 12:00:25: the last beat (12:00:00) is what's kept.
        var recording = ActivityRecording()
        try log.recordCoverage(try XCTUnwrap(recording.begin(at: clock(9, 0))), calendar: calendar)
        for minute in stride(from: 0.5, through: 180, by: 0.5) {
            try log.recordCoverage(try XCTUnwrap(recording.beat(at: clock(9, minute))), calendar: calendar)
        }
        XCTAssertNil(recording.beat(at: clock(12, 0)), "nothing moved, nothing to write")
        // Relaunched at 14:00.
        recording = ActivityRecording()
        try log.recordCoverage(try XCTUnwrap(recording.begin(at: clock(14, 0))), calendar: calendar)
        try log.recordCoverage(try XCTUnwrap(recording.beat(at: clock(14, 0.5))), calendar: calendar)
        XCTAssertEqual(log.readCoverage(day: day, calendar: calendar),
                       [DateInterval(start: clock(9, 0), end: clock(12, 0)), DateInterval(start: clock(14, 0), end: clock(14, 0.5))])
        // The Mac sleeps at 22:00 and wakes at 7:00 the next day; the first beat after waking covers the sleep, split at midnight.
        try log.recordCoverage(try XCTUnwrap(recording.beat(at: clock(22, 0))), calendar: calendar)
        try log.recordCoverage(try XCTUnwrap(recording.beat(at: clock(31, 0))), calendar: calendar)
        try log.recordCoverage(try XCTUnwrap(recording.beat(at: clock(31, 0.5))), calendar: calendar)
        let first = try XCTUnwrap(log.readCoverage(day: day, calendar: calendar))
        XCTAssertEqual(first, [DateInterval(start: clock(9, 0), end: clock(12, 0)), DateInterval(start: clock(14, 0), end: clock(24, 0))])
        let next = clock(24, 0)
        XCTAssertEqual(log.readCoverage(day: next, calendar: calendar), [DateInterval(start: next, end: clock(31, 0.5))])
        let built = ActivityDay.build(spans: [], rules: ActivityRules(), day: day, coverage: first, calendar: calendar)
        XCTAssertEqual(built.notRecorded, [DateInterval(start: day, end: clock(9, 0)), DateInterval(start: clock(12, 0), end: clock(14, 0))],
                       "the sleep is away, the kill is not recorded")
        let today = ActivityDay.build(spans: [], rules: ActivityRules(), day: next, coverage: log.readCoverage(day: next, calendar: calendar),
                                      now: clock(31, 0.5), calendar: calendar)
        XCTAssertEqual(today.notRecorded, [], "recording since midnight")
        // Pausing ends the interval; resuming starts another.
        XCTAssertEqual(recording.end(at: clock(32, 0), calendar: calendar), DateInterval(start: next, end: clock(32, 0)))
        XCTAssertNil(recording.live(at: clock(33, 0)))
        XCTAssertNil(recording.beat(at: clock(33, 0)))
    }

    func testCoverageSidecarIsPrivateBoundedAndGoesWithTheDay() throws {
        let log = try temporaryLog()
        let calendar = Calendar.current, now = Date()
        for back in [0, 1, 400] {
            let day = calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now))!.addingTimeInterval(3600)
            try log.recordCoverage(DateInterval(start: day, end: day.addingTimeInterval(600)), calendar: calendar)
            try log.append([span(day, day.addingTimeInterval(60))], calendar: calendar)
        }
        let url = log.coverageURL(for: now)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, 0o600)
        XCTAssertLessThan(try Data(contentsOf: url).count, 64, "the write stays tiny")
        log.prune(now: now)
        XCTAssertEqual(log.coverageFiles().count, 2, "pruned with the day files")
        log.deleteDay(now)
        XCTAssertNil(log.readCoverage(day: now), "deleted with the day")
        XCTAssertEqual(log.coverageFiles().count, 1)

        // Bad or forged contents read as unknown; a symlink is neither read nor written through.
        try Data("[[1,".utf8).write(to: url)
        XCTAssertNil(log.readCoverage(day: now))
        try FileManager.default.removeItem(at: url)
        let target = log.folder.appendingPathComponent("elsewhere.txt")
        try Data("[[0,1]]".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertNil(log.readCoverage(day: now), "symlinks are not followed")
        XCTAssertThrowsError(try log.recordCoverage(DateInterval(start: now, end: now.addingTimeInterval(1))))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "[[0,1]]")
        try FileManager.default.removeItem(at: url)
        try Data(count: 70 * 1024).write(to: url)
        XCTAssertNil(log.readCoverage(day: now), "oversized sidecars are ignored")

        log.deleteAll()
        XCTAssertTrue(log.coverageFiles().isEmpty, "delete everything removes coverage")
        XCTAssertTrue(log.dayFiles().isEmpty)
    }

    func testAnUnreadableCoverageSidecarIsSetAsideAndTheDayStaysUnknown() throws {
        let log = try temporaryLog()
        let calendar = Calendar.current, now = Date()
        let start = calendar.startOfDay(for: now).addingTimeInterval(3600)
        let url = log.coverageURL(for: start, calendar: calendar), bad = log.unreadableCoverageURL(for: start, calendar: calendar)
        try FileManager.default.createDirectory(at: log.folder, withIntermediateDirectories: true)
        try Data("[[1,".utf8).write(to: url)
        try log.recordCoverage(DateInterval(start: start, end: start.addingTimeInterval(60)), calendar: calendar)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "no fresh claim replaces the unreadable one")
        XCTAssertEqual(try String(contentsOf: bad, encoding: .utf8), "[[1,", "the unreadable record is kept aside")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: bad.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, 0o600)
        try log.recordCoverage(DateInterval(start: start, end: start.addingTimeInterval(120)), calendar: calendar)
        try log.recordCoverage(DateInterval(start: start.addingTimeInterval(600), end: start.addingTimeInterval(660)), calendar: calendar)
        XCTAssertNil(log.readCoverage(day: start, calendar: calendar), "unknown for the rest of the day")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // An oversized sidecar the same way, replacing the earlier one set aside; other days are unaffected.
        try Data(count: 70 * 1024).write(to: url)
        try log.recordCoverage(DateInterval(start: start, end: start.addingTimeInterval(60)), calendar: calendar)
        XCTAssertEqual(try Data(contentsOf: bad).count, 70 * 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let other = calendar.date(byAdding: .day, value: -1, to: start)!
        try log.recordCoverage(DateInterval(start: other, end: other.addingTimeInterval(60)), calendar: calendar)
        XCTAssertNotNil(log.readCoverage(day: other, calendar: calendar))

        // Deleting the day clears it, so recording counts again; pruning and delete everything take it too.
        log.deleteDay(start, calendar: calendar)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))
        try log.recordCoverage(DateInterval(start: start, end: start.addingTimeInterval(60)), calendar: calendar)
        XCTAssertNotNil(log.readCoverage(day: start, calendar: calendar))
        let old = calendar.date(byAdding: .day, value: -400, to: start)!
        try Data("x".utf8).write(to: log.unreadableCoverageURL(for: old, calendar: calendar))
        try Data("x".utf8).write(to: bad)
        XCTAssertEqual(log.coverageFiles().filter { $0.hasSuffix(".bad") }.count, 2)
        log.prune(now: now, calendar: calendar)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.unreadableCoverageURL(for: old, calendar: calendar).path), "pruned with the day")
        log.deleteAll()
        XCTAssertTrue(log.coverageFiles().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))
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
    ///
    /// One deliberate exception: burro-inspect's `--activity-import-dayflow` (DayflowImportCommand.swift)
    /// writes Dayflow's history into the local activity log through `DayflowImport`. It may name
    /// `DayflowImport` and its counts-only `Report`, but it is held to the rest: it must not touch spans,
    /// titles, hosts or app names (so it can't print them), the activity types themselves, the
    /// network, processes, logging, the orchestrator or MCP. Every other BurroInspect file, and every
    /// shared surface, still may not mention activity at all, including `DayflowImport`.
    func testActivityDataStaysOutOfSharedSurfaces() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let importer = "Sources/BurroInspect/DayflowImportCommand.swift"
        var files = ["Sources/BurroCore/Orchestrator.swift", "Sources/BurroCore/OrchestratorTools.swift",
                     "Sources/Burro/Stores/AppStore+Orchestrator.swift", "Sources/Burro/Stores/OrchestratorStore.swift",
                     "Sources/BurroCore/RemoteAgentMonitor.swift", "Sources/BurroCore/UsageHTTP.swift", "Sources/BurroCore/ConvexClient.swift",
                     // What the Orchestrator's model reads: its tools, triage and the Brief.
                     "Sources/BurroCore/OrchestratorToolsMore.swift", "Sources/BurroCore/OrchestratorTriage.swift", "Sources/BurroCore/OrchestratorBrief.swift",
                     "Sources/Burro/Stores/OrchestratorBriefStore.swift", "Sources/Burro/Stores/AppStore+Brief.swift"]
        for folder in ["Sources/BurroMCP", "Sources/BurroInspect", "Sources/BurroCore/Resources"] {
            files += try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path).map { "\(folder)/\($0)" }
        }
        XCTAssertTrue(files.contains(importer))
        // The tracked day and what is derived from it (agent time while you were away, the Today store holding both).
        let markers = ["ActivityLog", "ActivitySpan", "ActivityDay", "ActivityKey", "ActivityTracker", "activityTracker", "Burro/Activity",
                       "AgentAwayTime", "awayAgentTime", "TodayStore"]
        for file in files where file != importer {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for marker in markers + ["DayflowImport.", "DayflowImport(", "readCards"] {
                XCTAssertFalse(text.contains(marker), "\(file) mentions \(marker)")
            }
        }
        let command = try String(contentsOf: root.appendingPathComponent(importer), encoding: .utf8)
        for marker in markers + ["ActivityRules", "ActivityBlock", "readCards", "DayflowImport.Card", ".title", ".host", ".app", "span(",
                                 "URLSession", "URLRequest", "Process(", "CommandRunner", "NSLog", "os_log", "Logger(",
                                 "Orchestrator", "state.json", "BurroMCP", "Remote"] {
            XCTAssertFalse(command.contains(marker), "\(importer) must not use \(marker)")
        }
        // The report it prints can only hold numbers (and categories, which name no app, site or title).
        for child in Mirror(reflecting: DayflowImport.Report()).children {
            XCTAssertTrue(child.value is Int || child.value is [ActivityCategory: TimeInterval], "Report.\(child.label ?? "?") isn't a count")
        }
        let tracking = try ["ActivityPrivacy", "ActivityLog", "ActivityRecorder", "ActivityPresence", "ActivitySummary", "ActivityCategories", "ActivityTimeline",
                            "ActivityTimelineLayout", "ActivityImport", "ActivityCoverage", "AgentAwayTime"].map {
            try String(contentsOf: root.appendingPathComponent("Sources/BurroCore/\($0).swift"), encoding: .utf8)
        } + ["Stores/ActivityTracker", "Stores/TodayStore", "Support/ActivitySampler", "Views/Today/TodayActivity", "Views/Today/TodayDayView",
             "Views/Home/HomeActivity"].map {
            try String(contentsOf: root.appendingPathComponent("Sources/Burro/\($0).swift"), encoding: .utf8)
        }
        for text in tracking {
            for marker in ["URLSession", "print(", "NSLog", "os_log", "Logger(", "CommandRunner", "Process("] {
                XCTAssertFalse(text.contains(marker), "activity tracking code must not use \(marker)")
            }
        }
    }
}
