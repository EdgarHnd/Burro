// The ⌘K command palette's search: plain items (pages, chats, projects, machines, actions) are
// folded once when the palette opens, then every keystroke filters and ranks them in memory.
// A title that starts with the query beats one that contains it, which beats one that merely
// holds its letters in order; matches at the start of a word score higher; chats that need you
// rank above working chats, which rank above the rest. Case and accents are ignored, ties keep
// the order the items were given in, and results are capped.
import Foundation

public struct CommandPaletteItem: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case page, chat, project, machine, action }
    /// How much a chat wants attention; everything that isn't a chat is `.none`.
    public enum Status: Int, Sendable, Comparable {
        case none = 0, recent, working, needsYou
        public static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }
    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String
    /// Searched as well as the title, at a lower weight: folder, project, machine, provider…
    public var keywords: [String]
    public var status: Status
    public var updatedAt: Date?
    /// Added to the score; a negative weight keeps secondary items (like "Ask about…") below their subject.
    public var weight: Int

    public init(id: String, kind: Kind, title: String, subtitle: String = "", keywords: [String] = [],
                status: Status = .none, updatedAt: Date? = nil, weight: Int = 0) {
        self.id = id; self.kind = kind; self.title = title; self.subtitle = subtitle
        self.keywords = keywords; self.status = status; self.updatedAt = updatedAt; self.weight = weight
    }
}

public struct CommandPaletteIndex: Sendable {
    public static let defaultLimit = 50
    /// Score tiers for a title match; keyword matches count 70% of these.
    enum Tier {
        static let prefix = 300, wordSubstring = 220, substring = 150, subsequence = 40, subsequenceBoundary = 40
    }
    static func statusBonus(_ status: CommandPaletteItem.Status) -> Int {
        switch status { case .needsYou: 60; case .working: 30; case .recent: 10; case .none: 0 }
    }
    static func kindBonus(_ kind: CommandPaletteItem.Kind) -> Int { kind == .page ? 15 : 0 }

    struct Field: Sendable {
        var chars: [Character]
        var boundaries: [Bool]
        init(_ text: String) {
            let folded = Array(CommandPaletteIndex.fold(text))
            chars = folded
            boundaries = folded.indices.map { i in
                i == 0 || !(folded[i - 1].isLetter || folded[i - 1].isNumber)
            }
        }
    }
    struct Entry: Sendable {
        var item: CommandPaletteItem
        var order: Int
        var title: Field
        var keywords: [Field]
    }

    public let items: [CommandPaletteItem]
    let entries: [Entry]

    public init(_ items: [CommandPaletteItem]) {
        self.items = items
        entries = items.enumerated().map { order, item in
            Entry(item: item, order: order, title: Field(item.title), keywords: item.keywords.filter { !$0.isEmpty }.map(Field.init))
        }
    }

    /// Lowercased, accent- and width-free, with runs of whitespace collapsed; independent of the Mac's locale.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The palette's list for `query`. An empty query lists pages in their given order, then chats
    /// that need you (newest first), then the other chats: working first, then by last activity.
    public func results(for query: String, limit: Int = CommandPaletteIndex.defaultLimit) -> [CommandPaletteItem] {
        let folded = Self.fold(query)
        guard !folded.isEmpty else { return emptyResults(limit: limit) }
        let whole = Array(folded)
        let tokens = folded.split(separator: " ").map { Array($0) }
        var scored: [(score: Int, entry: Entry)] = []
        scored.reserveCapacity(entries.count / 4)
        for entry in entries {
            guard let match = Self.match(whole: whole, tokens: tokens, entry: entry) else { continue }
            let score = match + Self.statusBonus(entry.item.status) + Self.kindBonus(entry.item.kind) + entry.item.weight
            scored.append((score, entry))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.entry.item.status != b.entry.item.status { return a.entry.item.status > b.entry.item.status }
            let (da, db) = (a.entry.item.updatedAt ?? .distantPast, b.entry.item.updatedAt ?? .distantPast)
            if da != db { return da > db }
            return a.entry.order < b.entry.order
        }
        return scored.prefix(max(0, limit)).map(\.entry.item)
    }

