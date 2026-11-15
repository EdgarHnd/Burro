// Shared orchestrator pieces: its colours, avatar and composer. Home shows it as the Brief
// (HomeBrief.swift); the full conversation lives on its own page (OrchestratorPage.swift).
import SwiftUI
import BurroCore

/// The orchestrator is Burro's butter in gold: fills use the butter colour, text and small icons
/// a deeper gold that stays readable on the light background.
enum OrchestratorStyle {
    static let gradient = LinearGradient(colors: [Color(red: 1.0, green: 0.86, blue: 0.40), Color(red: 0.95, green: 0.70, blue: 0.18)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
    static let tint = HomeStyle.butter
    static let ink = AppAppearance.adaptive(light: (0.64, 0.45, 0.03, 1), dark: (1, 0.83, 0.33, 1))
    /// Icons drawn on the gold gradient.
    static let onGold = Color(red: 0.16, green: 0.13, blue: 0.08)
}

/// Burro's butter in gold, with sunglasses and a warm glow (brighter while it works).
struct OrchestratorAvatar: View {
    var size: CGFloat
    var working = false
    var body: some View {
        ZStack {
            Circle().fill(OrchestratorStyle.tint.opacity(working ? 0.34 : 0.21))
                .frame(width: size * 0.7, height: size * 0.7).blur(radius: size * 0.32)
                .animation(.easeInOut(duration: 0.4), value: working)
            BurroMark(active: true, working: working, tint: OrchestratorStyle.tint, shades: true)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

/// Type a message; Return sends, ⌥Return adds a line.
struct OrchestratorComposer: View {
    @Bindable var orchestrator: OrchestratorStore
    var placeholder = "Ask the orchestrator…"
    @FocusState private var focused: Bool
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $orchestrator.draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...6)
                .focused($focused).onSubmit(send)
                .padding(.vertical, 8)
            if orchestrator.running {
                circleButton("stop.fill", help: "Stop") { orchestrator.stop() }
            } else {
                circleButton("arrow.up", help: "Send", enabled: !orchestrator.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: send)
            }
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 3)
        .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(focused ? OrchestratorStyle.tint.opacity(0.55) : AppAppearance.separator))
    }
    private func send() { orchestrator.send(orchestrator.draft) }
    private func circleButton(_ symbol: String, help: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(enabled ? OrchestratorStyle.onGold : .white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(enabled ? AnyShapeStyle(OrchestratorStyle.gradient) : AnyShapeStyle(AppAppearance.tertiary.opacity(0.35))))
        }
        .buttonStyle(.plain).disabled(!enabled).help(help).padding(.bottom, 2)
    }
}
