// What Haiku returns for a day, week or month: a short headline, a few tagged themes (per person
// for a day, overall for a week or month) and, only when something went out, a production line.
// Kept as JSON in the summary cache; the Shipped card and the Timeline lay it out as bullets
// beside bars drawn from the data. Older entries are plain lines and still display.
import Foundation

public struct ShippedBrief: Codable, Sendable, Equatable {
    public struct Theme: Codable, Sendable, Equatable {
        /// One or two words, ideally an area tag from the titles ("Checkout").
        public var area: String?
        /// What changed, eight words or so.
        public var text: String
        /// Who worked on it (weeks and months).
        public var people: [String]?
        public init(area: String?, text: String, people: [String]? = nil) { self.area = area; self.text = text; self.people = people }
    }
    public struct Person: Codable, Sendable, Equatable {
        public var name: String
        public var themes: [Theme]
        public init(name: String, themes: [Theme]) { self.name = name; self.themes = themes }
    }
    public enum Shape: Sendable { case day, period }

    public var headline: String
    public var people: [Person]
    public var themes: [Theme]
    public var production: String?

    public init(headline: String, people: [Person] = [], themes: [Theme] = [], production: String? = nil) {
        self.headline = headline; self.people = people; self.themes = themes; self.production = production
    }

    enum CodingKeys: String, CodingKey { case headline, people, themes, production }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        headline = (try? container.decode(String.self, forKey: .headline)) ?? ""
        people = (try? container.decode([Person].self, forKey: .people)) ?? []
        themes = (try? container.decode([Theme].self, forKey: .themes)) ?? []
        production = try? container.decode(String.self, forKey: .production)
    }

    /// A cached summary as a brief; nil for older plain-line summaries.
    public init?(json text: String) {
        guard text.hasPrefix("{"), let brief = try? JSONDecoder().decode(ShippedBrief.self, from: Data(text.utf8)),
              !brief.headline.isEmpty || !brief.people.isEmpty || !brief.themes.isEmpty else { return nil }
        self = brief
    }

    /// The compact JSON kept in the cache.
    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Reads Claude's answer: the first JSON object in it, tidied and held to the day's facts.
    /// People not in `names` are dropped, a production line only stays when something went to
    /// production, and lengths are capped so the layout never turns back into paragraphs.
    public static func parse(_ answer: String, shape: Shape, names: Set<String>, production: Bool) -> ShippedBrief? {
        guard let open = answer.firstIndex(of: "{"), let close = answer.lastIndex(of: "}"), open < close,
              var brief = try? JSONDecoder().decode(ShippedBrief.self, from: Data(answer[open...close].utf8)) else { return nil }
        brief.headline = tidy(brief.headline, words: 16)
        func clean(_ themes: [Theme], limit: Int, words: Int) -> [Theme] {
            themes.compactMap { theme in
                let text = tidy(theme.text, words: words)
                guard !text.isEmpty else { return nil }
                let area = theme.area.map { tidy($0, words: 3) }.flatMap { $0.isEmpty ? nil : $0 }
                let people = theme.people?.filter(names.contains)
                return Theme(area: area, text: text, people: people?.isEmpty == true ? nil : people)
            }.prefix(limit).map { $0 }
        }
        switch shape {
        case .day:
            var seen = Set<String>()
            brief.people = brief.people.filter { names.contains($0.name) && seen.insert($0.name).inserted }
                .map { Person(name: $0.name, themes: clean($0.themes, limit: 3, words: 11)) }
                .filter { !$0.themes.isEmpty }
            brief.themes = []
        case .period:
            brief.themes = clean(brief.themes, limit: 4, words: 13)
            brief.people = []
        }
        brief.production = production ? brief.production.map { tidy($0, words: 22) }.flatMap { $0.isEmpty ? nil : $0 } : nil
        guard !brief.headline.isEmpty, !(brief.people.isEmpty && brief.themes.isEmpty) else { return nil }
        return brief
    }

    /// One line, no trailing period or markdown, at most `words` words.
    static func tidy(_ text: String, words: Int) -> String {
        var line = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while line.hasSuffix(".") { line.removeLast() }
        let parts = line.split(separator: " ")
        return parts.count > words ? parts.prefix(words).joined(separator: " ") + "…" : line
    }

    /// The most telling few lines, for a compact column: each person's first theme in turn,
    /// then their second, and so on (a day), or the themes as they are (a week or month).
    public func bullets(_ limit: Int = 3) -> [Theme] {
        guard !people.isEmpty else { return Array(themes.prefix(limit)) }
        var out: [Theme] = []
        var round = 0
        while out.count < limit, people.contains(where: { $0.themes.count > round }) {
            for person in people where person.themes.count > round && out.count < limit { out.append(person.themes[round]) }
            round += 1
        }
        return out
    }

    /// Plain text for Copy and `burro-inspect`.
    public var plainText: String {
        var lines = [headline]
        for person in people {
            lines.append("\(person.name): " + person.themes.map(Self.line).joined(separator: "; "))
        }
        lines += themes.map { "- " + Self.line($0) + ($0.people.map { " (\($0.joined(separator: ", ")))" } ?? "") }
        if let production { lines.append("Production: \(production)") }
        return lines.joined(separator: "\n")
    }

    static func line(_ theme: Theme) -> String { (theme.area.map { "[\($0)] " } ?? "") + theme.text }

    /// Plain text for any cached summary: a brief's lines, or older plain lines as they are.
    public static func plain(_ text: String) -> String {
        ShippedBrief(json: text)?.plainText ?? ShippedSummary.normalized(text)
    }

    public static let dayInstructions = """
    You summarise one day of a software team's GitHub activity for the person who reads it, who appears as "You".
    The reader sees the counts and every title elsewhere. Your job is the gist, readable in one look.

    Reply with only this JSON, nothing before or after:
    {"headline": "...", "people": [{"name": "...", "themes": [{"area": "...", "text": "..."}]}], "production": "..."}

    - headline: at most 12 words, the day's gist in plain words. No counts, no names of people.
    - people: one entry per person who merged or pushed, in the order given, name exactly as given.
    - themes: one to three per person, biggest first. Group related pull requests into one theme.
      area: one or two words; reuse the [area] tags from the input when they fit, keeping their wording, else name the product area.
      text: at most 8 words, what changed, starting with a noun or verb, no trailing period.
      For someone who merged nothing, the themes say what they're working on.
    - production: only if the input lists production releases, at most 15 words on what went out and whether anything failed. Otherwise "".
    - Use only what the titles say. Never invent features, reasons or results. No dates, numbers of pull requests or markdown.
    """

    public static func periodInstructions(_ kind: ShippedPeriod.Kind) -> String {
        let span = kind == .week ? "week" : "month"
        return """
        You summarise one \(span) of a software team's GitHub activity for the person who reads it, who appears as "You".
        The reader sees the counts elsewhere. Your job is the \(span)'s gist, readable in one look.

        Reply with only this JSON, nothing before or after:
        {"headline": "...", "themes": [{"area": "...", "text": "...", "people": ["..."]}], "production": "..."}

        - headline: at most 12 words, the \(span)'s gist in plain words. No counts.
        - themes: the three biggest themes of the \(span)\(kind == .month ? " (four at most)" : ""), biggest first. Group many pull requests into each; a \(span) is themes, never a day-by-day list.
          area: one or two words; reuse the [area] tags from the input when they fit, else name the product area.
          text: at most 10 words, what changed, no trailing period.
          people: who worked on it, names exactly as given.
        - production: only if the input lists production releases, at most 15 words on what went out and whether anything failed. Otherwise "".
        - Use only what the titles say. Never invent features, reasons or results. No dates, counts or markdown.
        """
    }
}

// MARK: Composition from the data

extension ShippedDigest {
    /// Merged pull requests per area (untagged ones as "Other"), biggest first; for one person when given.
    public func areas(for person: String? = nil) -> [(area: String, count: Int)] {
        ShippedDigest.areas(merged.filter { person == nil || $0.author == person })
    }

    static func areas(_ pulls: [Pull]) -> [(area: String, count: Int)] {
        var counts: [String: Int] = [:]
        for pull in pulls { counts[pull.area ?? "Other", default: 0] += 1 }
        return counts.sorted { ($0.key == "Other") != ($1.key == "Other") ? $1.key == "Other" : $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }
}

extension ShippedPeriodReport {
    /// Merged pull requests per area across the period, biggest first, untagged last.
    public var areas: [(area: String, count: Int)] { ShippedDigest.areas(digests.flatMap(\.merged)) }
    /// Days something reached production.
    public var productionDays: Int { digests.filter { $0.shippedCount > 0 }.count }
}
