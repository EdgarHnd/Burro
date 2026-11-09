// The Orchestrator's own page: one focused conversation in the middle (each question, the steps
// it took, its answer) and, on the right, the agents it oversees across your machines with their
// subagents, live.
import SwiftUI
import BurroCore

struct OrchestratorPage: View {
    @Bindable var store: AppStore
    var body: some View {
        HStack(spacing: 0) {
            OrchestratorConversation(store: store).frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(AppAppearance.separator).frame(width: 1)
            OrchestratorAgentsPanel(store: store).frame(width: 340)
        }
        .background(AppAppearance.background)
        .task { await store.orchestrator.loadHistory() }
    }
}

// MARK: Conversation

/// One question and everything the orchestrator did for it.
struct ConversationTurn: Identifiable, Equatable {
    var id: Int
    var question: ChatMessage?
    /// Tool calls and the notes it wrote between them, in order.
    var steps: [ChatMessage] = []
    /// Its final reply (or the reply being written).
    var answer: ChatMessage?

    static func turns(_ messages: [ChatMessage]) -> [ConversationTurn] {
        var turns: [ConversationTurn] = []
        for message in messages {
            if message.kind == .user {
                turns.append(ConversationTurn(id: message.id, question: message))
                continue
            }
            if turns.isEmpty { turns.append(ConversationTurn(id: message.id)) }
            var turn = turns.removeLast()
            if let answer = turn.answer { turn.steps.append(answer); turn.answer = nil }
            if message.kind == .assistant { turn.answer = message } else { turn.steps.append(message) }
            turns.append(turn)
        }
        return turns
    }
}

private struct OrchestratorConversation: View {
    @Bindable var store: AppStore
    var body: some View {
        let orchestrator = store.orchestrator
        let messages = orchestrator.messages
        let turns = ConversationTurn.turns(messages)
        VStack(spacing: 0) {
            header(orchestrator, empty: messages.isEmpty)
            if messages.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 34) {
                            ForEach(turns) { turn in
                                TurnView(turn: turn, live: orchestrator.running && turn.id == turns.last?.id,
                                         activity: orchestrator.activity, title: chatTitle)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 36).padding(.top, 8).padding(.bottom, 24)
                        .frame(maxWidth: 780).frame(maxWidth: .infinity)
                    }
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: messages.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: messages.last?.text.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if let error = orchestrator.error, !orchestrator.running {
                    Label(error, systemImage: "exclamationmark.bubble").font(.system(size: 12)).foregroundStyle(AppAppearance.amber).lineLimit(4)
                }
                if let problem = orchestrator.setupProblem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(AppAppearance.amber)
                }
                OrchestratorComposer(orchestrator: orchestrator, placeholder: messages.isEmpty ? "Ask anything about your agents, or have it start work…" : "Reply to the orchestrator…")
                    .shadow(color: AppAppearance.shadow, radius: 10, y: 3)
            }
            .frame(maxWidth: 780).frame(maxWidth: .infinity)
            .padding(.horizontal, 36).padding(.top, 6).padding(.bottom, 22)
        }
    }

    private func header(_ orchestrator: OrchestratorStore, empty: Bool) -> some View {
        HStack(spacing: 14) {
            OrchestratorAvatar(size: 44, working: orchestrator.running)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Orchestrator").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(Orchestrator.modelTitle.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.8)
                        .foregroundStyle(OrchestratorStyle.ink)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(OrchestratorStyle.tint.opacity(0.2), in: Capsule())
                }
                HStack(spacing: 6) {
                    Circle().fill(orchestrator.running ? OrchestratorStyle.tint : AppAppearance.green).frame(width: 6, height: 6)
                    Text(orchestrator.activity ?? status).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
                }
            }
            Spacer()
            if !empty && !orchestrator.running {
                PillButton(title: "New conversation", symbol: "square.and.pencil") { orchestrator.newConversation() }
            }
        }
        .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 14)
    }

    private var status: String {
        let counts = store.homeSummary.counts
        let machines = 1 + store.remoteHosts.filter(\.enabled).count
        var parts = ["Ready", "watching \(machines == 1 ? "this Mac" : "\(machines) machines")", "\(counts.running) running"]
        if counts.waiting > 0 { parts.append("\(counts.waiting) need you") }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 20)
            OrchestratorAvatar(size: 76)
            VStack(spacing: 8) {
                Text("What should we get done?").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("I see every Codex and Claude chat on your machines, read them when I need detail, and start new ones on this Mac. Ask what needs you, where a project stands, or to get something going.")
                    .font(.system(size: 13.5)).foregroundStyle(AppAppearance.secondary).multilineTextAlignment(.center).frame(maxWidth: 500)
            }
            let suggestions: [(String, String)] = [
                ("hand.raised", "What needs me right now?"),
                ("flag", "Where is \(store.mainProject?.name ?? "my main project") at?"),
                ("sun.max", "Plan my day from my to-dos and chats"),
                ("arrow.triangle.branch", "Which worktrees can I clean up?"),
            ]
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(suggestions, id: \.1) { item in SuggestionCard(symbol: item.0, text: item.1) { store.askOrchestrator(item.1) } }
            }
            .frame(maxWidth: 560).padding(.top, 6)
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chatTitle(_ id: String) -> String? {
        let key = id.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        return store.notchChatSessions.first { $0.id.lowercased() == key || $0.id.lowercased().hasSuffix(":" + key) }?.title
    }
}

