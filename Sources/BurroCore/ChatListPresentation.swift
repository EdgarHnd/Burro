// Small decisions for how chats are listed and opened. A row shows its "machine · folder" tag
// only when it differs from the row above in the same section, so a run of chats in one folder
// reads as a group. A row's second line is the chat's last assistant sentence when a scan Burro
// already ran has it (the Today activity scan's previews), never a new read per row. Clicking a
// chat in the notch or the menu bar opens it in Burro when "Open chats in Burro" is on, and ⌥
// flips that to the provider's app; a chat without a provider link always opens in Burro.
import Foundation

public enum ChatListPresentation {
    /// For each row in display order: whether to show its place tag.
    public static func showsPlace(_ places: [String]) -> [Bool] {
        places.indices.map { index in index == 0 || places[index] != places[index - 1] }
    }

    /// A one-line preview from an existing scan's text: the first non-empty line, collapsed and shortened.
    public static func preview(_ text: String?, limit: Int = 140) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        guard let line else { return nil }
        let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
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
