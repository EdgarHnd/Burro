// Codex's app markup in replies, for display only. The Codex app asks the model to put directive
// lines in its final messages, which its own window turns into cards: `::inbox-item{title="…"
// summary="…"}`, `::code-comment{title="…" body="…" file="…" start=12 end=14 priority=1}`,
// `::created-thread{threadId="…"}`, and the container `:::writing{variant="…" id="…" title="…"}`
// … `:::` around a draft. Burro shows them like this: an inbox item becomes a quiet one-line note
// (its title, then its summary), so does a code comment (its title, its body, and where), a
// writing block keeps its text without the fence lines, and any other directive is left out of
// what's shown. Conservatively: only a whole line `::name{…}` (or `:::name{…}`) whose name is
// lower-case and hyphenated and whose braces hold nothing but `key="value"` or `key=value`
// attributes counts; anything else is ordinary text. What is sent to or stored for an agent is
// never changed. One-line previews (the Chats list, Home, Today) use the same rules, and also drop
// a directive the scan cut off at its length cap.
import Foundation

public enum ChatDirectives {
    /// One directive line.
    public struct Directive: Equatable, Sendable {
        public var name: String
        public var attributes: [String: String]
        /// `:::name{…}`: opens a block that a line of `:::` closes.
        public var opensBlock: Bool
        public init(name: String, attributes: [String: String], opensBlock: Bool = false) {
            self.name = name; self.attributes = attributes; self.opensBlock = opensBlock
        }
    }

    /// What a reply line turns into on screen.
    public enum Shown: Equatable, Sendable {
        /// Not a directive: shown as written.
        case text
        /// Left out of what's shown.
        case hidden
        /// A quiet note: a title, a secondary line, and its glyph.
        case note(ChatNote)
    }

    /// The directive on `line`, when the whole line (spaces around it aside) is one.
    public static func parse(_ line: String) -> Directive? {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("::"), line.hasSuffix("}") else { return nil }
        let block = line.hasPrefix(":::")
        let rest = line.dropFirst(block ? 3 : 2)
        guard !rest.hasPrefix(":"), let brace = rest.firstIndex(of: "{") else { return nil }
        let name = String(rest[..<brace])
        guard isName(name) else { return nil }
        let body = rest[rest.index(after: brace)..<rest.index(before: rest.endIndex)]
        guard let attributes = attributes(body, complete: true) else { return nil }
        return Directive(name: name, attributes: attributes, opensBlock: block)
    }

    /// What `directive` shows: a note for an inbox item or a code comment, nothing otherwise.
    public static func shown(_ directive: Directive) -> Shown {
        let value = { (key: String) -> String? in
            directive.attributes[key].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch directive.name {
        case "inbox-item":
            guard let title = value("title") ?? value("summary") else { return .hidden }
            return .note(ChatNote(kind: .inbox, title: title, detail: value("title") == nil ? nil : value("summary")))
        case "code-comment":
            guard let title = value("title") ?? value("body") else { return .hidden }
            let place = value("file").map { file -> String in
                let name = URL(fileURLWithPath: file).lastPathComponent
                guard let start = value("start") else { return name }
                guard let end = value("end"), end != start else { return "\(name):\(start)" }
                return "\(name):\(start)–\(end)"
            }
            let body = value("title") == nil ? nil : value("body")
            let detail = [body, place].compactMap { $0 }.joined(separator: " · ")
            return .note(ChatNote(kind: .comment, title: title, detail: detail.isEmpty ? nil : detail))
        default:
            return .hidden
        }
    }

    /// A one-line preview's view of a line: like `parse`/`shown`, and also a directive cut off by
    /// a scan's length cap (`::name{key="…` with no closing brace) or a lone `:::` fence, both
    /// hidden; a cut-off inbox item still shows its title when the title arrived whole.
    public static func previewLine(_ line: String) -> Shown {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("::") else { return .text }
        if trimmed.allSatisfy({ $0 == ":" }) { return trimmed.count >= 3 ? .hidden : .text }
        if let directive = parse(trimmed) { return shown(directive) }
        // Cut off: `::name{` then the start of an attribute list that never closes.
        let rest = trimmed.drop { $0 == ":" }
        guard trimmed.count - rest.count <= 3, let brace = rest.firstIndex(of: "{"), isName(String(rest[..<brace])),
              !rest.contains("}") else { return .text }
        let body = rest[rest.index(after: brace)...]
        guard body.isEmpty || body.first.map({ $0.isLetter || $0 == "_" }) == true,
              let attributes = attributes(body, complete: false) else { return .text }
        if rest[..<brace] == "inbox-item", let title = attributes["title"]?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            return .note(ChatNote(kind: .inbox, title: title, detail: nil))
        }
        return .hidden
    }

    /// A line that closes a `:::name{…}` block.
    public static func isBlockEnd(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces) == ":::" }

    /// Lower-case words joined by single hyphens: "inbox-item", "code-comment", "writing".
    static func isName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, ("a"..."z").contains(first), !name.hasSuffix("-"), !name.contains("--") else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// `key="value" key=value …` as a dictionary, or nil when anything else is in there. With
    /// `complete` false the text may stop part-way (a value with no closing quote is dropped).
    static func attributes(_ body: Substring, complete: Bool) -> [String: String]? {
        var result: [String: String] = [:]
        var index = body.startIndex
        func skipSpaces() { while index < body.endIndex, body[index] == " " || body[index] == "\t" { index = body.index(after: index) } }
        skipSpaces()
        while index < body.endIndex {
            let keyStart = index
            while index < body.endIndex, body[index].isLetter || body[index].isNumber || body[index] == "_" || body[index] == "-" {
                index = body.index(after: index)
            }
            let key = String(body[keyStart..<index])
            // A bare word with no "=": only a cut-off attribute may end like that.
            if index == body.endIndex { return complete ? nil : result }
            guard !key.isEmpty, key.first?.isLetter == true || key.first == "_", body[index] == "=" else { return nil }
            index = body.index(after: index)
            if index == body.endIndex { return complete ? nil : result }
            var value = ""
            if body[index] == "\"" {
                index = body.index(after: index)
                var closed = false
                while index < body.endIndex {
                    let character = body[index]
                    if character == "\\" {
                        let next = body.index(after: index)
                        guard next < body.endIndex else { break }
                        value.append(body[next]); index = body.index(after: next); continue
                    }
                    if character == "\"" { closed = true; index = body.index(after: index); break }
                    value.append(character); index = body.index(after: index)
                }
                guard closed else { return complete ? nil : result }
            } else {
                while index < body.endIndex, body[index] != " ", body[index] != "\t", body[index] != "\"" {
                    value.append(body[index]); index = body.index(after: index)
                }
                guard !value.isEmpty else { return nil }
            }
            result[key] = value
            guard index == body.endIndex || body[index] == " " || body[index] == "\t" else { return nil }
            skipSpaces()
        }
        return result
    }
}

/// A quiet one-line note in a conversation, made from a Codex directive.
public struct ChatNote: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case inbox, comment }
    public var kind: Kind
    public var title: String
    /// The summary, or a comment's body and place, in secondary text.
    public var detail: String?
    public init(kind: Kind, title: String, detail: String?) { self.kind = kind; self.title = title; self.detail = detail }
}
