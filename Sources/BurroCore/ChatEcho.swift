// A reply sent from Burro shows in the chat at once, dimmed as "sending…", until the chat's own
// log has it. Each logged message of yours settles at most one waiting echo with the same text
// (it may carry attached file paths after it); a logged message from before the send never does.
// An echo the log never shows within a few minutes is dropped, as is one whose send failed.
import Foundation

public struct ChatEcho: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let sent: Date
    /// Logged messages of yours with the same text, without times, that were already there.
    public let earlier: Int
    public init(id: UUID = UUID(), text: String, sent: Date, earlier: Int = 0) {
        self.id = id; self.text = text; self.sent = sent; self.earlier = earlier
    }
}

public enum ChatEchoes {
    /// How long an echo waits for the log before it is dropped.
    public static let window: TimeInterval = 180
    /// A logged time may be this much earlier than the send (the provider's clock, or a remote Mac's).
    public static let skew: TimeInterval = 30

    /// A new echo for `text`, sent at `sent`, given what the chat shows now.
    public static func make(_ text: String, sent: Date, logged: [ChatMessage], id: UUID = UUID()) -> ChatEcho {
        let draft = ChatEcho(id: id, text: text, sent: sent)
        return ChatEcho(id: id, text: text, sent: sent, earlier: logged.filter { $0.at == nil && matches($0, draft) }.count)
    }

    /// The logged message is this reply: yours, with the same text, or the text followed by more
    /// (attachments), or the start of it when the log cut a long message short.
    static func matches(_ message: ChatMessage, _ echo: ChatEcho) -> Bool {
        guard message.kind == .user, !message.sending else { return false }
        let logged = clean(message.text), sent = clean(echo.text)
        guard !sent.isEmpty else { return false }
        if logged == sent || logged.hasPrefix(sent) { return true }
        return logged.hasSuffix("…") && logged.count > 200 && sent.hasPrefix(String(logged.dropLast()))
    }

    private static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The echoes still waiting at `now`, oldest first: each logged message settles at most one.
    public static func pending(_ echoes: [ChatEcho], logged: [ChatMessage], now: Date) -> [ChatEcho] {
        var used = Set<Int>()
        var waiting: [ChatEcho] = []
        for echo in echoes.sorted(by: { $0.sent < $1.sent }) {
            var untimed = 0
            let match = logged.indices.first { index in
                let message = logged[index]
                guard !used.contains(index), matches(message, echo) else { return false }
                if let at = message.at { return at >= echo.sent.addingTimeInterval(-skew) }
                untimed += 1
                return untimed > echo.earlier
            }
            if let match {
                used.insert(match)
            } else if now.timeIntervalSince(echo.sent) < window {
                waiting.append(echo)
            }
        }
        return waiting
    }

    /// The transcript with waiting echoes after its messages, marked `sending`.
    public static func merged(_ transcript: ChatTranscript, echoes: [ChatEcho]) -> ChatTranscript {
        guard !echoes.isEmpty else { return transcript }
        var merged = transcript
        let next = (transcript.messages.map(\.id).max() ?? -1) + 1
        merged.messages += echoes.enumerated().map { offset, echo in
            ChatMessage(id: next + offset, kind: .user, text: echo.text, at: echo.sent, sending: true)
        }
        return merged
    }
}
