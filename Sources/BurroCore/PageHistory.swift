// A browser-style list of the pages the window has shown, for Back (⌘[) and Forward (⌘]).
// Visiting the page already on screen changes nothing; visiting a new page drops anything ahead
// of the current position. Each entry remembers whether it was reached by a jump from inside a
// page (opening a chat from Today, say) rather than from the top bar, so the bar can offer a
// way back to where that jump started. The list keeps at most `limit` entries.
import Foundation

public struct PageHistory<Page: Hashable & Sendable>: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var page: Page
        /// Reached from a link inside a page rather than from the top bar, a shortcut or Back.
        public var jump: Bool
    }
    public private(set) var entries: [Entry]
    public private(set) var index: Int
    public let limit: Int

    public init(start: Page, limit: Int = 50) {
        entries = [Entry(page: start, jump: false)]
        index = 0
        self.limit = max(2, limit)
    }

    public var current: Page { entries[index].page }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index < entries.count - 1 }
    public var previous: Page? { canGoBack ? entries[index - 1].page : nil }
    /// Where a jump to the current page came from, if the current page was reached by one.
    public var jumpOrigin: Page? { entries[index].jump ? previous : nil }

    /// Records that `page` is now on screen. The page already on screen is ignored.
    public mutating func visit(_ page: Page, jump: Bool = false) {
        guard page != current else { return }
        entries.removeSubrange((index + 1)...)
        entries.append(Entry(page: page, jump: jump))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        index = entries.count - 1
    }

    /// Steps back and returns the page to show, or nil at the start.
    @discardableResult public mutating func back() -> Page? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }

    /// Steps forward and returns the page to show, or nil at the end.
    @discardableResult public mutating func forward() -> Page? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }
}
