// The Orchestrator's own page: the wrapper that feeds the layout (OrchestratorPageLayout.swift: the
// header with its sentence and Run triage now, the strip, the Brief · Memory · Runs tabs and the
// Brief tab's joined surface) its budget and the minute clock, and loads history, memory and runs
// when it appears. This file also holds the conversation column: today's conversation (each
// question, the steps it took, its answer, the reply or chat it proposed as a card to send or
// discard, and any to-do it changed as a line with Undo; proposals no visible turn shows wait under
// their own heading), with the composer, its model and effort menus and the reminder that proposals
// wait for you. The conversation's header reads back an earlier day ("Earlier days") and holds New
// conversation and whether it may read your notes.
import SwiftUI
import BurroCore

struct OrchestratorPage: View {
    @Bindable var store: AppStore
    var body: some View {
        // Ages and "last triage" move on by the minute while the page is open.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            OrchestratorPageLayout(store: store, budget: budget, now: context.date)
        }
        .background(AppAppearance.background)
        .task { await store.orchestrator.loadHistory() }
        .onAppear { store.orchestrator.reloadMemory(); store.orchestrator.reloadRuns() }
    }

    /// The Budget card from the Brief, today's runs and Claude's usage windows (nil when unknown).
    private var budget: OrchestratorBudget {
        let brief = store.brief
        let claude = store.usage.enabled ? store.usage.snapshot.providers.first { $0.id == .claude && $0.issue == nil } : nil
        return OrchestratorBudget(runsToday: brief.runsToday, cap: brief.dailyCap, runs: store.orchestrator.runsToday,
                                  claude: claude?.windows, enabled: brief.autoTriage, gate: brief.gate,
                                  budget: TriageBudget(dailyCap: brief.dailyCap))
    }
}

enum OrchestratorTab: String, CaseIterable, Identifiable {
    case brief = "Brief", memory = "Memory", runs = "Runs"
    var id: String { rawValue }
}

// MARK: Today's conversation

/// The tall left column: today's conversation (or an earlier day's), then the composer. It draws no
/// card of its own; it sits on the Brief tab's joined surface.
struct OrchestratorTodayCard: View {
    @Bindable var store: AppStore
    var now: Date

