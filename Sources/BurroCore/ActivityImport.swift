// One-time import of Dayflow's timeline into the activity log, run from `burro-inspect
// --activity-import-dayflow`. Dayflow's database is opened read-only and immutable, and only
// `timeline_cards`' id, times, day, title, category, metadata and deleted flag are selected (never
// its summaries). Each card becomes one span marked `source: "dayflow"` with its own category,
// after the same privacy rules as live tracking: titles through `ActivityPrivacy.sanitize`;
// Personal cards, banking or private hosts, credential apps and private-window or bank words in a
// title become Private with no title, host or app. A day that already holds live spans keeps them
// and gets imported time only before its first live span; re-running replaces earlier imported
// spans and leaves live ones alone. The report holds counts only, never titles, hosts or apps.
import Foundation
import CSystem

public enum DayflowImport {
    public static let source = "dayflow"
    /// Longer cards are taken as broken.
    public static let maximumCard: TimeInterval = 6 * 3600
    /// Imported spans have no real bundle id. A colon can't appear in one, so these never collide.
    public static let bundlePrefix = "dayflow:"
    public static let webBundle = "dayflow:web", privateBundle = "dayflow:private", unknownBundle = "dayflow:unknown"

    /// One row of `timeline_cards`, as read (only the columns the import needs).
    public struct Card: Sendable, Equatable {
        public var id: Int64
        public var start: Int64
        public var end: Int64
        public var day: String
        public var title: String?
        public var category: String?
        public var metadata: String?
        public var deleted: Bool
        public init(id: Int64, start: Int64, end: Int64, day: String, title: String?, category: String?, metadata: String?, deleted: Bool) {
            self.id = id; self.start = start; self.end = end; self.day = day
            self.title = title; self.category = category; self.metadata = metadata; self.deleted = deleted
        }
    }

    public enum Outcome: Sendable, Equatable {
        case span(ActivitySpan)
        case idle, deleted, invalid
    }

    /// Counts only: nothing here can carry a title, host or app name.
    public struct Report: Sendable, Equatable {
        public var cardsRead = 0
        public var deleted = 0
        public var idle = 0
        public var invalid = 0
        /// Days older than the retention window, which pruning would delete anyway.
        public var tooOld = 0
        /// Cards that became Private.
        public var madePrivate = 0
        /// Pieces (after the midnight split) dropped or shortened because live tracking had started that day.
        public var trimmedForLive = 0
        /// Earlier imported spans removed before writing.
        public var replaced = 0
        public var spansWritten = 0
        public var days = 0
        /// Written time per category, as imported (your rules can still change it on read).
        public var seconds: [ActivityCategory: TimeInterval] = [:]
        public init() {}
    }

    // MARK: Mapping

