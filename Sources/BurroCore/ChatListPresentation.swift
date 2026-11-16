// Small decisions for how chats are listed and opened. A row's preview is the chat's last
// assistant sentence when a scan Burro already ran has it (the Today activity scan's previews),
// never a new read per row, cleaned to plain text: Markdown links keep their text (a link cut off
// by the scan's length cap too), and emphasis, code ticks, headings, quotes and list markers go.
// Codex directive lines (`ChatDirectives`) never show as text: an inbox item previews as its
// title, any other directive (whole, or cut off by the scan's cap) and writing fences are skipped.
// Clicking a chat in the notch or the menu bar opens it in Burro when "Open chats in Burro" is on,
// and ⌥ flips that to the provider's app; a chat without a provider link always opens in Burro.
import Foundation

public enum ChatListPresentation {
    /// A one-line plain-text preview from an existing scan's text: the first line with words in
    /// it, Markdown and Codex directives removed, collapsed and shortened.
    public static func preview(_ text: String?, limit: Int = 140) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).lazy.compactMap { raw -> String? in
            switch ChatDirectives.previewLine(String(raw)) {
            case .text: plain(String(raw))
            case .hidden: nil
            case .note(let note): plain(note.title)
            }
        }.first { !$0.isEmpty }
        guard let line else { return nil }
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    /// One line of Markdown as plain text, whitespace collapsed.
    static func plain(_ line: String) -> String {
        var value = line.trimmingCharacters(in: .whitespaces)
        // Block markers at the start: headings, quotes, bullets, task boxes, numbered items.
        while let range = value.range(of: #"^(#{1,6}\s+|>\s*|[-*+]\s+|\[[ xX]\]\s+|\d{1,3}[.)]\s+)"#, options: .regularExpression) {
            value.removeSubrange(range)
        }
        // [text](url) and [text](url… cut off by the scan's cap, and images: keep the text.
        value = value.replacingOccurrences(of: #"!?\[([^\]\n]*)\]\([^)\s]*\)?"#, with: "$1", options: .regularExpression)
        for mark in ["**", "__", "`", "~~"] { value = value.replacingOccurrences(of: mark, with: "") }
        // Single-character emphasis around a word: *word* and _word_.
        value = value.replacingOccurrences(of: #"(^|[\s(])[*_]([^*_\s][^*_]*?)[*_](?=$|[\s.,;:!?)])"#, with: "$1$2", options: .regularExpression)
        return value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Where a click on a chat in the notch or the menu bar opens it.
public enum ChatOpenTarget: Equatable, Sendable {
    case burro, provider
    public static func decide(openInBurro: Bool, optionKey: Bool, hasProviderLink: Bool) -> ChatOpenTarget {
        guard hasProviderLink else { return .burro }
        return openInBurro != optionKey ? .burro : .provider
    }
}

/// The ⌘K palette's "Start chat: …" row. It opens the New chat sheet prefilled; it never starts anything.
public enum CommandPaletteStartChat {
    public static let itemID = "action:start-chat"
    static let titleLimit = 60

    /// The row for typed text, or nil when there is nothing to start with.
    public static func item(query: String, projectName: String?) -> CommandPaletteItem? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let shown = text.count > titleLimit ? String(text.prefix(titleLimit - 1)) + "…" : text
        let place = projectName.map { "in \($0) · " } ?? ""
        return CommandPaletteItem(id: itemID, kind: .action, title: "Start chat: “\(shown)”",
                                  subtitle: place + "opens the New chat sheet")
    }

    /// The palette's list with the row added: the only row when nothing matched, otherwise last, after
    /// every match, so it never pushes a real result down. An empty query adds nothing.
    public static func results(_ matches: [CommandPaletteItem], query: String, projectName: String?) -> [CommandPaletteItem] {
        guard let item = item(query: query, projectName: projectName) else { return matches }
        return matches.filter { $0.id != itemID } + [item]
    }
}
