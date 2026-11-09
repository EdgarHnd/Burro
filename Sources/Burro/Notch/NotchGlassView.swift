// A dark translucent material behind the expanded notch; the parent owns clipping, fades and input.
import AppKit

@MainActor final class NotchGlassView: NSView {
    private let effect: NSView
    private let shade = NSView()

    override init(frame frameRect: NSRect) {
        effect = Self.makeEffect()
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        addSubview(effect)
        // Darken bright backdrops while retaining the material's blur and transparency.
        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        addSubview(shade)
        setAccessibilityElement(false)
    }

    private static func makeEffect() -> NSView {
        // Xcode 16 does not know the macOS 26 type, even behind an availability check.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 26
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
        // Align the material and tint with the existing eight-point notch shoulders.
        effect.frame = bounds.insetBy(dx: 8, dy: 0)
        shade.frame = effect.frame
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
