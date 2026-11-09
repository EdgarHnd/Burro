// The aquarium on screen, and the pointer side, where
// hovering a fish names its chat and clicking opens it.
import AppKit
import SwiftUI

/// One canvas, a few frames a second: the grid moves in whole cells, so that reads as smooth.
struct AquariumView: View {
    var fish: [AquariumFish]
    var hover: AquariumHover?
    var animate: Bool
    var stillTime: Double
    var ink: Color
    var amber: Color

    var body: some View {
        let highlight = hover?.fish?.id
        TimelineView(.animation(minimumInterval: 1.0 / 6, paused: !animate)) { timeline in
            let t = Aquarium.time(timeline.date, animate: animate, still: stillTime)
            Canvas(rendersAsynchronously: true) { context, size in
                Aquarium.draw(&context, size: size, t: t, ink: ink, amber: amber, fish: fish, highlight: highlight)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The fish under the pointer, shared by the catcher that sets it and the tank and label that show it.
@Observable @MainActor final class AquariumHover {
    var fish: AquariumFish?
    var point: CGPoint = .zero
}

/// Sits behind the page's content, so it only sees the pointer over the open water between cards.
struct AquariumCatcher: View {
    var hover: AquariumHover
    var fish: [AquariumFish]
    var size: CGSize
    var animate: Bool
    var space: String
    var open: (String) -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .named(space)) { phase in
                switch phase {
                case .active(let point):
                    let hit = find(point)
                    if hit?.id != hover.fish?.id { (hit == nil ? NSCursor.arrow : NSCursor.pointingHand).set() }
                    if hit != hover.fish { hover.fish = hit }
                    if hit != nil { hover.point = point }
                case .ended:
                    if hover.fish != nil { NSCursor.arrow.set(); hover.fish = nil }
                }
            }
            .gesture(SpatialTapGesture(coordinateSpace: .named(space)).onEnded { value in
                guard let hit = find(value.location) else { return }
                hover.fish = nil
                NSCursor.arrow.set()
                open(hit.id)
            })
    }

    private func find(_ point: CGPoint) -> AquariumFish? {
        guard !fish.isEmpty else { return nil }
        return Aquarium.fish(at: point, size: size, t: Aquarium.time(Date(), animate: animate), fish: fish)
    }
}

/// The hovered fish's chat: its title, model, effort and age, beside the pointer.
struct AquariumLabel: View {
    var hover: AquariumHover
    var size: CGSize

    var body: some View {
        if let fish = hover.fish {
            let point = hover.point
            let left = point.x > size.width - 300
            VStack(alignment: .leading, spacing: 2) {
                Text(fish.title.isEmpty ? "Untitled chat" : fish.title)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(AppAppearance.text).lineLimit(1)
                Text(fish.waiting ? fish.detail + " · needs you" : fish.detail)
                    .font(.system(size: 11)).foregroundStyle(fish.waiting ? CoverField.amber : AppAppearance.secondary).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(AppAppearance.separator.opacity(0.6)))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .frame(maxWidth: 280, alignment: .leading)
            .fixedSize()
            // A one-point frame pins the label's corner beside the pointer; the label overflows away from it.
            .frame(width: 1, height: 1, alignment: left ? .topTrailing : .topLeading)
            .position(x: point.x + (left ? -14 : 14), y: point.y + 18)
            .allowsHitTesting(false)
        }
    }
}