    public static func category(_ dayflow: String?) -> ActivityCategory? {
        switch dayflow?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "engineering / product": .build
        case "distraction": .break
        case "data & insights": .analytics
        case "research & strategy": .docs
        case "communication": .comms
        case "personal", "idle": nil
        default: .other
        }
    }

    /// App names that count as credential apps on top of `ActivityPrivacy.isCredentialApp`'s fragments.
    static let credentialNames = ["system settings", "system preferences", "security agent", "loginwindow"]

    /// One card as a span, or why it was skipped. `calendar` decides the card's `day`.
    public static func span(for card: Card, privateHosts: [String] = [], calendar: Calendar = .current) -> Outcome {
        if card.deleted { return .deleted }
        let name = card.category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name == "idle" { return .idle }
        let start = Date(timeIntervalSince1970: TimeInterval(card.start)), end = Date(timeIntervalSince1970: TimeInterval(card.end))
        guard card.end > card.start, end.timeIntervalSince(start) <= maximumCard, let dayStart = day(card.day, calendar: calendar),
              let earliest = calendar.date(byAdding: .day, value: -1, to: dayStart),
              let latest = calendar.date(byAdding: .day, value: 2, to: dayStart),
              start >= earliest, end <= latest else { return .invalid }

        let sites = appSites(card.metadata)
        let primary = site(sites.primary), secondary = site(sites.secondary)
        let hidden = name == "personal" || [primary, secondary].contains { site in
            switch site {
            case .host(let host): ActivityPrivacy.isPrivateHost(host, extra: privateHosts)
            case .app(let app): isCredential(app)
            case nil: false
            }
        } || card.title.map { title in
            let lower = title.lowercased()
            return ActivityPrivacy.isPrivateWindow(title: title) || (ActivityPrivacy.bankingWords + ["paypal", "boursorama"]).contains(where: lower.contains)
        } ?? false

        var key: ActivityKey
        if hidden {
            key = ActivityKey(bundleID: privateBundle, app: ActivityPrivacy.privateHost, title: nil, host: nil, isPrivate: true)
        } else {
            let title = card.title.flatMap(ActivityPrivacy.sanitize)
            switch primary {
            case .host(let host): key = ActivityKey(bundleID: webBundle, app: "Web", title: title, host: host, isPrivate: false)
            case .app(let app): key = ActivityKey(bundleID: bundlePrefix + slug(app), app: app, title: title, host: nil, isPrivate: false)
            case nil: key = ActivityKey(bundleID: unknownBundle, app: "Dayflow", title: title, host: nil, isPrivate: false)
            }
        }
        var span = ActivitySpan(key, start: start, end: end)
        span.source = source
        span.category = hidden ? nil : category(card.category) ?? .other
        return .span(span)
    }

    enum Site: Equatable { case host(String), app(String) }

    /// A host when the value parses as one; otherwise an app name, one line, scrubbed and clipped like live app names.
    static func site(_ raw: String?) -> Site? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, raw.count <= 2000 else { return nil }
        if let host = ActivityPrivacy.host(fromAddress: raw) { return .host(host) }
        guard let clean = ActivityPrivacy.sanitize(title: raw) else { return nil }
        return .app(String(clean.prefix(80)))
    }

    static func isCredential(_ app: String) -> Bool {
        let lower = app.lowercased()
        return ActivityPrivacy.isCredentialApp(lower) || credentialNames.contains { lower.contains($0) }
    }

    /// `appSites.primary` and `.secondary` from a card's metadata JSON; nothing else is read.
    static func appSites(_ metadata: String?) -> (primary: String?, secondary: String?) {
        guard let metadata, metadata.utf8.count <= 256 * 1024,
              let object = try? JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any],
              let sites = object["appSites"] as? [String: Any] else { return (nil, nil) }
        return (sites["primary"] as? String, sites["secondary"] as? String)
    }

    /// "Google Chrome" → "google-chrome".
    static func slug(_ app: String) -> String {
        var out = ""
        for ch in app.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) } else if !out.isEmpty && out.last != "-" { out.append("-") }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "app" : String(out.prefix(60))
    }

    static func day(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.prefix(10).split(separator: "-")
        guard text.count >= 10, parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (2000...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    // MARK: Icons

    /// Real bundle ids for well-known app names, only to borrow an installed app's icon.
    static let iconBundles: [String: String] = [
        "xcode": "com.apple.dt.Xcode", "claude": "com.anthropic.claudefordesktop", "chatgpt": "com.openai.chat", "codex": "com.openai.codex",
        "slack": "com.tinyspeck.slackmacgap", "discord": "com.hnc.Discord", "terminal": "com.apple.Terminal", "ghostty": "com.mitchellh.ghostty",
        "iterm2": "com.googlecode.iterm2", "iterm": "com.googlecode.iterm2", "cursor": "com.todesktop.230313mzl4w4u92",
        "visual-studio-code": "com.microsoft.VSCode", "vs-code": "com.microsoft.VSCode", "vscode": "com.microsoft.VSCode", "zed": "dev.zed.Zed",
        "figma": "com.figma.Desktop", "notion": "notion.id", "obsidian": "md.obsidian", "linear": "com.linear", "safari": "com.apple.Safari",
        "google-chrome": "com.google.Chrome", "chrome": "com.google.Chrome", "arc": "company.thebrowser.Browser", "firefox": "org.mozilla.firefox",
        "mail": "com.apple.mail", "messages": "com.apple.MobileSMS", "notes": "com.apple.Notes", "spotify": "com.spotify.client",
        "music": "com.apple.Music", "finder": "com.apple.finder", "preview": "com.apple.Preview", "blender": "org.blenderfoundation.blender",
        "godot": "org.godotengine.godot", "simulator": "com.apple.iphonesimulator", "whatsapp": "net.whatsapp.WhatsApp",
        "telegram": "ru.keepcoding.Telegram", "zoom": "us.zoom.xos", "calendar": "com.apple.iCal", "superhuman": "com.superhuman.electron",
        "android-studio": "com.google.android.studio", "rive": "app.rive.editor", "warp": "dev.warp.Warp-Stable",
    ]

    public static func isImported(bundleID: String) -> Bool { bundleID.hasPrefix(bundlePrefix) }

    /// The bundle id whose icon an imported app may show, if it's a well-known app.
    public static func iconBundleID(for bundleID: String) -> String? {
        guard isImported(bundleID: bundleID) else { return nil }
        return iconBundles[String(bundleID.dropFirst(bundlePrefix.count))]
    }

    /// Imported placeholders that stand for many apps (all web time, all Private time): an app rule on them would mean nothing.
    public static func isGroup(bundleID: String) -> Bool { [webBundle, privateBundle, unknownBundle].contains(bundleID) }

    // MARK: Reading Dayflow

    public enum ReadError: Error, LocalizedError, Equatable {
        case notAFile, cannotOpen, unsupported, incomplete
        public var errorDescription: String? {
            switch self {
            case .notAFile: "The database isn't a regular file."
            case .cannotOpen: "The database couldn't be opened read-only."
            case .unsupported: "The database has no timeline_cards table in the expected shape."
            case .incomplete: "The database couldn't be read completely."
            }
        }
    }

    /// Every card, deleted ones included (so they can be counted). Opened read-only and immutable:
    /// no locks, journal or WAL changes, and the connection is query-only. With `immutable`, rows
    /// still sitting in an unmerged `-wal` file are not seen (`walPending` tells you if one exists).
    public static func readCards(database url: URL) throws -> [Card] {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ReadError.notAFile }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        guard let path = url.path.addingPercentEncoding(withAllowedCharacters: allowed) else { throw ReadError.cannotOpen }
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro&immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            sqlite3_close(db)
            throw ReadError.cannotOpen
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else { throw ReadError.cannotOpen }
        let sql = "SELECT id, start_ts, end_ts, day, title, category, metadata, is_deleted FROM timeline_cards ORDER BY start_ts, id"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ReadError.unsupported }
        defer { sqlite3_finalize(statement) }
        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL, let value = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: value)
        }
        func integer(_ column: Int32) -> Int64? {
            sqlite3_column_type(statement, column) == SQLITE_INTEGER ? sqlite3_column_int64(statement, column) : nil
        }
        var cards: [Card] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return cards }
            guard step == SQLITE_ROW, cards.count < 500_000 else { throw ReadError.incomplete }
            // A row with missing or non-integer times reads as an invalid card rather than failing the import.
            cards.append(Card(id: integer(0) ?? 0, start: integer(1) ?? 0, end: integer(2) ?? 0, day: text(3) ?? "",
                              title: text(4), category: text(5), metadata: text(6), deleted: (integer(7) ?? 0) != 0))
        }
    }

    /// True when the database has a non-empty `-wal` file beside it (checked by size only, never opened).
    public static func walPending(database url: URL) -> Bool {
        var info = stat()
        return lstat(url.path + "-wal", &info) == 0 && info.st_size > 0
    }

    // MARK: Writing

    /// Maps every card and replaces the log's earlier Dayflow spans with them. `dryRun` reads and
    /// counts everything and writes nothing.
    public static func run(cards: [Card], log: ActivityLog, dryRun: Bool, now: Date = Date(), calendar: Calendar = .current) throws -> Report {
        var report = Report()
        report.cardsRead = cards.count
        let privateHosts = ActivityRules.load(from: log.rulesURL).privateHosts
        let oldest = calendar.date(byAdding: .day, value: -(ActivityLog.retentionDays - 1), to: calendar.startOfDay(for: now)) ?? .distantPast
        var spans: [ActivitySpan] = []
        for card in cards {
            switch span(for: card, privateHosts: privateHosts, calendar: calendar) {
            case .deleted: report.deleted += 1
            case .idle: report.idle += 1
            case .invalid: report.invalid += 1
            case .span(let span):
                if span.end <= oldest { report.tooOld += 1; continue }
                if span.isPrivate { report.madePrivate += 1 }
                spans.append(span)
            }
        }
        try log.replaceImported(source: source, with: spans, dryRun: dryRun, oldest: oldest, calendar: calendar, report: &report)
        return report
    }

    /// Reads the database and runs the import into `folder`.
    public static func run(database: URL, folder: URL = ActivityLog.defaultFolder, dryRun: Bool) throws -> Report {
        try run(cards: readCards(database: database), log: ActivityLog(folder: folder), dryRun: dryRun)
    }

    public static var defaultDatabase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dayflow/chunks.sqlite")
    }
    public static var defaultActivityFolder: URL { ActivityLog.defaultFolder }
    public static var retentionDays: Int { ActivityLog.retentionDays }
}

