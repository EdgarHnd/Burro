// One native material behind the expanded notch; the parent owns clipping, fades and input.
import AppKit

@MainActor final class NotchGlassView: NSView {
    private let effect: NSView

    override init(frame frameRect: NSRect) {
        effect = Self.makeEffect()
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        addSubview(effect)
        setAccessibilityElement(false)
    }

    private static func makeEffect() -> NSView {
        // Xcode 16 does not know the macOS 26 type, even behind an availability check.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 26
            // Keep white status text readable over bright windows without covering the material.
            glass.tintColor = NSColor.black.withAlphaComponent(0.75)
            glass.contentView = NSView()
            return glass
        }
        #endif
        let frost = NSVisualEffectView()
        frost.material = .hudWindow
        frost.blendingMode = .behindWindow
        frost.state = .active
        return frost
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        // Align the material's edges with the existing eight-point notch shoulders.
        effect.frame = bounds.insetBy(dx: 8, dy: 0)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
