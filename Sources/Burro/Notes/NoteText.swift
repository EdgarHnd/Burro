// Plain-text rules for notes. A note is Markdown-ish text: `- [ ] ` / `- [x] ` start a checklist
// item, `- ` a bullet, `# ` a heading; the first line is the title. Works in UTF-16 (NSString)
// offsets so the editor can use the results directly.
import Foundation

enum NoteText {
    static let unchecked = "- [ ] "
    static let checked = "- [x] "

    enum Kind: Equatable { case text, checklist(done: Bool), bullet, heading(Int) }

    /// What a line starts with, and how long that prefix is (UTF-16).
    static func kind(of line: String) -> (kind: Kind, prefix: Int) {
        if line.hasPrefix(unchecked) { return (.checklist(done: false), 6) }
        if line.hasPrefix(checked) || line.hasPrefix("- [X] ") { return (.checklist(done: true), 6) }
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return (.bullet, 2) }
        for level in 1...3 where line.hasPrefix(String(repeating: "#", count: level) + " ") { return (.heading(level), level + 1) }
        return (.text, 0)
    }

    /// The paragraph (without its line break) around a UTF-16 location.
    static func paragraph(in text: NSString, at location: Int) -> NSRange {
        let range = text.paragraphRange(for: NSRange(location: min(location, text.length), length: 0))
        var length = range.length
        while length > 0, let scalar = UnicodeScalar(text.character(at: range.location + length - 1)),
              CharacterSet.newlines.contains(scalar) { length -= 1 }
        return NSRange(location: range.location, length: length)
    }

    static func lineKind(in text: NSString, paragraph: NSRange) -> (kind: Kind, prefix: Int) {
        kind(of: text.substring(with: paragraph))
    }

    /// The first non-empty line, without list or heading marks.
    static func title(_ text: String) -> String {
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            let trimmed = strip(raw, kind(of: raw).prefix).trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
        }
        return "New Note"
    }

    static func strip(_ line: String, _ prefix: Int) -> String { String(line.utf16.dropFirst(prefix)) ?? line }

    /// Everything after the first line, for one-line previews.
    static func rest(_ text: String) -> String {
        guard let newline = text.firstIndex(where: \.isNewline) else { return "" }
        return String(text[text.index(after: newline)...])
    }

    /// Characters you typed, not counting list marks.
    static func visibleCount(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { total, line in
            total + max(0, line.utf16.count - kind(of: String(line)).prefix)
        } + max(0, text.filter { $0 == "\n" }.count)
    }

    /// Readable everywhere: checkboxes as ☐/☑, bullets as •, headings without #.
    static func plain(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let raw = String(line)
            let (kind, prefix) = kind(of: raw)
            let body = strip(raw, prefix)
            switch kind {
            case .checklist(let done): return (done ? "☑ " : "☐ ") + body
            case .bullet: return "• " + body
            case .heading: return body
            case .text: return raw
            }
        }.joined(separator: "\n")
    }

    /// Unchecked checklist items, for To-dos.
    static func openItems(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let raw = String(line)
            guard kind(of: raw).kind == .checklist(done: false) else { return nil }
            let item = strip(raw, 6).trimmingCharacters(in: .whitespaces)
            return item.isEmpty ? nil : item
        }
    }

    /// Turns the lines in `selection` into checklist items, or back into text when they all are.
    /// Returns the new text and the adjusted selection.
    static func toggleChecklist(_ text: String, selection: NSRange) -> (String, NSRange) {
        let string = text as NSString
        let lines = string.lineRange(for: NSRange(location: min(selection.location, string.length), length: selection.length))
        var paragraphs: [NSRange] = []
        string.enumerateSubstrings(in: lines, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in paragraphs.append(range) }
        if paragraphs.isEmpty { paragraphs = [NSRange(location: string.length, length: 0)] }
        let allChecklist = paragraphs.allSatisfy { if case .checklist = lineKind(in: string, paragraph: $0).kind { true } else { false } }
        let result = NSMutableString(string: string)
        var shift = 0, first = 0
        for (index, paragraph) in paragraphs.enumerated() {
            let range = NSRange(location: paragraph.location + shift, length: paragraph.length)
            let (kind, prefix) = lineKind(in: result, paragraph: range)
            let replacement: String
            let removed: Int
            if allChecklist { replacement = ""; removed = prefix }
            else if case .checklist = kind { continue }
            else { replacement = unchecked; removed = kind == .bullet ? prefix : 0 }
            result.replaceCharacters(in: NSRange(location: range.location, length: removed), with: replacement)
            let delta = (replacement as NSString).length - removed
            if index == 0 { first = delta }
            shift += delta
        }
        let location = max(0, selection.location + first)
        return (result as String, NSRange(location: location, length: max(0, selection.length + shift - first)))
    }
}