    private func emptyResults(limit: Int) -> [CommandPaletteItem] {
        let pages = entries.filter { $0.item.kind == .page }
        let chats = entries.filter { $0.item.kind == .chat }
        let newest: (Entry, Entry) -> Bool = { a, b in
            let (da, db) = (a.item.updatedAt ?? .distantPast, b.item.updatedAt ?? .distantPast)
            return da != db ? da > db : a.order < b.order
        }
        let needs = chats.filter { $0.item.status == .needsYou }.sorted(by: newest)
        let rest = chats.filter { $0.item.status != .needsYou }.sorted { a, b in
            let (wa, wb) = (a.item.status == .working, b.item.status == .working)
            return wa != wb ? wa : newest(a, b)
        }
        return (pages + needs + rest).prefix(max(0, limit)).map(\.item)
    }

    /// The whole query against the title, else every word of it against the title or keywords.
    static func match(whole: [Character], tokens: [[Character]], entry: Entry) -> Int? {
        var best = score(whole, in: entry.title, subsequence: true)
        for keyword in entry.keywords {
            if let value = score(whole, in: keyword, subsequence: false).map({ $0 * 7 / 10 }) { best = max(best ?? value, value) }
        }
        if best != nil || tokens.count < 2 { return best }
        var total = 0
        for token in tokens {
            var tokenBest = score(token, in: entry.title, subsequence: true)
            for keyword in entry.keywords {
                if let value = score(token, in: keyword, subsequence: false).map({ $0 * 7 / 10 }) { tokenBest = max(tokenBest ?? value, value) }
            }
            guard let tokenBest else { return nil }
            total += tokenBest
        }
        return total / tokens.count - 10
    }

    /// One field's score for `query`, or nil when it doesn't match.
    static func score(_ query: [Character], in field: Field, subsequence: Bool) -> Int? {
        let text = field.chars
        guard !query.isEmpty, query.count <= text.count else { return nil }
        // Shorter fields win ties a little, never enough to cross a tier.
        let lengthPenalty = min(20, text.count - query.count) / 4
        var substringAt: Int?
        var boundarySubstring = false
        var start = 0
        while start + query.count <= text.count {
            if text[start] == query[0] && text[start..<(start + query.count)].elementsEqual(query) {
                if start == 0 { return Tier.prefix - lengthPenalty }
                if substringAt == nil { substringAt = start }
                if field.boundaries[start] { boundarySubstring = true; break }
            }
            start += 1
        }
        if boundarySubstring { return Tier.wordSubstring - lengthPenalty }
        if substringAt != nil { return Tier.substring - lengthPenalty }
        guard subsequence, query.count >= 2 else { return nil }
        let hits = max(subsequenceHits(query, field, preferBoundaries: true) ?? -1, subsequenceHits(query, field, preferBoundaries: false) ?? -1)
        guard hits >= 0 else { return nil }
        return Tier.subsequence + Tier.subsequenceBoundary * hits / query.count
    }

    /// How many query letters land on word starts, or nil when the letters don't appear in order.
    static func subsequenceHits(_ query: [Character], _ field: Field, preferBoundaries: Bool) -> Int? {
        let text = field.chars
        var position = 0, hits = 0
        for (offset, character) in query.enumerated() {
            let remaining = query.count - offset - 1
            var found: Int?
            if preferBoundaries {
                var i = position
                while i < text.count - remaining {
                    if text[i] == character && field.boundaries[i] { found = i; break }
                    i += 1
                }
            }
            if found == nil {
                var i = position
                while i < text.count {
                    if text[i] == character { found = i; break }
                    i += 1
                }
            }
            guard let index = found else { return nil }
            if field.boundaries[index] { hits += 1 }
            position = index + 1
        }
        return hits
    }
}
