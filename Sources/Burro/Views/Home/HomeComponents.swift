// Quiet building blocks for Burro Home: cards, chips and tiles. Token counts read "500K", "1.2M"
// in every language (`TokenCount`).
import SwiftUI
import BurroCore

enum HomeStyle {
    /// Brand colours that read the same in both themes (the app icon is butter on charcoal).
    static let butter = Color(red: 0.98, green: 0.79, blue: 0.27)
    static let charcoal = Color(red: 0.13, green: 0.13, blue: 0.125)
    /// Warm butter light on paper; a faint glow on charcoal so it never reads as olive.
    static let heroWash = AppAppearance.adaptive(light: (0.98, 0.79, 0.27, 0.18), dark: (0.98, 0.79, 0.27, 0.06))
    static let cardRadius: CGFloat = 16
    static let palette: [Color] = [AppAppearance.blue, .purple, .teal, AppAppearance.green, AppAppearance.amber, AppAppearance.claude, .pink, .indigo]
    /// A stable colour per project name, so a project keeps its tile colour across launches.
    static func tint(for name: String) -> Color {
        let hash = name.unicodeScalars.reduce(UInt32(2166136261)) { ($0 ^ $1.value) &* 16777619 }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

enum HomeFormat {
    /// "500K", "1.2M" in every language (`TokenCount`).
    static func tokens(_ value: Double) -> String { TokenCount.compact(value) }
    static func money(_ value: Double) -> String { value.formatted(.currency(code: "USD").precision(.fractionLength(0))) }
    static func ago(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }
}

struct HomeSectionHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
            Spacer()
            trailing().buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
        }.padding(.horizontal, 2)
    }
}

struct HomeChip: View {
    var text: String
    var color: Color = AppAppearance.secondary
    var symbol: String
    var dimmed = false
    var action: () -> Void
    @State private var hovering = false
    init(count: Int, label: String, color: Color, symbol: String, action: @escaping () -> Void) {
        self.text = "\(count) \(label)"; self.color = color; self.symbol = symbol; self.dimmed = count == 0; self.action = action
    }
    init(text: String, symbol: String, action: @escaping () -> Void) {
        self.text = text; self.symbol = symbol; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(text).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            .foregroundStyle(dimmed ? AppAppearance.tertiary : color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(hovering ? AppAppearance.raised : AppAppearance.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(AppAppearance.separator))
            .contentShape(Capsule())
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}

private struct HomeTile: View {
    var initial: String? = nil
    var symbol: String? = nil
    var tint: Color
    var body: some View {
        Group {
            if let initial { Text(initial).font(.system(size: 16, weight: .semibold, design: .rounded)) }
            else if let symbol { Image(systemName: symbol).font(.system(size: 15, weight: .medium)) }
        }
        .foregroundStyle(tint)
        .frame(width: 40, height: 40)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct HomeEmptyCard<Actions: View>: View {
    var symbol: String
    var title: String
    var detail: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack(spacing: 14) {
            HomeTile(symbol: symbol, tint: AppAppearance.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
            }
            Spacer()
            actions()
        }.padding(16).modifier(AppCardSurface(radius: HomeStyle.cardRadius))
    }
}
