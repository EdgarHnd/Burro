// Clicking commits a notch page; brief hover previews never replace that selection.
import Foundation

public enum NotchPage: String, CaseIterable, Sendable {
    case agents, usage
    public var title: String { self == .agents ? "Agents" : "Usage" }
    public var symbol: String { self == .agents ? "waveform.path" : "gauge.with.dots.needle.33percent" }
}

public struct NotchNavigation: Equatable, Sendable {
    public private(set) var selected: NotchPage = .agents
    public private(set) var preview: NotchPage?
    public private(set) var hovered: NotchPage?
    public private(set) var deadline: TimeInterval?
    public var visible: NotchPage { preview ?? selected }
    public var isPreviewing: Bool { preview != nil }
    public init() {}

    public mutating func select(_ page: NotchPage) {
        selected = page; preview = nil; deadline = nil
    }
    public mutating func updatePointer(over page: NotchPage?, now: TimeInterval) {
        guard hovered != page else { return }
        hovered = page
        if page == selected { preview = nil; deadline = nil }
        else if page != nil { deadline = now + 0.16 }
        else { deadline = preview == nil ? nil : now + 0.08 }
    }
    public mutating func advance(now: TimeInterval) {
        guard let deadline, now >= deadline else { return }
        self.deadline = nil
        preview = hovered == selected ? nil : hovered
    }
    public mutating func endPreview() {
        preview = nil; hovered = nil; deadline = nil
    }
}