extension ActivityLog {
    /// Removes every stored span from `source` and writes `spans` in their place, split at local
    /// midnight. On a day with live spans, imported time is cut at the first live span. Days are
    /// rewritten whole (owner-only, through a temporary file; symlinks and non-regular files are
    /// refused); lines that aren't `source` spans are kept byte for byte.
    func replaceImported(source: String, with spans: [ActivitySpan], dryRun: Bool, oldest: Date, calendar: Calendar,
                         report: inout DayflowImport.Report) throws {
        var byDay: [String: [ActivitySpan]] = [:]
        for span in spans {
            var piece = span
            while piece.end > piece.start {
                let dayStart = calendar.startOfDay(for: piece.start)
                let next = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? piece.end
                var part = piece
                part.end = min(piece.end, next)
                if part.end > oldest { byDay[TodoDay.key(dayStart, calendar: calendar), default: []].append(part) }
                piece.start = part.end
            }
        }
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys // so a re-run writes the same bytes
        let names = Set(dayFiles().map { String($0.prefix(10)) }).union(byDay.keys)
        var ready = false
        for name in names.sorted() {
            let url = folder.appendingPathComponent(name + ".jsonl")
            var info = stat()
            let exists = lstat(url.path, &info) == 0
            if exists, info.st_mode & S_IFMT != S_IFREG { throw CocoaError(.fileWriteInvalidFileName) }
            let data = exists ? Self.readRegularFile(url, limit: Self.fileLimit + 64 * 1024) ?? Data() : Data()
            var kept: [Data] = [], removed = 0
            var firstLive: Date?
            for line in data.split(separator: UInt8(ascii: "\n")) {
                let span = line.count <= 4096 ? try? decoder.decode(ActivitySpan.self, from: Data(line)) : nil
                if span?.source == source { removed += 1; continue }
                if let span, span.source == nil { firstLive = min(firstLive ?? span.start, span.start) }
                kept.append(Data(line))
            }
            var added: [ActivitySpan] = []
            for var span in (byDay[name] ?? []).sorted(by: { $0.start < $1.start }) {
                if let firstLive, span.end > firstLive {
                    report.trimmedForLive += 1
                    span.end = firstLive
                    if span.end <= span.start { continue }
                }
                added.append(span)
            }
            guard removed > 0 || !added.isEmpty else { continue }
            report.replaced += removed
            report.spansWritten += added.count
            if !added.isEmpty { report.days += 1 }
            for span in added { report.seconds[span.isPrivate ? .private : span.category ?? .other, default: 0] += span.duration }
            var out = Data()
            for line in kept { out.append(line); out.append(UInt8(ascii: "\n")) }
            for span in added { out.append(try encoder.encode(span)); out.append(UInt8(ascii: "\n")) }
            guard out.count <= Self.fileLimit else { throw CocoaError(.fileWriteOutOfSpace) }
            guard !dryRun else { continue }
            if !ready { try Self.ensurePrivateFolder(folder); ready = true }
            try Self.writePrivateFile(url, data: out)
        }
    }
}
