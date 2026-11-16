// The block structure of a chat reply, for the Chats page and the Orchestrator page to draw:
// headings, bullet and numbered lists, paragraphs, fenced code, images or videos linked by absolute
// path, tables, and quiet notes made from Codex directives (`ChatDirectives`). Parsed per render,
// never stored. A table is a header row, then a separator row (`|---|:--:|--:|`, outer pipes
// optional, colons setting each column's alignment), then body rows until a line without a pipe;
// it may follow a paragraph line or a list item with no blank line between. Cells keep their
// inline Markdown, `\|` is a literal pipe, short rows are padded and long ones keep their extra
// cells. A header row with no separator yet (a reply still arriving) stays a paragraph. Nothing
// here drops text: a line that isn't any other block is paragraph text.
import Foundation

public enum ChatMarkdown {
    public enum Block: Equatable, Sendable {
        case code(String), heading(String, Int), item(String, String, Int), paragraph(String), media(String, String)
        case table(ChatTable)
        case note(ChatNote)
    }

    /// `![caption](/absolute/path.png)` links to an image or video file; other images stay as text.
    public static func media(in line: String) -> (rest: String, media: [(String, String)])? {
        var media: [(String, String)] = []
        var rest = line
        for match in line.matches(of: /!\[([^\]]*)\]\(<?(?:file:\/\/)?(\/[^)>]+?)>?\)/) {
            let path = String(match.2).removingPercentEncoding ?? String(match.2)
            guard ChatMedia.kind(of: path) != nil else { continue }
            media.append((String(match.1), path))
            rest = rest.replacingOccurrences(of: String(match.0), with: "")
        }
        return media.isEmpty ? nil : (rest.trimmingCharacters(in: .whitespaces), media)
    }

    public static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var openDirectiveBlocks = 0
        for (index, part) in text.components(separatedBy: "```").enumerated() {
            if index % 2 == 1 {
                // Drop the language tag on the fence's first line.
                let lines = part.split(separator: "\n", omittingEmptySubsequences: false)
                let body = lines.count > 1 && !lines[0].contains(" ") ? lines.dropFirst().joined(separator: "\n") : part
                blocks.append(.code(body.trimmingCharacters(in: .newlines)))
                continue
            }
            var paragraph: [String] = []
            func flush() {
                let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { blocks.append(.paragraph(joined)) }
                paragraph = []
            }
            let lines = part.components(separatedBy: "\n")
            var position = 0
            while position < lines.count {
                let raw = lines[position]
                position += 1
                let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { flush(); continue }
                if let directive = ChatDirectives.parse(line) {
                    flush()
                    if directive.opensBlock { openDirectiveBlocks += 1 }
                    if case .note(let note) = ChatDirectives.shown(directive) { blocks.append(.note(note)) }
                    continue
                }
                if openDirectiveBlocks > 0, ChatDirectives.isBlockEnd(line) { flush(); openDirectiveBlocks -= 1; continue }
                if position < lines.count, let header = ChatTable.cells(line), let alignments = ChatTable.alignments(lines[position]) {
                    flush()
                    position += 1
                    var rows: [[String]] = []
                    while position < lines.count, let row = ChatTable.cells(lines[position].trimmingCharacters(in: .whitespaces)) {
                        rows.append(row); position += 1
                    }
                    blocks.append(.table(ChatTable(header: header, alignments: alignments, rows: rows)))
                    continue
                }
                if let found = media(in: line) {
                    flush()
                    if !found.rest.isEmpty { blocks.append(.paragraph(found.rest)) }
                    blocks += found.media.map { Block.media($0.0, $0.1) }
                    continue
                }
                if let match = line.wholeMatch(of: /(#{1,6})\s+(.+)/) {
                    flush(); blocks.append(.heading(String(match.2), match.1.count)); continue
                }
                if let match = line.wholeMatch(of: /[-*•]\s+(.+)/) {
                    flush(); blocks.append(.item("•", String(match.1), indent / 2)); continue
                }
                if let match = line.wholeMatch(of: /(\d{1,3})[.)]\s+(.+)/) {
                    flush(); blocks.append(.item(match.1 + ".", String(match.2), indent / 2)); continue
                }
                paragraph.append(line)
            }
            flush()
        }
        return blocks
    }
}

/// A Markdown table: every row has `columns` cells (short rows padded with empty cells).
public struct ChatTable: Equatable, Sendable {
    public enum Alignment: String, Equatable, Sendable { case leading, center, trailing }
    public var header: [String]
    public var alignments: [Alignment]
    public var rows: [[String]]

    public init(header: [String], alignments: [Alignment], rows: [[String]]) {
        let columns = max(header.count, alignments.count, rows.map(\.count).max() ?? 0)
        func padded(_ cells: [String]) -> [String] { cells + Array(repeating: "", count: columns - cells.count) }
        self.header = padded(header)
        self.alignments = alignments + Array(repeating: .leading, count: columns - alignments.count)
        self.rows = rows.map(padded)
    }

    public var columns: Int { header.count }

    /// A row's cells, or nil when the line has no unescaped pipe. Outer pipes are optional; cells
    /// are trimmed and `\|` becomes `|`.
    public static func cells(_ line: String) -> [String]? {
        var cells: [String] = []
        var current = ""
        var sawPipe = false
        var escaped = false
        for character in line {
            if escaped {
                // `\|` is a literal pipe; any other backslash stays for the inline Markdown.
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                sawPipe = true
                cells.append(current); current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        guard sawPipe else { return nil }
        cells.append(current)
        var trimmed = cells.map { $0.trimmingCharacters(in: .whitespaces) }
        // The empty pieces outside a leading and a trailing pipe aren't cells.
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|"), trimmed.first?.isEmpty == true { trimmed.removeFirst() }
        if trimmed.count > 0, endsWithPipe(line), trimmed.last?.isEmpty == true { trimmed.removeLast() }
        return trimmed
    }

    /// A separator row's alignments (`---`, `:--`, `:-:`, `--:`), or nil when the line isn't one.
    public static func alignments(_ line: String) -> [Alignment]? {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard let cells = cells(line), !cells.isEmpty else { return nil }
        var result: [Alignment] = []
        for cell in cells {
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":") && cell.count > 1
            let dashes = cell.dropFirst(left ? 1 : 0).dropLast(right ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(left && right ? .center : (right ? .trailing : .leading))
        }
        return result
    }

    /// A trailing pipe that isn't escaped.
    private static func endsWithPipe(_ line: String) -> Bool {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard line.hasSuffix("|") else { return false }
        let slashes = line.dropLast().reversed().prefix { $0 == "\\" }.count
        return slashes % 2 == 0
    }
}
