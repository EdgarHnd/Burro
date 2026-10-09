// Compact desktop styling shared by every Burro surface; no layout or state ownership.
import SwiftUI

enum AppAppearance {
    static let background = Color(red: 0.105, green: 0.105, blue: 0.10)
    static let surface = Color(red: 0.155, green: 0.155, blue: 0.15)
    static let raised = Color(red: 0.205, green: 0.205, blue: 0.20)
    static let text = Color.white.opacity(0.88)
    static let secondary = Color.white.opacity(0.58)
    static let green = Color(red: 0.19, green: 0.79, blue: 0.34)
    static let lime = Color(red: 0.76, green: 0.90, blue: 0.29)
    static let amber = Color(red: 1, green: 0.73, blue: 0.05)
    static let blue = Color(red: 0.40, green: 0.68, blue: 1)
    static let claude = Color(red: 0.84, green: 0.46, blue: 0.29)
    static let separator = Color.white.opacity(0.07)
    static let pageTitle = Font.system(size: 18, weight: .semibold)
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let metric = Font.system(size: 20, weight: .semibold, design: .rounded)
    static let cardRadius: CGFloat = 14

    static func quotaGradient(remaining: Double?, stale: Bool) -> LinearGradient {
        let colors: [Color]
        if stale { colors = [.gray.opacity(0.65), .gray] }
        else if (remaining ?? 100) <= 10 { colors = [amber, .orange] }
        else { colors = [green, lime] }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}

struct AppCardSurface: ViewModifier {
    var radius: CGFloat = AppAppearance.cardRadius
    var translucent = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content
            .background(AppAppearance.surface.opacity(translucent && !reduceTransparency ? 0.5 : 1),
                in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(AppAppearance.separator))
    }
}

struct AppButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size == .mini ? 10 : 12, weight: .medium))
            .foregroundStyle((configuration.role == .destructive ? Color.red : AppAppearance.text).opacity(enabled ? 1 : 0.4))
            .padding(.horizontal, size == .mini ? 8 : 10).padding(.vertical, size == .mini ? 3 : 5)
            .background(AppAppearance.raised.opacity(configuration.isPressed ? 0.65 : 1), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(hovering && enabled ? 0.14 : 0.025)))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

struct AppTheme: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13))
            .foregroundStyle(AppAppearance.text)
            .tint(AppAppearance.text)
            .buttonStyle(AppButtonStyle())
            .controlSize(.small)
            .background(AppAppearance.background)
            .preferredColorScheme(.dark)
            .environment(\.colorScheme, .dark)
    }
}

struct ProviderBadge: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct AppEmptyState<Actions: View>: View {
    var title: String
    var symbol: String
    var detail: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 24, weight: .light)).foregroundStyle(AppAppearance.secondary)
                .accessibilityHidden(true)
            Text(title).font(AppAppearance.pageTitle)
            Text(detail).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            actions()
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension AppEmptyState where Actions == EmptyView {
    init(_ title: String, symbol: String, detail: String) {
        self.init(title: title, symbol: symbol, detail: detail) { EmptyView() }
    }
}

struct UsageQuotaBar: View {
    var percent: Double?
    var remaining: Double?
    var stale: Bool
    var marker: Double? = nil
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(AppAppearance.raised).frame(height: height)
                if let percent {
                    Capsule().fill(AppAppearance.quotaGradient(remaining: remaining, stale: stale))
                        .frame(width: geometry.size.width * min(100, max(0, percent)) / 100, height: height)
                }
                if let marker {
                    Capsule().fill(AppAppearance.text)
                        .frame(width: 3, height: height + 8)
                        .offset(x: max(0, min(geometry.size.width - 3, geometry.size.width * marker / 100 - 1.5)))
                }
            }.frame(height: height)
        }.frame(height: height).accessibilityHidden(true)
    }
}
