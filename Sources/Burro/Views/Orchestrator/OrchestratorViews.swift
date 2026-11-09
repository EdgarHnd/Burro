// The orchestrator in Burro: a card on Home to ask it anything, its pinned row in Chats, and
// the full conversation with a composer.
import SwiftUI
import BurroCore

enum OrchestratorStyle {
    static let gradient = LinearGradient(colors: [Color(red: 0.46, green: 0.36, blue: 0.98), Color(red: 0.93, green: 0.42, blue: 0.62)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
    static let tint = Color(red: 0.55, green: 0.40, blue: 0.95)
    @MainActor static func suggestions(_ store: AppStore) -> [String] {
        ["What needs me right now?", "Where is \(store.mainProject?.name ?? "my main project") at?", "Plan my day from my to-dos and chats"]
    }
}

struct OrchestratorAvatar: View {
    var size: CGFloat
    var working = false
    var body: some View {
        ZStack {
            Circle().fill(OrchestratorStyle.gradient)
            Image(systemName: "sparkles").font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(.white)
                .symbolEffect(.pulse, isActive: working)
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
            Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
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
                            .foregroundStyle(OrchestratorStyle.tint)
                            .padding(.horizontal, 7).padding(.vertical, 3).background(OrchestratorStyle.tint.opacity(0.12), in: Capsule())
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

// MARK: Chats

struct OrchestratorRow: View {
    var orchestrator: OrchestratorStore
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                OrchestratorAvatar(size: 28, working: orchestrator.running)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Orchestrator").font(.system(size: 13, weight: .semibold)).foregroundStyle(AppAppearance.text)
                    Text(orchestrator.activity ?? orchestrator.lastReply.map(plain) ?? "\(Orchestrator.modelTitle) · sees every chat and machine")
                        .font(.system(size: 11)).lineLimit(1).foregroundStyle(AppAppearance.tertiary)
                }
                Spacer(minLength: 6)
                if orchestrator.running { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(selected ? AppAppearance.surface : (hovering ? AppAppearance.hover : .clear),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? OrchestratorStyle.tint.opacity(0.35) : .clear))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
    /// One line of the latest reply without Markdown marks.
    private func plain(_ text: String) -> String {
        String(MarkdownBlock.inline(text).characters).replacingOccurrences(of: "\n", with: " ")
    }
}

struct OrchestratorDetail: View {
    @Bindable var store: AppStore
    var body: some View {
        let orchestrator = store.orchestrator
        let messages = orchestrator.messages
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                OrchestratorAvatar(size: 38, working: orchestrator.running)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Orchestrator").font(.system(size: 18, weight: .semibold))
                    Text("Claude Code · \(Orchestrator.modelTitle) · runs in Burro with your chats, machines, projects and to-dos")
                        .font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
                }
                Spacer()
                if !messages.isEmpty && !orchestrator.running {
                    PillButton(title: "New conversation", symbol: "square.and.pencil") { orchestrator.newConversation() }
                }
            }
            .padding(.horizontal, 26).padding(.vertical, 16)
            Rectangle().fill(AppAppearance.separator).frame(height: 1)
            Group {
                if messages.isEmpty {
                    VStack(spacing: 16) {
                        OrchestratorAvatar(size: 56)
                        Text("Your agents' project manager").font(.system(size: 20, weight: .semibold, design: .rounded))
                        Text("It sees every Codex and Claude chat on your machines, reads them when it needs detail, and can start new chats on this Mac. Ask what needs you, where a project stands, or to get something going.")
                            .font(.system(size: 13)).foregroundStyle(AppAppearance.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                        SuggestionChips(suggestions: OrchestratorStyle.suggestions(store)) { store.askOrchestrator($0) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ChatTranscriptView(transcript: ChatTranscript(messages: messages), provider: .claude)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                if let activity = orchestrator.activity {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text(activity).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                    }
                }
                if let error = orchestrator.error, !orchestrator.running {
                    Label(error, systemImage: "exclamationmark.bubble").font(.system(size: 12)).foregroundStyle(AppAppearance.amber).lineLimit(4)
                }
                OrchestratorComposer(orchestrator: orchestrator)
            }
            .frame(maxWidth: 820).frame(maxWidth: .infinity)
            .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 18)
        }
        .task { await orchestrator.loadHistory() }
    }
}
