// The same vector butter mark is used in the notch and native menu bar.
import AppKit
import SwiftUI

@MainActor enum BurroBrand {
    static let plateImage: NSImage = {
        guard let url = Bundle.module.url(forResource: "butter-plate", withExtension: "pdf", subdirectory: "Brand"),
              let image = NSImage(contentsOf: url) else {
            assertionFailure("The Burro plate resource is missing")
            return NSImage()
        }
        return image
    }()
    static let bodyImage: NSImage = {
        guard let url = Bundle.module.url(forResource: "butter-body", withExtension: "pdf", subdirectory: "Brand"),
              let image = NSImage(contentsOf: url) else {
            assertionFailure("The animated Burro brand resource is missing")
            return Self.image
        }
        return image
    }()
    static let eyes: [CGRect] = {
        guard let url = Bundle.module.url(forResource: "butter-eyes", withExtension: "json", subdirectory: "Brand"),
              let data = try? Data(contentsOf: url), let eyes = try? JSONDecoder().decode([CGRect].self, from: data) else {
            assertionFailure("The Burro eye geometry is missing")
            return []
        }
        return eyes
    }()
    static let image: NSImage = {
        guard let url = Bundle.module.url(forResource: "butter", withExtension: "pdf", subdirectory: "Brand"),
              let image = NSImage(contentsOf: url) else {
            assertionFailure("The Burro brand resource is missing")
            return NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Burro")!
        }
        image.size = NSSize(width: 18, height: 18)
        // Native menu bars adapt the glyph to their material. The notch explicitly uses white.
        image.isTemplate = true
        return image
    }()
}

struct BurroMark: View {
    var active = false
    var working = false
    var tint: Color = .white
    var phase: Double = 0
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AnimatedBurroMark(active: active && appeared, working: working, reduceMotion: reduceMotion,
                          tint: NSColor(tint), phase: phase)
            .accessibilityHidden(true)
            .onAppear { appeared = true }
            .onDisappear { appeared = false }
    }
}

private struct AnimatedBurroMark: NSViewRepresentable {
    let active: Bool
    let working: Bool
    let reduceMotion: Bool
    let tint: NSColor
    let phase: Double

    func makeNSView(context: Context) -> BurroMascotView { BurroMascotView() }
    func updateNSView(_ view: BurroMascotView, context: Context) {
        view.configure(active: active, working: working, reduceMotion: reduceMotion, tint: tint, phase: phase)
    }
    static func dismantleNSView(_ view: BurroMascotView, coordinator: ()) { view.stopAnimating() }
}
