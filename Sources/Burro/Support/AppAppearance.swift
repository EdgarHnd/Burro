// Compact desktop styling shared by every Burro surface; no layout or state ownership.
// Every token resolves per appearance: warm paper in light mode, charcoal in dark mode.
// The notch panel pins itself to dark, so it keeps its black, camera-housing look.
import AppKit
import SwiftUI

enum AppAppearance {
    typealias RGBA = (Double, Double, Double, Double)
    static let background = adaptive(light: (0.957, 0.953, 0.941, 1), dark: (0.105, 0.105, 0.10, 1))
    static let surface = adaptive(light: (1, 1, 1, 1), dark: (0.155, 0.155, 0.15, 1))
    static let raised = adaptive(light: (0.925, 0.920, 0.905, 1), dark: (0.205, 0.205, 0.20, 1))
    static let text = adaptive(light: (0.11, 0.11, 0.10, 0.92), dark: (1, 1, 1, 0.88))
    static let secondary = adaptive(light: (0.11, 0.11, 0.10, 0.56), dark: (1, 1, 1, 0.58))
    static let tertiary = adaptive(light: (0.11, 0.11, 0.10, 0.36), dark: (1, 1, 1, 0.36))
    static let green = adaptive(light: (0.10, 0.58, 0.25, 1), dark: (0.19, 0.79, 0.34, 1))
    static let lime = adaptive(light: (0.42, 0.62, 0.08, 1), dark: (0.76, 0.90, 0.29, 1))
    static let amber = adaptive(light: (0.80, 0.50, 0.0, 1), dark: (1, 0.73, 0.05, 1))
    static let blue = adaptive(light: (0.14, 0.45, 0.88, 1), dark: (0.40, 0.68, 1, 1))
    static let claude = adaptive(light: (0.78, 0.38, 0.20, 1), dark: (0.84, 0.46, 0.29, 1))
    static let butter = adaptive(light: (0.93, 0.70, 0.12, 1), dark: (1, 0.83, 0.33, 1))
    static let separator = adaptive(light: (0, 0, 0, 0.08), dark: (1, 1, 1, 0.07))
    static let hairline = adaptive(light: (0, 0, 0, 0.14), dark: (1, 1, 1, 0.14))
    static let hover = adaptive(light: (0, 0, 0, 0.035), dark: (1, 1, 1, 0.045))
    static let shadow = adaptive(light: (0.25, 0.20, 0.10, 0.07), dark: (0, 0, 0, 0))
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
    /// Resolves against the drawing appearance, so one token serves both themes and the dark notch.
    static func adaptive(light: RGBA, dark: RGBA) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
    }
}

/// The desktop window follows this choice; the notch always stays dark.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    static let key = "appearance"
    var id: String { rawValue }
    var title: String {
        switch self { case .system: "Match System"; case .light: "Light"; case .dark: "Dark" }
    }
    var nsAppearance: NSAppearance? {
        switch self { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
    }
    static func load(_ defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .system
    }
    @MainActor func apply() { NSApp?.appearance = nsAppearance }
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
            .shadow(color: AppAppearance.shadow, radius: 10, y: 3)
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
            .overlay(Capsule().strokeBorder(hovering && enabled ? AppAppearance.hairline : AppAppearance.separator))
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