private struct SuggestionCard: View {
    var symbol: String
    var text: String
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(OrchestratorStyle.ink).frame(width: 18)
                Text(text).font(.system(size: 13)).foregroundStyle(AppAppearance.text).multilineTextAlignment(.leading).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).frame(height: 54)
            .background(hovering ? AppAppearance.raised : AppAppearance.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppAppearance.separator))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
    }
}

private struct TurnView: View {
    var turn: ConversationTurn
    var live: Bool
    var activity: String?
    var title: (String) -> String?
    /// A tool call is in flight, and its own row already shows a spinner.
    private var stepRunning: Bool { turn.steps.last.map { $0.kind == .tool && $0.output == nil } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let question = turn.question {
                HStack {
                    Spacer(minLength: 120)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(question.text).font(.system(size: 14)).textSelection(.enabled)
                            .padding(.horizontal, 15).padding(.vertical, 10)
                            .background(OrchestratorStyle.tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        if let at = question.at {
                            Text(Calendar.current.isDateInToday(at) ? at.formatted(date: .omitted, time: .shortened) : at.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 10.5)).foregroundStyle(AppAppearance.tertiary).padding(.trailing, 6)
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                OrchestratorAvatar(size: 26, working: live)
                VStack(alignment: .leading, spacing: 12) {
                    if !turn.steps.isEmpty { StepsView(steps: turn.steps, live: live, title: title) }
                    if let answer = turn.answer {
                        MarkdownBlock(text: answer.text, size: 14.5)
                    } else if live && !stepRunning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(activity ?? "Thinking…").font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary)
                        }.padding(.top, 3)
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

/// What the orchestrator did before answering: a one-line summary that opens into a timeline.
private struct StepsView: View {
    var steps: [ChatMessage]
    var live: Bool
    var title: (String) -> String?
    @State private var open = false
    var body: some View {
        let tools = steps.filter { $0.kind == .tool }
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.18)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    HStack(spacing: -5) {
                        ForEach(Array(tools.prefix(4).enumerated()), id: \.offset) { _, step in
                            Image(systemName: Self.describe(step, title: title).symbol).font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(OrchestratorStyle.ink).frame(width: 20, height: 20)
                                .background(Circle().fill(AppAppearance.surface)).overlay(Circle().strokeBorder(AppAppearance.separator))
                        }
                    }
                    Text(summary(tools)).font(.system(size: 12.5)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(AppAppearance.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(steps) { step in StepRow(step: step, live: live, title: title) }
                }
                .padding(.leading, 9).padding(.top, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(OrchestratorStyle.tint.opacity(0.5)).frame(width: 1.5).padding(.top, 12).padding(.bottom, 4)
                }
            }
        }
    }
    /// Steps stay open while the turn runs; finished turns fold to one line.
    private var expanded: Bool { live || open }
    private func summary(_ tools: [ChatMessage]) -> String {
        let labels = tools.map { Self.describe($0, title: title).text }
        var unique: [String] = []
        for label in labels where !unique.contains(label) { unique.append(label) }
        let head = unique.prefix(2).joined(separator: ", ")
        return unique.count > 2 ? "\(head) and \(unique.count - 2) more" : (head.isEmpty ? "Thought it through" : head)
    }

    static func describe(_ step: ChatMessage, title: (String) -> String?) -> (symbol: String, text: String) {
        let detail = step.text.hasPrefix("mcp__") ? "" : step.text
        switch step.tool ?? "" {
        case "overview": return ("square.grid.2x2", "Looked at everything")
        case "list_chats": return ("bubble.left.and.bubble.right", "Listed chats")
        case "read_chat": return ("text.bubble", title(detail).map { "Read “\($0)”" } ?? "Read a chat")
        case "list_worktrees": return ("arrow.triangle.branch", "Checked worktrees")
        case "start_chat": return ("plus.bubble", detail.isEmpty ? "Started a chat" : "Started a chat: \(detail)")
        case "Read": return ("doc.text", detail.isEmpty ? "Read a file" : "Read \(URL(fileURLWithPath: detail).lastPathComponent)")
        case "Grep": return ("magnifyingglass", detail.isEmpty ? "Searched files" : "Searched for \(detail)")
        case "Glob": return ("magnifyingglass", detail.isEmpty ? "Looked for files" : "Looked for \(detail)")
        default: return ("gearshape", step.tool ?? "Tool")
        }
    }
}

private struct StepRow: View {
    var step: ChatMessage
    var live: Bool
    var title: (String) -> String?
    @State private var showOutput = false
    var body: some View {
        if step.kind == .assistant {
            // A note it wrote between steps.
            Text(MarkdownBlock.inline(step.text)).font(.system(size: 12.5)).foregroundStyle(AppAppearance.secondary)
                .padding(.leading, 14).textSelection(.enabled)
        } else {
            let described = StepsView.describe(step, title: title)
            VStack(alignment: .leading, spacing: 6) {
                Button { if step.output?.isEmpty == false { withAnimation(.easeOut(duration: 0.15)) { showOutput.toggle() } } } label: {
                    HStack(spacing: 8) {
                        Circle().fill(AppAppearance.background).frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(OrchestratorStyle.ink.opacity(0.7), lineWidth: 1.5))
                            .offset(x: -4)
                        if live && step.output == nil {
                            ProgressView().controlSize(.mini).frame(width: 14)
                        } else {
                            Image(systemName: described.symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(AppAppearance.tertiary).frame(width: 14)
                        }
                        Text(described.text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
                        if step.output?.isEmpty == false {
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(AppAppearance.tertiary)
                                .rotationEffect(.degrees(showOutput ? 90 : 0))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showOutput, let output = step.output {
                    Text(output).font(.system(size: 11, design: .monospaced)).foregroundStyle(AppAppearance.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(AppAppearance.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.leading, 24)
                }
            }
        }
    }
}

// MARK: Agents panel

/// The agents the orchestrator oversees: chats it started, then everything that needs you, is
/// working or has a result, with their subagents. Live from Burro's monitoring.
struct OrchestratorAgentsPanel: View {
    @Bindable var store: AppStore
    var body: some View {
        let sessions = unique(store.notchChatSessions)
        let roots = sessions.filter { $0.isSubagent != true }
        let started = store.orchestrator.startedChatIDs.compactMap { id in roots.first { $0.id == id || $0.id.hasSuffix(":" + id) } }
        let startedIDs = Set(started.map(\.id))
        let rest = roots.filter { !startedIDs.contains($0.id) }
        let needs = rest.filter { $0.state == .waiting && $0.remote?.stale != true }
        let working = rest.filter { $0.state == .working || $0.state == .scheduled }
        let unread = rest.filter(\.isDone)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agents").font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("What the orchestrator is watching, live").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                }
                machines
                if !started.isEmpty { section("Started by the orchestrator", OrchestratorStyle.tint, started, sessions) }
                if !needs.isEmpty { section("Needs you", AppAppearance.amber, needs, sessions) }
                if !working.isEmpty { section("Working", AppAppearance.green, working, sessions) }
                if !unread.isEmpty { section("Ready to read", AppAppearance.blue, unread, sessions) }
                if started.isEmpty && needs.isEmpty && working.isEmpty && unread.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "moon.zzz").font(.system(size: 22)).foregroundStyle(AppAppearance.tertiary)
                        Text("All quiet. Nothing is running on your machines.").font(.system(size: 12.5)).foregroundStyle(AppAppearance.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 20)
        }
        .background(AppAppearance.raised.opacity(0.22))
    }

    private var machines: some View {
        VStack(spacing: 6) {
            ForEach(store.homeSummary.machines) { machine in
                HStack(spacing: 8) {
                    Circle().fill(color(machine.connection)).frame(width: 7, height: 7)
                    Text(machine.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 6)
                    if machine.counts.running > 0 {
                        Label("\(machine.counts.running)", systemImage: "waveform.path").font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                            .foregroundStyle(AppAppearance.green)
                    }
                    if machine.counts.waiting > 0 {
                        Label("\(machine.counts.waiting)", systemImage: "hand.raised").font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                            .foregroundStyle(AppAppearance.amber)
                    }
                    if machine.counts.running + machine.counts.waiting == 0 {
                        Text(machine.connection == .offline ? "Offline" : "Quiet").font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary)
                    }
                }
                .padding(.horizontal, 12).frame(height: 34)
                .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AppAppearance.separator))
            }
        }
    }

    private func section(_ title: String, _ color: Color, _ chats: [AgentSession], _ all: [AgentSession]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.7)
                Text("\(chats.count)").font(.system(size: 10.5)).monospacedDigit().opacity(0.6)
            }
            .foregroundStyle(AppAppearance.tertiary).padding(.leading, 4).padding(.bottom, 4)
            ForEach(chats.sorted { $0.updatedAt > $1.updatedAt }) { chat in
                AgentPanelRow(session: chat, place: ChatsModel.place(chat, store: store), subagents: subagents(of: chat, in: all),
                              open: { store.showChat(chat) },
                              ask: { store.orchestrator.draft = "What's the latest on “\(chat.title)” (\(chat.remote?.hostName ?? "This Mac"))?" })
            }
        }
    }

    private func subagents(of chat: AgentSession, in all: [AgentSession]) -> [AgentSession] {
        all.filter { child in
            guard child.isSubagent == true, let parent = child.parentSessionID else { return false }
            return parent == chat.id || chat.id.hasSuffix(":" + parent) || parent.hasSuffix(chat.id)
        }
        .sorted { ($0.state == .working ? 0 : 1, $1.updatedAt) < ($1.state == .working ? 0 : 1, $0.updatedAt) }
    }
    private func unique(_ sessions: [AgentSession]) -> [AgentSession] {
        var seen = Set<String>()
        return sessions.filter { seen.insert($0.id).inserted }
    }
    private func color(_ connection: HomeMachine.Connection) -> Color {
        switch connection {
        case .local, .online: AppAppearance.green
        case .stale, .connecting: AppAppearance.amber
        case .offline, .paused: AppAppearance.tertiary
        }
    }
}

