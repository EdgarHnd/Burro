// Following a chat while it updates: remember the last message seen at the bottom and count
// what arrived after it, so the reader can stay where they scrolled and see "↓ N new".
// Replies of yours still sending don't count as new.
import Foundation

public enum ChatFollow {
    /// Identifies a message across reloads (its position changes when older ones scroll out of the window).
    public struct Mark: Equatable, Sendable {
        let kind: ChatMessage.Kind
        let text: String
        let at: Date?
    }

    /// The newest logged message, as seen now.
    public static func mark(_ messages: [ChatMessage]) -> Mark? {
        messages.last { !$0.sending }.map { Mark(kind: $0.kind, text: $0.text, at: $0.at) }
    }

    /// Logged messages after `mark`. When the marked message is no longer in the window, those
    /// newer than its time; without either, none.
    public static func newCount(_ messages: [ChatMessage], after mark: Mark?) -> Int {
        guard let mark else { return messages.filter { !$0.sending }.count }
        let logged = messages.filter { !$0.sending }
        if let index = logged.lastIndex(where: { $0.kind == mark.kind && $0.text == mark.text && $0.at == mark.at }) {
            return logged.count - 1 - index
        }
        guard let at = mark.at else { return 0 }
        return logged.filter { ($0.at ?? .distantPast) > at }.count
    }
}