    var body: some View {
        let orchestrator = store.orchestrator
        VStack(spacing: 0) {
            cardHeader(orchestrator)
            Rectangle().fill(AppAppearance.separator).frame(height: 1)
            conversation(orchestrator).frame(maxHeight: .infinity)
            Rectangle().fill(AppAppearance.separator).frame(height: 1)
            OrchestratorAskBox(orchestrator: orchestrator)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cardHeader(_ orchestrator: OrchestratorStore) -> some View {
        HStack(spacing: 8) {
            if let viewing = orchestrator.viewing {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                    .accessibilityHidden(true)
                Text(OrchestratorSessions.title(day: viewing.day, today: now)).font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 6)
                Button("Back to today") { Task { await orchestrator.show(nil) } }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
            } else {
                Text("Today").font(.system(size: 15, weight: .semibold))
                Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                earlierMenu(orchestrator)
            }
            moreMenu(orchestrator)
        }
        .padding(.horizontal, 20).frame(height: 46)
    }

    private func earlierMenu(_ orchestrator: OrchestratorStore) -> some View {
        let earlier = orchestrator.earlierSessions
        return Menu {
            ForEach(earlier.prefix(30)) { session in
                Button(OrchestratorSessions.title(day: session.day, today: now) + (session.startedAt.map { ", started " + $0.formatted(date: .omitted, time: .shortened) } ?? "")) {
                    Task { await orchestrator.show(session) }
                }
            }
        } label: {
            Text("Earlier days").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(earlier.isEmpty || orchestrator.running)
        .help(earlier.isEmpty ? "No earlier conversations yet" : "Read back an earlier day's conversation")
    }

    private func moreMenu(_ orchestrator: OrchestratorStore) -> some View {
        Menu {
            Button("New conversation") { orchestrator.newConversation() }
                .disabled(orchestrator.running || orchestrator.messages.isEmpty || orchestrator.viewing != nil)
            Section("Settings") {
                Toggle("Let it read my notes", isOn: Bindable(orchestrator).notesAccess)
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(AppAppearance.secondary)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(orchestrator.running)
        .help("New conversation, and whether the orchestrator may read your notes")
        .accessibilityLabel("Conversation options")
    }

    @ViewBuilder private func conversation(_ orchestrator: OrchestratorStore) -> some View {
        let messages = orchestrator.messages
        let turns = ConversationTurn.turns(messages)
        let actions = orchestrator.actions
        let anchored = Set(turns.flatMap(\.proposalIDs))
        // Triage drafts the queue shows inline aren't listed again here.
        let inline = store.brief.shownInline(actions, now: now)
        let loose = actions.filter { !anchored.contains($0.id) && !inline.contains($0.id) && ($0.status == .pending || $0.status == .unconfirmed) && !$0.isLocal }
        if messages.isEmpty && loose.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        ForEach(turns) { turn in
                            let ids = turn.proposalIDs
                            TurnView(turn: turn, live: orchestrator.running && turn.id == turns.last?.id,
                                     activity: orchestrator.activity, title: chatTitle) {
                                ForEach(ids.compactMap { id in actions.first { $0.id == id } }) { action in
                                    if action.isLocal {
                                        OrchestratorLocalActionCard(store: store, action: action)
                                    } else {
                                        OrchestratorActionCard(store: store, action: action)
                                    }
                                }
                            }
                        }
                        let drafts = loose.filter { $0.conversation == BriefDrafts.triageConversation }
                        let earlier = loose.filter { $0.conversation != BriefDrafts.triageConversation }
                        ForEach([("Drafted by triage", drafts), ("Proposed earlier", earlier)], id: \.0) { title, group in
                            if !group.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    OrchSectionLabel(title: title, dot: nil)
                                    ForEach(group) { action in OrchestratorActionCard(store: store, action: action) }
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 20).padding(.vertical, 18)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: actions.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: messages.last?.text.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 12)
            Text("What should we get done?").font(.system(size: 20, weight: .bold))
            Text("It sees every Codex and Claude chat on your machines and reads them when it needs detail. It can draft replies and new chats for you to send. Ask what needs you, where a project stands, or to get something going.")
                .font(.system(size: 13)).foregroundStyle(AppAppearance.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
            let suggestions: [(String, String)] = [
                ("hand.raised", "What needs me right now?"),
                ("flag", "Where is \(store.mainProject?.name ?? "my main project") at?"),
                ("sun.max", "Plan my day from my to-dos and chats"),
                ("arrow.triangle.branch", "Which worktrees can I clean up?"),
            ]
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(suggestions, id: \.1) { item in SuggestionCard(symbol: item.0, text: item.1) { store.askOrchestrator(item.1) } }
            }
            .frame(maxWidth: 520).padding(.top, 4)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chatTitle(_ id: String) -> String? {
        let key = id.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        return store.notchChatSessions.first { $0.id.lowercased() == key || $0.id.lowercased().hasSuffix(":" + key) }?.title
    }
}

/// The composer under the conversation: the message, model and effort menus, and Ask (Stop while
/// it answers). Return sends what you typed or changed (an untouched "Ask the Orchestrator about
/// this chat" prefill goes only by Ask); ⌥Return adds a line. Text put in the field from elsewhere
/// takes focus.
struct OrchestratorAskBox: View {
    @Bindable var orchestrator: OrchestratorStore
    @FocusState private var focused: Bool

    var body: some View {
        let empty = orchestrator.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 8) {
            if let error = orchestrator.error, !orchestrator.running {
                Label(error, systemImage: "exclamationmark.bubble").font(.system(size: 12)).foregroundStyle(AppAppearance.amber).lineLimit(4)
            }
            if let problem = orchestrator.setupProblem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(AppAppearance.amber)
            }
            Text("Ask, or tell it what to start").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
            TextField("What did the agents finish while I was away?", text: $orchestrator.draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(2...6)
                .focused($focused).onSubmit { orchestrator.submitFromReturn() }
                // A question put here from elsewhere ("Ask the Orchestrator about this chat", the
                // palette) gets the cursor, ready to edit or Ask; nothing is sent.
                .onAppear { focusIfPrefilled() }
                .onChange(of: orchestrator.draft) { _, _ in focusIfPrefilled() }
                .modifier(OrchField())
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(focused ? AppAppearance.hairline : .clear))
                .accessibilityLabel("Ask, or tell it what to start")
            HStack(spacing: 6) {
                chip(title: "Claude · " + Orchestrator.modelTitle(orchestrator.model),
                     help: "Which Claude model the orchestrator runs on; applies from your next message.") {
                    Picker("Model", selection: $orchestrator.model) {
                        ForEach(Orchestrator.models) { model in
                            Text(model.id == Orchestrator.model ? "\(model.title) (default)" : model.title).tag(model.id)
                        }
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
                chip(title: Orchestrator.effortTitle(orchestrator.effort) + " effort",
                     help: "How hard the orchestrator thinks. Higher is more careful and slower; applies from your next message.") {
                    Picker("Effort", selection: $orchestrator.effort) {
                        ForEach(Orchestrator.efforts, id: \.self) { Text(Orchestrator.effortTitle($0)).tag($0) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
                Spacer(minLength: 6)
                Text("Proposals wait for you before anything starts").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                    .lineLimit(1).truncationMode(.tail)
                if orchestrator.running {
                    Button("Stop") { orchestrator.stop() }.buttonStyle(OrchButtonStyle(kind: .bordered, large: true))
                        .help("Stop this answer")
                } else {
                    Button("Ask", action: send).buttonStyle(OrchButtonStyle(kind: .primary, large: true)).disabled(empty)
                        .help("Send to the orchestrator (Return sends what you typed or changed)")
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 14)
    }

    private func send() { orchestrator.send(orchestrator.draft) }

    private func focusIfPrefilled() {
        guard !focused, !orchestrator.draft.isEmpty else { return }
        DispatchQueue.main.async { focused = true }
    }

    private func chip<Content: View>(title: String, help: String, @ViewBuilder content: () -> Content) -> some View {
        Menu { content() } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).accessibilityHidden(true)
            }
            .foregroundStyle(AppAppearance.secondary)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(AppAppearance.raised.opacity(0.6)))
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(orchestrator.running)
        .help(help)
    }
}

// MARK: Turns

/// One question and everything the orchestrator did for it.
struct ConversationTurn: Identifiable, Equatable {
    var id: Int
    var question: ChatMessage?
    /// Tool calls and the notes it wrote between them, in order.
    var steps: [ChatMessage] = []
    /// Its final reply (or the reply being written).
    var answer: ChatMessage?

    /// Proposals its reply_chat and start_chat steps recorded, and to-do changes its add_todo and
    /// complete_todo steps asked for, by the id their results lead with.
    var proposalIDs: [String] {
        steps.filter { $0.kind == .tool && Self.recordingTools.contains($0.tool ?? "") }.compactMap { step in
            step.output?.firstMatch(of: /^(?:Proposal|To-do action) ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/).map { String($0.1) }
        }
    }
    static let recordingTools: Set<String> = ["reply_chat", "start_chat", "add_todo", "complete_todo"]

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

private struct SuggestionCard: View {
    var symbol: String
    var text: String
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(AppAppearance.secondary).frame(width: 18)
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

private struct TurnView<Proposals: View>: View {
    var turn: ConversationTurn
    var live: Bool
    var activity: String?
    var title: (String) -> String?
    /// Cards for what this turn proposed.
    @ViewBuilder var proposals: () -> Proposals
    /// A tool call is in flight, and its own row already shows a spinner.
    private var stepRunning: Bool { turn.steps.last.map { $0.kind == .tool && $0.output == nil } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let question = turn.question {
                HStack {
                    Spacer(minLength: 80)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(question.text).font(.system(size: 13)).textSelection(.enabled)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(AppAppearance.raised, in: UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14,
                                                                                          bottomTrailingRadius: 4, topTrailingRadius: 14, style: .continuous))
                        if let at = question.at {
                            Text(Calendar.current.isDateInToday(at) ? at.formatted(date: .omitted, time: .shortened) : at.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 10.5)).foregroundStyle(AppAppearance.tertiary).padding(.trailing, 6)
                        }
                    }
                    .frame(maxWidth: 560, alignment: .trailing)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                if !turn.steps.isEmpty { StepsView(steps: turn.steps, live: live, title: title) }
                if let answer = turn.answer {
                    MarkdownBlock(text: answer.text, size: 13.5)
                } else if live && !stepRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(activity ?? "Thinking…").font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary)
                    }.padding(.top, 3)
                }
                proposals()
            }
            .frame(maxWidth: 640, alignment: .leading)
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
                                .foregroundStyle(AppAppearance.secondary).frame(width: 20, height: 20)
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
                    Rectangle().fill(AppAppearance.hairline).frame(width: 1.5).padding(.top, 12).padding(.bottom, 4)
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
        case "start_chat": return ("plus.bubble", detail.isEmpty ? "Proposed a chat" : "Proposed a chat: \(detail)")
        case "reply_chat": return ("arrowshape.turn.up.left", title(detail).map { "Proposed a reply to “\($0)”" } ?? "Proposed a reply")
        case "brief": return ("list.bullet.rectangle", "Read the brief")
        case "chat_digest": return ("text.bubble", title(detail).map { "Checked “\($0)”" } ?? "Checked a chat")
        case "read_shipped": return ("shippingbox", "Checked what shipped")
        case "usage": return ("gauge.with.dots.needle.33percent", "Checked usage")
        case "read_notes": return ("note.text", "Read notes")
        case "add_todo": return ("checklist", "Added a to-do")
        case "complete_todo": return ("checkmark.circle", "Completed a to-do")
        case "remember": return ("bookmark", "Noted for later")
        case "forget": return ("bookmark.slash", "Dropped a note")
        case "Read", "read_file": return ("doc.text", detail.isEmpty ? "Read a file" : "Read \(URL(fileURLWithPath: detail).lastPathComponent)")
        case "search_files": return ("magnifyingglass", detail.isEmpty ? "Searched files" : "Searched for \(detail)")
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
                            .overlay(Circle().strokeBorder(AppAppearance.tertiary, lineWidth: 1.5))
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

