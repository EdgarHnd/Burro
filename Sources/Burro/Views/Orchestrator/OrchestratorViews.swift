// Shared orchestrator pieces (avatar, composer, suggestion chips) and its Home card. The full
// conversation lives on its own page (OrchestratorPage.swift).
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
    @MainActor static func suggestions(_ store: AppStore) -> [String] {
        ["What needs me right now?", "Where is \(store.mainProject?.name ?? "my main project") at?", "Plan my day from my to-dos and chats"]
    }
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

struct SuggestionChips: View {
    var suggestions: [String]
    var pick: (String) -> Void
    var body: some View {
        HStack(spacing: 6) {
            ForEach(suggestions, id: \.self) { text in
                Button { pick(text) } label: {
                    Text(text).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(AppAppearance.raised.opacity(0.7), in: Capsule())
                }.buttonStyle(.plain)
            }
        }
    }
}

// MARK: Home

struct HomeOrchestrator: View {
    @Bindable var store: AppStore
    var body: some View {
        let orchestrator = store.orchestrator
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                OrchestratorAvatar(size: 40, working: orchestrator.running)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Orchestrator").font(.system(size: 17, weight: .semibold))
                        Text(Orchestrator.modelTitle.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.8)
                            .foregroundStyle(OrchestratorStyle.ink)
                            .padding(.horizontal, 7).padding(.vertical, 3).background(OrchestratorStyle.tint.opacity(0.2), in: Capsule())
                    }
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if !orchestrator.messages.isEmpty {
                    PillButton(title: "Open", symbol: "arrow.up.left.and.arrow.down.right") { store.showOrchestrator() }
                }
            }
            latest(orchestrator)
            OrchestratorComposer(orchestrator: orchestrator, placeholder: "Ask about your chats, machines and projects, or have it start work…")
            if orchestrator.messages.isEmpty && !orchestrator.running {
                SuggestionChips(suggestions: OrchestratorStyle.suggestions(store)) { store.askOrchestrator($0) }
            }
            if let problem = orchestrator.setupProblem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(AppAppearance.amber)
            }
        }
        .padding(20)
        .modifier(SoftSurface(radius: 22, shadowRadius: 14, y: 4))
        .task { await orchestrator.loadHistory() }
    }

    private var subtitle: String {
        let chats = store.homeSummary.counts
        let machines = 1 + store.remoteHosts.filter(\.enabled).count
        return "Watches \(machines == 1 ? "this Mac" : "\(machines) machines") · \(chats.running) running, \(chats.waiting) need you · starts chats for you"
    }

    @ViewBuilder private func latest(_ orchestrator: OrchestratorStore) -> some View {
        if let error = orchestrator.error, !orchestrator.running {
            Label(error, systemImage: "exclamationmark.bubble").font(.system(size: 12)).foregroundStyle(AppAppearance.amber).lineLimit(3)
        }
        if orchestrator.running || orchestrator.lastReply != nil {
            Button { store.showOrchestrator() } label: {
                VStack(alignment: .leading, spacing: 8) {
                    if let question = orchestrator.lastQuestion {
                        Text(question).font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
                    }
                    if let reply = orchestrator.lastReply, !(orchestrator.running && orchestrator.streaming.isEmpty) {
                        Text(MarkdownBlock.inline(reply)).font(.system(size: 13)).lineSpacing(2).foregroundStyle(AppAppearance.text)
                            .lineLimit(7).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let activity = orchestrator.activity {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.mini)
                            Text(activity).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                        }
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppAppearance.raised.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
            }.buttonStyle(.plain).help("Open the conversation")
        }
    }
}
