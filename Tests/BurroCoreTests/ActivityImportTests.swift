import XCTest
import CSystem
@testable import BurroCore

/// The Dayflow import: the span format's category and source, category precedence, card mapping
/// and its privacy rules, one block per imported card, and an end-to-end run on a fixture database.
/// Never opens the real Dayflow database or the real activity folder.
final class ActivityImportTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()
    /// `hour` hours after the start of `day` ("2026-11-07") in Seoul.
    private func time(_ day: String, _ hour: Double) -> Date {
        DayflowImport.day(day, calendar: calendar)!.addingTimeInterval(hour * 3600)
    }
    private func card(_ id: Int64, _ day: String, _ from: Double, _ to: Double, _ category: String?, title: String? = nil,
                      primary: String? = nil, secondary: String? = nil, deleted: Bool = false) -> DayflowImport.Card {
        var sites: [String: String] = [:]
        sites["primary"] = primary; sites["secondary"] = secondary
        let metadata = String(data: try! JSONSerialization.data(withJSONObject: ["appSites": sites, "distractions": [["title": "skip me"]]]), encoding: .utf8)
        return DayflowImport.Card(id: id, start: Int64(time(day, from).timeIntervalSince1970), end: Int64(time(day, to).timeIntervalSince1970),
                                  day: day, title: title, category: category, metadata: metadata, deleted: deleted)
    }
    private func mapped(_ card: DayflowImport.Card, privateHosts: [String] = []) throws -> ActivitySpan {
        struct NotASpan: Error {}
        guard case .span(let span) = DayflowImport.span(for: card, privateHosts: privateHosts, calendar: calendar) else { throw NotASpan() }
        return span
    }
    // Card- and email-shaped strings, assembled here so no such literal sits in the repository.
    private let cardNumber = ["4111", "1111", "1111", "1111"].joined(separator: " ")
    private let email = ["someone", "example.com"].joined(separator: "@")

    // MARK: Span format

    func testSpanFormatCarriesCategoryAndSourceAndRejectsAnythingElse() throws {
        var span = ActivitySpan(ActivityKey(bundleID: "dayflow:xcode", app: "Xcode", title: "Work", host: nil, isPrivate: false),
                                start: Date(timeIntervalSince1970: 1_794_150_000), end: Date(timeIntervalSince1970: 1_794_150_600))
        span.category = .build; span.source = "dayflow"
        let line = try XCTUnwrap(String(data: try JSONEncoder().encode(span), encoding: .utf8))
        XCTAssertTrue(line.contains(#""category":"build""#) && line.contains(#""source":"dayflow""#), line)
        XCTAssertEqual(try JSONDecoder().decode(ActivitySpan.self, from: Data(line.utf8)), span)

        let live = #"{"start":1794150000,"end":1794150060,"bundle":"com.apple.Notes","app":"Notes","title":"One"}"#
        let old = try JSONDecoder().decode(ActivitySpan.self, from: Data(live.utf8))
        XCTAssertNil(old.category); XCTAssertNil(old.source, "existing files still read")
        XCTAssertFalse(try XCTUnwrap(String(data: try JSONEncoder().encode(old), encoding: .utf8)).contains("source"), "live spans are unchanged")

        let base = #"{"start":1794150000,"end":1794150060,"bundle":"x","app":"x""#
        for bad in [#","category":"build"}"#, #","category":"build","source":"elsewhere"}"#, #","source":"elsewhere"}"#,
                    #","category":"private","source":"dayflow"}"#, #","category":"nonsense","source":"dayflow"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(ActivitySpan.self, from: Data((base + bad).utf8)), bad)
        }
        XCTAssertNoThrow(try JSONDecoder().decode(ActivitySpan.self, from: Data((base + #","private":true,"source":"dayflow"}"#).utf8)))

        let redacted = ActivitySpan(ActivityKey(bundleID: DayflowImport.webBundle, app: "Web", title: "Payroll", host: "pay.acme.dev", isPrivate: false),
                                    start: span.start, end: span.end)
        var imported = redacted; imported.source = "dayflow"; imported.category = .docs
        let scrubbed = imported.redacted(host: "acme.dev")
        XCTAssertTrue(scrubbed.isPrivate); XCTAssertNil(scrubbed.title); XCTAssertNil(scrubbed.category)
        XCTAssertEqual(scrubbed.source, "dayflow", "a scrubbed imported span is still replaced by a re-run")
    }

    func testStoredCategoryComesAfterYourRulesAndBeforeBuiltIns() {
        let base = ActivityRules()
        let yours = ActivityRules(apps: ["dayflow:xcode": .design], hosts: ["x.com": .docs])
        XCTAssertEqual(base.category(bundleID: DayflowImport.webBundle, host: "x.com", title: nil, isPrivate: false, stored: .analytics), .analytics,
                       "stored beats the built-in host")
        XCTAssertEqual(yours.category(bundleID: DayflowImport.webBundle, host: "x.com", title: nil, isPrivate: false, stored: .analytics), .docs,
                       "your host rule beats stored")
        XCTAssertEqual(yours.category(bundleID: "dayflow:xcode", host: nil, title: nil, isPrivate: false, stored: .comms), .design,
                       "your app rule beats stored")
        XCTAssertEqual(yours.category(bundleID: "dayflow:xcode", host: nil, title: nil, isPrivate: true, stored: .comms), .private, "Private wins")
        XCTAssertEqual(base.category(bundleID: "com.apple.dt.Xcode", host: nil, title: nil, isPrivate: false), .build, "live spans unchanged")
    }

    // MARK: Mapping

    func testCardMappingCategoriesAndSites() throws {
        let d = "2026-11-07"
        let expected: [(String?, ActivityCategory)] = [("Engineering / Product", .build), ("Distraction", .break), ("Data & Insights", .analytics),
                                                       ("Research & Strategy", .docs), ("Communication", .comms), ("System", .other),
                                                       ("Something new", .other), (nil, .other)]
        for (name, category) in expected {
            let span = try mapped(card(1, d, 9, 10, name, title: "T", primary: "Xcode"))
            XCTAssertEqual(span.category, category, name ?? "nil")
            XCTAssertEqual(span.source, "dayflow")
        }
        XCTAssertEqual(DayflowImport.span(for: card(1, d, 9, 10, "Idle"), calendar: calendar), .idle)
        XCTAssertEqual(DayflowImport.span(for: card(1, d, 9, 10, "Distraction", deleted: true), calendar: calendar), .deleted)

        let web = try mapped(card(1, d, 9, 10, "Communication", title: "Inbox", primary: "mail.google.com"))
        XCTAssertEqual(web.host, "mail.google.com"); XCTAssertEqual(web.bundleID, DayflowImport.webBundle); XCTAssertEqual(web.app, "Web")
        let app = try mapped(card(1, d, 9, 10, "Engineering / Product", title: "Build", primary: "Google Chrome"))
        XCTAssertNil(app.host); XCTAssertEqual(app.app, "Google Chrome"); XCTAssertEqual(app.bundleID, "dayflow:google-chrome")
        XCTAssertEqual(DayflowImport.iconBundleID(for: app.bundleID), "com.google.Chrome")
        XCTAssertEqual(try mapped(card(1, d, 9, 10, "System", primary: String(repeating: "A", count: 200))).app.count, 80, "app names are clipped")
        let bare = try mapped(card(1, d, 9, 10, "System"))
        XCTAssertEqual(bare.bundleID, DayflowImport.unknownBundle)
        for id in [web.bundleID, app.bundleID, bare.bundleID, DayflowImport.privateBundle] {
            XCTAssertTrue(DayflowImport.isImported(bundleID: id)); XCTAssertTrue(id.contains(":"), "never a real bundle id")
        }
        XCTAssertNil(DayflowImport.iconBundleID(for: "com.apple.dt.Xcode"), "live ids are looked up as they are")
    }

    func testCardPrivacyRules() throws {
        let d = "2026-11-07"
        let clean = try mapped(card(1, d, 9, 10, "Communication", title: "Paid \(cardNumber), wrote to \(email)", primary: "mail.google.com"))
        XCTAssertEqual(clean.title, "Paid [number], wrote to [email]", "titles go through the live sanitiser")
        XCTAssertFalse(clean.title!.contains("4111"))

        func assertHidden(_ card: DayflowImport.Card, privateHosts: [String] = [], _ message: String) throws {
            let span = try mapped(card, privateHosts: privateHosts)
            XCTAssertTrue(span.isPrivate, message); XCTAssertNil(span.title, message); XCTAssertNil(span.host, message)
            XCTAssertEqual(span.app, ActivityPrivacy.privateHost, message); XCTAssertNil(span.category, message)
        }
        try assertHidden(card(1, d, 9, 10, "Personal", title: "Family dinner plans", primary: "Messages"), "Personal")
        try assertHidden(card(1, d, 9, 10, "Engineering / Product", title: "Checked statement", primary: "https://www.boursobank.com/x"), "banking host")
        try assertHidden(card(1, d, 9, 10, "Engineering / Product", title: "Payroll", primary: "pay.acme.dev"), privateHosts: ["acme.dev"], "your private host")
        for name in ["1Password", "Bitwarden", "Keychain Access", "Passwords", "System Settings"] {
            try assertHidden(card(1, d, 9, 10, "System", title: "Looked something up", primary: name), name)
        }
        try assertHidden(card(1, d, 9, 10, "Research & Strategy", title: "Notes", primary: "claude.ai", secondary: "paypal.com"), "a banking secondary site")
        try assertHidden(card(1, d, 9, 10, "Research & Strategy", title: "Reviewed bank transfers", primary: "Safari"), "a bank word in the title")
        try assertHidden(card(1, d, 9, 10, "Distraction", title: "Browsing in an Incognito window", primary: "Chrome"), "a private window in the title")
        XCTAssertFalse(try mapped(card(1, d, 9, 10, "Engineering / Product", title: "Fix", primary: "github.com")).isPrivate)
    }

    func testBrokenCardsAreInvalid() {
        let d = "2026-11-07"
        var reversed = card(1, d, 10, 9, "Distraction"); reversed.end = reversed.start
        for broken in [reversed, card(2, d, 9, 9, "Distraction"), card(3, d, 1, 7.5, "Distraction"),
                       card(4, d, 9, 10, "Distraction").with(day: "2026-10-01"), card(5, d, 9, 10, "Distraction").with(day: "nonsense")] {
            XCTAssertEqual(DayflowImport.span(for: broken, calendar: calendar), .invalid, "\(broken.id)")
        }
        // Dayflow's day starts at 4 am, so a card may sit on the next calendar day.
        XCTAssertNotEqual(DayflowImport.span(for: card(6, d, 25, 26, "Distraction"), calendar: calendar), .invalid)
    }

    // MARK: Timeline

    func testImportedSpansAreOneBlockEach() throws {
        let d = "2026-11-07"
        let spans = try [
            mapped(card(1, d, 9, 9 + 1 / 60, "Engineering / Product", title: "Short one", primary: "Xcode")),
            mapped(card(2, d, 9 + 1 / 60, 9 + 2 / 60, "Engineering / Product", title: "Short two", primary: "Xcode")),
            mapped(card(3, d, 9 + 2 / 60, 10, "Engineering / Product", title: "Long", primary: "github.com")),
            mapped(card(4, d, 10, 10.5, "Personal", title: "Hidden", primary: "Messages")),
            mapped(card(5, d, 10.5, 11, "Distraction", primary: "www.youtube.com")),
        ]
        // A live minute right after: it may not fold into the imported block.
        let live = ActivitySpan(ActivityPrivacy.key(bundleID: "com.apple.Notes", app: "Notes", title: "Live"), start: time(d, 11), end: time(d, 11 + 1 / 60))
        let day = ActivityDay.build(spans: spans + [live], rules: ActivityRules(), day: time(d, 0), calendar: calendar)
        XCTAssertEqual(day.blocks.map(\.title), ["Short one", "Short two", "Long", "Private", "youtube.com", "Notes · Live"])
        XCTAssertEqual(day.blocks.map(\.detail), ["Xcode", "Xcode", "github.com", nil, nil, nil])
        XCTAssertEqual(day.blocks.map(\.category), [.build, .build, .build, .private, .break, .docs])
        XCTAssertEqual(day.blocks[2].host, "github.com")
        XCTAssertNil(day.blocks[3].host)
        XCTAssertEqual(day.focus.longest?.duration, 5400, "focus stretches work on imported days (Private counts, as live)")
        XCTAssertEqual(day.apps.first?.name, "Web", "Most time works on imported days")
        XCTAssertEqual(day.sites.map(\.name), ["github.com", "www.youtube.com"])
        XCTAssertTrue(day.categories.contains { $0.category == .break && $0.seconds == 1800 })
    }

    // MARK: End to end

    /// A fixture `timeline_cards` table with every category, deleted, idle, Personal, banking, a
    /// sanitised title, a midnight crossing and a day that already holds live spans.
    private func fixtureDatabase(_ cards: [DayflowImport.Card]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-dayflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("chunks.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func quote(_ value: String?) -> String { value.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL" }
        var sql = """
        CREATE TABLE timeline_cards (id INTEGER PRIMARY KEY, start_ts INTEGER, end_ts INTEGER, day DATE, title TEXT, summary TEXT,
          detailed_summary TEXT, category TEXT, subcategory TEXT, metadata TEXT, video_summary_url TEXT, is_deleted INTEGER DEFAULT 0);
        """
        for card in cards {
            sql += """
            INSERT INTO timeline_cards VALUES (\(card.id), \(card.start), \(card.end), \(quote(card.day)), \(quote(card.title)), 'SUMMARY-SENTINEL',
              'DETAILED-SENTINEL', \(quote(card.category)), 'SUBCATEGORY-SENTINEL', \(quote(card.metadata)), 'VIDEO-SENTINEL', \(card.deleted ? 1 : 0));
            """
        }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        return url
    }

    func testEndToEndImportTwiceOnFixtures() throws {
        let d1 = "2026-11-07", d2 = "2026-11-08"
        let cards = [
            card(1, d1, 9, 10, "Engineering / Product", title: "Building the importer", primary: "Xcode"),
            card(2, d1, 10, 10.5, "Distraction", title: "Scrolling", primary: "x.com"),
            card(3, d1, 10.5, 11, "Data & Insights", title: "Retention chart", primary: "mixpanel.com"),
            card(4, d1, 11, 11.5, "Research & Strategy", title: "Reading docs", primary: "Claude"),
            card(5, d1, 11.5, 12, "Communication", title: "Paid \(cardNumber), wrote to \(email)", primary: "mail.google.com"),
            card(6, d1, 12, 12.25, "System", title: "Cleanup", primary: "Finder"),
            card(7, d1, 12.25, 13, "Idle"),
            card(8, d1, 13, 13.5, "Personal", title: "Family dinner plans", primary: "Messages"),
            card(9, d1, 13.5, 14, "Engineering / Product", title: "Gone", primary: "Xcode", deleted: true),
            card(10, d1, 14, 14.25, "Engineering / Product", title: "Checked statement", primary: "www.boursobank.com"),
            card(11, d1, 14.25, 14.5, "Engineering / Product", title: "Payroll", primary: "pay.acme.dev"),
            card(12, d1, 14.5, 14.5, "Distraction"),                                       // invalid: empty
            card(13, d1, 15, 23, "Distraction"),                                          // invalid: 8 hours
            card(14, d1, 23.5, 24.5, "Engineering / Product", title: "Late fix", primary: "github.com"), // crosses midnight
            card(15, d2, 18, 19, "Engineering / Product", title: "Before live", primary: "Xcode"),
            card(16, d2, 19.5, 20.5, "Engineering / Product", title: "Into live", primary: "Xcode"),  // cut at 20:00
            card(17, d2, 21, 22, "Distraction", title: "After live", primary: "youtube.com"),          // dropped
        ]
        let database = try fixtureDatabase(cards)
        let before = try Data(contentsOf: database)
        let folder = database.deletingLastPathComponent().appendingPathComponent("Activity")
        let log = ActivityLog(folder: folder)
        try ActivityRules(privateHosts: ["acme.dev"]).save(to: log.rulesURL)
        let liveSpans = [ActivitySpan(ActivityPrivacy.key(bundleID: "com.apple.dt.Xcode", app: "Xcode", title: "Live work"), start: time(d2, 20), end: time(d2, 21)),
                         ActivitySpan(ActivityPrivacy.key(bundleID: "com.apple.Safari", app: "Safari", title: "Docs", address: "docs.google.com"),
                                      start: time(d2, 21), end: time(d2, 23))]
        try log.append(liveSpans, calendar: calendar)
        let liveFile = try Data(contentsOf: log.url(for: time(d2, 0), calendar: calendar))
        let now = time(d2, 30)

        let read = try DayflowImport.readCards(database: database)
        XCTAssertEqual(read.count, cards.count)
        XCTAssertEqual(read.map(\.title), cards.map(\.title), "titles read; summaries never selected")

        // Dry run: counts, no writes.
        let other = database.deletingLastPathComponent().appendingPathComponent("Empty")
        let dry = try DayflowImport.run(cards: read, log: ActivityLog(folder: other), dryRun: true, now: now, calendar: calendar)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path), "a dry run creates nothing")
        XCTAssertEqual(dry.spansWritten, 14)

        let first = try DayflowImport.run(cards: read, log: log, dryRun: false, now: now, calendar: calendar)
        XCTAssertEqual(first.cardsRead, 17)
        XCTAssertEqual(first.deleted, 1); XCTAssertEqual(first.idle, 1); XCTAssertEqual(first.invalid, 2); XCTAssertEqual(first.tooOld, 0)
        XCTAssertEqual(first.madePrivate, 3, "Personal, banking host, your private host")
        XCTAssertEqual(first.trimmedForLive, 2)
        XCTAssertEqual(first.replaced, 0)
        // 10 pieces on day one; on day two the midnight card's second half and two before live time.
        XCTAssertEqual(first.spansWritten, 13); XCTAssertEqual(first.days, 2)
        XCTAssertEqual(first.seconds[.private], 3600)
        XCTAssertEqual(first.seconds[.build], 3600 + 3600 + 3600 + 1800, "Xcode, the midnight card, and day two cut at live")

        let filesAfterFirst = try log.dayFiles().sorted().map { try Data(contentsOf: folder.appendingPathComponent($0)) }
        let second = try DayflowImport.run(cards: try DayflowImport.readCards(database: database), log: log, dryRun: false, now: now, calendar: calendar)
        XCTAssertEqual(second.replaced, 13, "a re-run replaces what the first run wrote")
        XCTAssertEqual(second.spansWritten, 13)
        let filesAfterSecond = try log.dayFiles().sorted().map { try Data(contentsOf: folder.appendingPathComponent($0)) }
        XCTAssertEqual(filesAfterFirst, filesAfterSecond, "no duplicates: the second run writes the same days")

        // Live spans untouched, byte for byte, and imported time ends before them.
        let day2 = log.read(day: time(d2, 0), calendar: calendar)
        XCTAssertEqual(day2.filter { $0.source == nil }, liveSpans)
        let liveText = try XCTUnwrap(String(data: liveFile, encoding: .utf8))
        let day2Text = try XCTUnwrap(String(data: try Data(contentsOf: log.url(for: time(d2, 0), calendar: calendar)), encoding: .utf8))
        XCTAssertTrue(day2Text.hasPrefix(liveText), "live lines are kept as written")
        XCTAssertEqual(day2.filter { $0.source != nil }.map(\.title), ["Late fix", "Before live", "Into live"])
        XCTAssertEqual(day2.filter { $0.source != nil }.map(\.end).max(), time(d2, 20))

        // Midnight split and privacy outcomes on disk.
        let day1 = log.read(day: time(d1, 0), calendar: calendar)
        XCTAssertEqual(day1.count, 10)
        XCTAssertEqual(day1.last?.end, time(d1, 24), "the midnight card is split")
        XCTAssertEqual(day2.first { $0.title == "Late fix" }?.duration, 1800)
        XCTAssertEqual(day1.filter(\.isPrivate).count, 3)
        XCTAssertTrue(day1.filter(\.isPrivate).allSatisfy { $0.title == nil && $0.host == nil && $0.app == ActivityPrivacy.privateHost })
        let mail = try XCTUnwrap(day1.first { $0.host == "mail.google.com" })
        XCTAssertEqual(mail.title, "Paid [number], wrote to [email]")
        for name in try log.dayFiles() {
            let url = folder.appendingPathComponent(name)
            let text = try String(contentsOf: url, encoding: .utf8)
            for leak in ["SENTINEL", "4111", email, "skip me", "Family", "statement", "Payroll", "boursobank", "acme"] {
                XCTAssertFalse(text.contains(leak), "\(name) contains \(leak)")
            }
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        }

        // The day view: one block per card, imported title, Private reads only "Private".
        let view = ActivityDay.build(spans: day1, rules: ActivityRules.load(from: log.rulesURL), day: time(d1, 0), calendar: calendar)
        XCTAssertEqual(view.blocks.count, 10)
        XCTAssertEqual(view.blocks.first?.title, "Building the importer"); XCTAssertEqual(view.blocks.first?.detail, "Xcode")
        XCTAssertEqual(view.blocks.filter { $0.category == .private }.map(\.title), ["Private", "Private", "Private"])

        // The database was only read: same bytes, no journal or WAL left behind.
        XCTAssertEqual(try Data(contentsOf: database), before)
        for suffix in ["-journal", "-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + suffix), suffix)
        }
    }

    func testImportRefusesSymlinksAndNonFiles() throws {
        let database = try fixtureDatabase([card(1, "2026-11-07", 9, 10, "Distraction", primary: "x.com")])
        let link = database.deletingLastPathComponent().appendingPathComponent("link.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: database)
        XCTAssertThrowsError(try DayflowImport.readCards(database: link))
        XCTAssertThrowsError(try DayflowImport.readCards(database: database.deletingLastPathComponent()))

        let folder = database.deletingLastPathComponent().appendingPathComponent("Activity")
        let log = ActivityLog(folder: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("elsewhere.txt")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: log.url(for: time("2026-11-07", 0), calendar: calendar), withDestinationURL: target)
        XCTAssertThrowsError(try DayflowImport.run(cards: DayflowImport.readCards(database: database), log: log, dryRun: false,
                                                   now: time("2026-11-08", 0), calendar: calendar), "a symlinked day file is refused")
        XCTAssertEqual(try Data(contentsOf: target), Data())
    }

    func testDaysOlderThanRetentionAreSkipped() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-dayflow-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let report = try DayflowImport.run(cards: [card(1, "2026-11-07", 9, 10, "Distraction", primary: "x.com")], log: ActivityLog(folder: folder),
                                           dryRun: true, now: time("2027-11-20", 0), calendar: calendar)
        XCTAssertEqual(report.tooOld, 1); XCTAssertEqual(report.spansWritten, 0)
    }
}

private extension DayflowImport.Card {
    func with(day: String) -> Self { var copy = self; copy.day = day; return copy }
}
