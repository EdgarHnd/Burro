// Small pieces Home's sections share: the section label (a dot, an uppercase name and a count),
// the quiet tag ("This Mac · focustown"), the three button weights (primary amber, secondary,
// ghost), the card surface with an optional amber edge for chats that need you, and short time
// formats. Monochrome on AppAppearance tokens; amber only where something needs you.
import SwiftUI
import BurroCore

/// "● NEEDS YOU · 2" with an optional trailing control.
struct HomeSectionLabel<Trailing: View>: View {
    var title: String
    var count: Int?
    var dot: Color?
    var tint: Color = AppAppearance.tertiary
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 8) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8).accessibilityHidden(true) }
            Text((count.map { "\(title) · \($0)" } ?? title).uppercased())
                .font(.system(size: 11, weight: .semibold)).tracking(0.9).monospacedDigit().foregroundStyle(tint)
            Spacer(minLength: 8)
            trailing()
        }
        .accessibilityElement(children: .contain)
    }
}

extension HomeSectionLabel where Trailing == EmptyView {
    init(title: String, count: Int? = nil, dot: Color? = nil, tint: Color = AppAppearance.tertiary) {
        self.init(title: title, count: count, dot: dot, tint: tint) { EmptyView() }
    }
}

/// Home's buttons: one amber primary per card at most, a bordered secondary, and a borderless ghost.
struct HomeButtonStyle: ButtonStyle {
    enum Weight { case primary, secondary, ghost }
    var weight: Weight = .secondary
    var compact = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 8 : 12).frame(height: compact ? 24 : 28)
            .background(background(pressed: configuration.isPressed), in: shape)
            .overlay(shape.strokeBorder(border))
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }
    private var foreground: Color {
        switch weight {
        case .primary: OrchestratorStyle.onGold
        case .secondary: AppAppearance.text
        case .ghost: hovering ? AppAppearance.text : AppAppearance.secondary
        }
    }
    private func background(pressed: Bool) -> Color {
        switch weight {
        case .primary: AppAppearance.amber.opacity(pressed ? 0.8 : 1)
        case .secondary: AppAppearance.raised.opacity(pressed ? 0.7 : 1)
        case .ghost: hovering && enabled ? AppAppearance.hover : .clear
        }
    }
    private var border: Color {
        switch weight {
        case .primary: .clear
        case .secondary: hovering && enabled ? AppAppearance.hairline : AppAppearance.separator
        case .ghost: .clear
        }
    }
}

/// Home's card: the shared surface, with an amber edge for a chat that needs you.
struct HomeCardSurface: ViewModifier {
    var attention = false
    func body(content: Content) -> some View {
        content.modifier(SoftSurface(radius: AppAppearance.cardRadius, fill: AppAppearance.surface,
                                     stroke: attention ? AppAppearance.amber.opacity(0.4) : AppAppearance.separator))
    }
}

enum HomeTime {
    /// "21:17" today (in the user's locale), "Mon 21:17" earlier.
    static func clock(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