private struct AgentPanelRow: View {
    var session: AgentSession
    var place: String
    var subagents: [AgentSession]
    var open: () -> Void
    var ask: () -> Void
    @State private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                AgentAvatar(session: session, active: hovering, working: session.state == .working, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(1).foregroundStyle(AppAppearance.text)
                    Text(place).font(.system(size: 11)).lineLimit(1).foregroundStyle(AppAppearance.tertiary)
                }
                Spacer(minLength: 4)
                if hovering {
                    Button(action: ask) {
                        Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold)).foregroundStyle(OrchestratorStyle.onGold)
                            .frame(width: 22, height: 22).background(Circle().fill(OrchestratorStyle.gradient))
                    }
                    .buttonStyle(.plain).help("Ask the orchestrator about this chat")
                } else {
                    Text(HomeFormat.ago(session.updatedAt)).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                }
            }
            ForEach(subagents.prefix(4)) { child in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(AppAppearance.tertiary)
                    Circle().fill(child.state == .working ? AppAppearance.green : AppAppearance.tertiary.opacity(0.5)).frame(width: 5, height: 5)
                    Text(child.title).font(.system(size: 11.5)).lineLimit(1).foregroundStyle(AppAppearance.secondary)
                    Spacer(minLength: 4)
                    Text(child.state == .working ? "working" : "idle").font(.system(size: 10.5)).foregroundStyle(AppAppearance.tertiary)
                }
                .padding(.leading, 40)
            }
            if subagents.count > 4 {
                Text("+\(subagents.count - 4) more subagents").font(.system(size: 10.5)).foregroundStyle(AppAppearance.tertiary).padding(.leading, 54)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(hovering ? AppAppearance.surface : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .help("Open this chat")
    }
}
