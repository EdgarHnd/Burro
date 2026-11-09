// Small shared controls drawn in Burro's own style instead of the stock AppKit look.
import SwiftUI

/// A small two-or-more option control drawn as one capsule.
struct CapsulePicker<Value: Hashable>: View {
    var options: [(value: Value, title: String)]
    @Binding var selection: Value
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button { withAnimation(.easeOut(duration: 0.15)) { selection = option.value } } label: {
                    Text(option.title).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == option.value ? AppAppearance.text : AppAppearance.secondary)
                        .padding(.horizontal, 12).frame(height: 26)
                        .background {
                            if selection == option.value {
                                Capsule().fill(AppAppearance.surface).shadow(color: AppAppearance.shadow, radius: 3, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(3).background(AppAppearance.raised, in: Capsule())
    }
}

/// An on/off pill with an icon.
struct TogglePill: View {
    var title: String
    var symbol: String
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? symbol : symbol + ".slash").font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isOn ? AppAppearance.text : AppAppearance.tertiary)
            .padding(.horizontal, 12).frame(height: 32)
            .background(isOn ? AppAppearance.surface : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(AppAppearance.separator))
        }.buttonStyle(.plain)
    }
}
