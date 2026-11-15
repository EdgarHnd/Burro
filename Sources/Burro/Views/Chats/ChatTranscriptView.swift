// A chat's conversation, laid out like the Claude app: a long opening brief as the chat's task,
// your messages as bubbles (a reply just sent from Burro shows dimmed as "Sending…" until the log
// has it), replies as Markdown, runs of tool calls folded into one line (open for each call and its
// output), the plan as a checklist. While the chat works, what it's doing right now sits in a strip
// under the conversation. The view follows new messages only while you're at the bottom; scrolled
// up, it stays put and offers "↓ N new". When the chat waits on you, "Jump to last question" (⌘↑).
// A chat on another machine shows Burro's copy of it at once (`RemoteTranscriptMirror`), then
// updates; while that machine can't be reached the copy stays readable "as of" its last update, and
// "Show earlier messages" at the top fetches more of its history when the copy doesn't start at
// the beginning.
import SwiftUI
import BurroCore

/// Loads a chat for the Chats page and keeps it current. A reload that finds the chat unchanged
/// (the worker says so, or an SSH fetch returns the same messages) leaves `transcript` untouched,
/// so the page doesn't redraw on every poll. Remote chats go through Burro's copy: the cached copy
/// shows first, each reload fetches only what was added, and when the machine can't be reached
/// `offline` and `syncedAt` say how current the copy shown is.
@MainActor @Observable final class TranscriptLoader {
    /// What the page shows: the logged conversation plus replies still sending.
    private(set) var transcript: ChatTranscript?
    private(set) var error: String?
    /// True only while a chat is read for the first time (later polls are silent).
    private(set) var loading = false
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var logged: ChatTranscript?
    @ObservationIgnored private var revision: UInt64?
    @ObservationIgnored private var echoes: [ChatEcho] = []
    @ObservationIgnored private var loadedID: String?
    /// Remote chats: why the copy shown isn't current (nil while it is), and when it last was.
    private(set) var offline: RemoteTranscriptMirror.Offline?
    private(set) var syncedAt: Date?
    /// Remote chats: the copy can fetch messages from before what it holds.
    private(set) var canShowEarlier = false
    private(set) var loadingEarlier = false
    /// Messages asked of the parser; "Show earlier messages" raises it.
    @ObservationIgnored private var limit = 300
    /// Keeps the remote copy on screen from eviction.
    @ObservationIgnored private var hold: RemoteTranscriptMirror.Hold?

    /// A reply sent from Burro hasn't reached the chat's log yet.
    var awaitingEcho: Bool { !echoes.isEmpty }

    func load(_ session: AgentSession, host: RemoteHost?, profiles: [UsageProvider: String], force: Bool = false) async {
        await load(session, host: host, profiles: profiles, force: force, earlier: false)
    }

    /// Fetches earlier history of a remote chat into its copy and shows more messages.
    func loadEarlier(_ session: AgentSession, host: RemoteHost?, profiles: [UsageProvider: String]) async {
        guard loadedID == session.id, !busy else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        limit = 500
        await load(session, host: host, profiles: profiles, force: true, earlier: true)
    }

    private func load(_ session: AgentSession, host: RemoteHost?, profiles: [UsageProvider: String], force: Bool, earlier: Bool) async {
        if busy { return }
        if loadedID != session.id {
            if transcript != nil { transcript = nil }
            if error != nil { error = nil }
            if offline != nil { offline = nil }
            if syncedAt != nil { syncedAt = nil }
            if canShowEarlier { canShowEarlier = false }
            logged = nil; revision = nil; echoes = []; loadedID = session.id; limit = 300
            hold = session.remote != nil ? RemoteTranscriptMirror.Hold(chatID: session.id) : nil
        }
        busy = true
        let first = logged == nil
        if first { loading = true }
        defer { busy = false; if first { loading = false } }
        let limit = limit
        if let host, session.remote != nil {
            if first {
                // The copy Burro already has shows while the machine is asked for what's new.
                let cached = await Task.detached(priority: .userInitiated) {
                    RemoteTranscriptMirror.shared.cached(chatID: session.id, host: host, limit: limit)
                }.value
                guard loadedID == session.id else { return }
                if let cached { apply(.success(cached)) }
            }
            let known = force ? nil : revision
            let result = await Task.detached(priority: .userInitiated) { () -> Result<RemoteTranscriptMirror.Outcome, Error> in
                Result { try RemoteTranscriptMirror.shared.refresh(chatID: session.id, host: host, limit: limit, after: known, earlier: earlier) }
            }.value
            guard loadedID == session.id else { return }
            apply(result)
            return
        }
        let known = force ? nil : revision
        let result = await Task.detached(priority: .userInitiated) { () -> Result<ChatTranscriptRead, Error> in
            Result { try ChatTranscripts.read(session, host: host, profiles: profiles, limit: limit, after: known) }
        }.value
        guard loadedID == session.id else { return }
        apply(result.map { RemoteTranscriptMirror.Outcome(read: $0, syncedAt: nil, mirrored: false) })
    }

    private func apply(_ result: Result<RemoteTranscriptMirror.Outcome, Error>) {
        switch result {
        case .success(let outcome):
            switch outcome.read {
            case .unchanged: break
            case .loaded(let value, let newRevision):
                revision = newRevision
                if value != logged { logged = value }
            }
            if error != nil { error = nil }
            if offline != outcome.offline { offline = outcome.offline }
            if syncedAt != outcome.syncedAt { syncedAt = outcome.syncedAt }
            if canShowEarlier != outcome.canShowEarlier { canShowEarlier = outcome.canShowEarlier }
        case .failure(let failure):
            if logged == nil {
                let message = (failure as? LocalizedError)?.errorDescription ?? "Couldn't read this chat."
                if error != message { error = message }
            }
        }
        publish()
    }

    /// Shows a reply you just sent at once, dimmed as "Sending…", until the chat's log has it.
    /// The composer calls this after a successful send; the next reloads replace it with the logged
    /// message (never both), and it disappears on its own if the log never shows it.
    @discardableResult func echo(_ text: String) -> UUID {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let echo = ChatEchoes.make(trimmed, sent: Date(), logged: logged?.messages ?? [])
        if !trimmed.isEmpty { echoes.append(echo) }
        publish()
        return echo.id
    }

    /// Removes a reply shown by `echo` (its send failed).
    func withdrawEcho(_ id: UUID) {
        echoes.removeAll { $0.id == id }
        publish()
    }

    private func publish() {
        echoes = ChatEchoes.pending(echoes, logged: logged?.messages ?? [], now: Date())
        let shown = logged.map { ChatEchoes.merged($0, echoes: echoes) }
        if shown != transcript { transcript = shown }
    }
}

/// Restarts the Chats page's reload loop when the chat goes on or off screen, starts or stops
/// working, or its machine comes back or goes away.
struct TranscriptFollowKey: Hashable {
    var onScreen: Bool
    var live: Bool
    var reachable: Bool = true
}

private struct ChatWaitingKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// The chat on screen is waiting on you (a question or an approval).
    var chatWaiting: Bool {
        get { self[ChatWaitingKey.self] }
        set { self[ChatWaitingKey.self] = newValue }
    }
}

/// Where the bottom of the conversation is, in the scroll view's own space.
private struct TranscriptBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ChatTranscriptView: View {
    var transcript: ChatTranscript
    var provider: AgentProvider
    /// The chat is working now: its last turn shows live.
    var working = false
    /// Set for a remote chat whose copy can fetch earlier history: "Show earlier messages" calls it.
    var showEarlier: (() -> Void)? = nil
    var loadingEarlier = false
    @Environment(\.chatWaiting) private var waiting
    /// The bottom of the conversation is in view: new messages scroll into view as they come.
    @State private var atBottom = true
    /// The last message seen while at the bottom; what came after it is "new".
    @State private var seen: ChatFollow.Mark?
    @State private var viewport: CGFloat = 0

    var body: some View {
        let turns = ConversationTurn.turns(transcript.messages)
        // A long opening brief reads as the chat's task, as the Claude app shows a session it started.
        let task = !transcript.truncated && (turns.first?.question.map(TaskCard.isBrief) ?? false)
        // A plan set in an earlier turn and not yet finished stays in view on the latest one.
        let latestPlan = transcript.messages.last { $0.plan?.isEmpty == false }
        let carried = latestPlan.flatMap { plan -> ChatMessage? in
            guard let last = turns.last, !last.steps.contains(where: { $0.plan != nil }),
                  plan.plan?.contains(where: { $0.status != .completed }) == true else { return nil }
            return plan
        }
        let fresh = atBottom ? 0 : ChatFollow.newCount(transcript.messages, after: seen)
        let question = waiting ? turns.last(where: { $0.answer != nil })?.id : nil
        let liveTurn = working ? turns.last.flatMap { $0.answer == nil ? $0 : nil } : nil
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if let showEarlier {
                        Button(action: showEarlier) {
                            HStack(spacing: 6) {
                                if loadingEarlier { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.up") }
                                Text("Show earlier messages")
                            }
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                        }
                        .buttonStyle(.plain).disabled(loadingEarlier).frame(maxWidth: .infinity)
                    } else if transcript.truncated {
                        Label("Showing the latest \(transcript.messages.filter { !$0.sending }.count) messages", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).frame(maxWidth: .infinity)
                    }
                    ForEach(turns) { turn in
                        let first = turn.id == turns.first?.id
                        ChatTurnView(turn: turn, live: working && turn.id == turns.last?.id,
                                     task: first && task ? transcript.title : nil,
                                     carriedPlan: turn.id == turns.last?.id ? carried : nil)
                            .id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: TranscriptBottomKey.self, value: geometry.frame(in: .named("transcript")).maxY)
                        })
                        .onDisappear { setAtBottom(false) }
                }
                .padding(.horizontal, 36).padding(.vertical, 22)
                // Room for the live strip and the floating controls over the end.
                .padding(.bottom, liveTurn != nil || question != nil ? 40 : 0)
                .frame(maxWidth: 840).frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "transcript")
            .background(GeometryReader { geometry in
                Color.clear.onAppear { viewport = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, height in viewport = height }
            })
            .onPreferenceChange(TranscriptBottomKey.self) { bottom in
                // Within a short reach of the end counts as at the bottom.
                setAtBottom(viewport > 0 && bottom <= viewport + 48)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        if let question {
                            FollowPill(title: "Jump to last question", symbol: "arrow.up") {
                                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(question, anchor: .bottom) }
                            }
                            .keyboardShortcut(.upArrow, modifiers: .command)
                        }
                        if fresh > 0 {
                            FollowPill(title: fresh == 1 ? "1 new" : "\(fresh) new", symbol: "arrow.down") {
                                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                            }
                        }
                    }
                    if let liveTurn { LiveActivity(steps: liveTurn.steps) }
                }
                .padding(.bottom, 10)
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
                seen = ChatFollow.mark(transcript.messages)
            }
            .onChange(of: transcript) { _, value in
                // Follow only while at the bottom; scrolled up, keep the place and count what's new.
                if atBottom {
                    proxy.scrollTo("bottom", anchor: .bottom)
                    seen = ChatFollow.mark(value.messages)
                }
            }
            .onChange(of: liveTurn != nil) { _, _ in if atBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }

    private func setAtBottom(_ value: Bool) {
        guard value != atBottom else { return }
        atBottom = value
        if value { seen = ChatFollow.mark(transcript.messages) }
    }
}

/// A small floating control over the bottom of the conversation.
private struct FollowPill: View {
    var title: String
    var symbol: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.text)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(AppAppearance.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(AppAppearance.separator))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// One exchange, laid out like the Codex and Claude apps: your message (or the chat's task), a
/// "Worked for…" line over its steps, then the reply.
private struct ChatTurnView: View {
    var turn: ConversationTurn
    var live: Bool
    /// Show the question as the chat's task card, under this title.
    var task: String?
    /// An unfinished plan from an earlier turn, shown at the top of this one.
    var carriedPlan: ChatMessage?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let question = turn.question {
                if let task {
                    TaskCard(title: task, text: question.text)
                } else {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack {
                            Spacer(minLength: 100)
                            CollapsibleText(text: question.text, lines: 14, size: 14)
                                .padding(.horizontal, 15).padding(.vertical, 10)
                                .background(AppAppearance.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .opacity(question.sending ? 0.55 : 1)
                        if question.sending {
                            Text("Sending…").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).padding(.trailing, 6)
                        }
                    }
                }
            }
            if !turn.steps.isEmpty || (live && turn.answer == nil) {
                WorkedSection(steps: turn.steps, start: turn.question?.at ?? turn.steps.first?.at,
                              end: turn.answer?.at ?? turn.steps.last(where: { $0.at != nil })?.at, live: live && turn.answer == nil,
                              carriedPlan: carriedPlan)
            } else if let carriedPlan {
                PlanCard(items: carriedPlan.plan ?? [], live: false)
            }
            if let answer = turn.answer {
                MarkdownBlock(text: answer.text, size: 14.5)
            }
        }
    }
}

/// The brief a chat started from: its title over the first lines, with Show more.
private struct TaskCard: View {
    var title: String?
    var text: String
    static func isBrief(_ message: ChatMessage) -> Bool {
        message.text.count > 280 || message.text.split(separator: "\n", omittingEmptySubsequences: false).count > 5
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Task").font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary)
                Text(title ?? "Brief").font(.system(size: 14, weight: .semibold)).lineLimit(2)
            }
            CollapsibleText(text: text, lines: 4, size: 13.5)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppAppearance.separator))
    }
}

/// Text cut to a few lines with Show more / Show less when it runs longer.
private struct CollapsibleText: View {
    var text: String
    var lines: Int
    var size: CGFloat
    @State private var expanded = false
    var body: some View {
        let long = text.count > lines * 90 || text.split(separator: "\n", omittingEmptySubsequences: false).count > lines
        VStack(alignment: .leading, spacing: 6) {
            Text(MarkdownBlock.inline(text)).font(.system(size: size)).lineSpacing(3).textSelection(.enabled)
                .lineLimit(long && !expanded ? lines : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
            if long {
                Button(expanded ? "Show less" : "Show more") { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct WorkedSection: View {
    var steps: [ChatMessage]
    var start: Date?
    var end: Date?
    var live: Bool
    var carriedPlan: ChatMessage?
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.18)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    if live { ProgressView().controlSize(.mini) }
                    if live, let start {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Working for \(Self.duration(context.date.timeIntervalSince(start)))")
                        }
                    } else {
                        Text(label)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 13, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rectangle().fill(AppAppearance.separator).frame(height: 1).padding(.top, 10)
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let carriedPlan { PlanCard(items: carriedPlan.plan ?? [], live: live) }
                    ForEach(StepItem.items(steps)) { item in
                        switch item {
                        case .note(let step): MarkdownBlock(text: step.text, size: 13.5).padding(.vertical, 2)
                        case .run(let run): ToolRun(steps: run)
                        case .single(let step): ChatStepRow(step: step)
                        case .plan(let step): PlanCard(items: step.plan ?? [], live: live)
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
    }
    /// Open while the chat works, the way the Claude app shows a live session; folded once it has answered.
    private var expanded: Bool { open || live }
    private var label: String {
        if let start, let end, end > start { return "Worked for \(Self.duration(end.timeIntervalSince(start)))" }
        let tools = steps.filter { $0.kind == .tool }.count
        return tools == 1 ? "1 step" : "\(tools) steps"
    }
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }
}

/// A turn's steps as shown: notes the agent wrote, runs of routine tool calls folded into one
/// line ("Ran 5 commands, read 2 files"), delegated agents on their own, and the turn's plan as one
/// card (its latest state, where the plan first appeared).
enum StepItem: Identifiable {
    case note(ChatMessage), run([ChatMessage]), single(ChatMessage), plan(ChatMessage)
    var id: Int {
        switch self {
        case .note(let m), .single(let m), .plan(let m): m.id
        case .run(let steps): steps.first?.id ?? 0
        }
    }

    static func items(_ steps: [ChatMessage]) -> [StepItem] {
        var items: [StepItem] = [], run: [ChatMessage] = [], planShown = false
        let latestPlan = steps.last { $0.plan?.isEmpty == false }
        func flush() {
            if run.count == 1 { items.append(.single(run[0])) } else if !run.isEmpty { items.append(.run(run)) }
            run = []
        }
        for step in steps {
            guard step.kind == .tool else { flush(); items.append(.note(step)); continue }
            let kind = StepKind(step)
            if kind == .plan {
                if !planShown, let latestPlan { flush(); items.append(.plan(latestPlan)); planShown = true }
                continue
            }
            if kind == .delegated { flush(); items.append(.single(step)); continue }
            run.append(step)
        }
        flush()
        return items
    }

    /// "Ran 5 commands, read 2 files": a run in words, kinds in the order they first came.
    static func summary(_ steps: [ChatMessage]) -> String {
        var order: [String] = [], counts: [String: Int] = [:]
        for step in steps {
            let key = StepKind(step).group
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        let parts = order.map { key -> String in
            let n = counts[key] ?? 0
            switch key {
            case "ran": return n == 1 ? "ran a command" : "ran \(n) commands"
            case "read": return n == 1 ? "read a file" : "read \(n) files"
            case "edited": return n == 1 ? "edited a file" : "edited \(n) files"
            case "searched": return n == 1 ? "searched once" : "searched \(n) times"
            case "browsed": return n == 1 ? "browsed a page" : "browsed \(n) pages"
            case "waited": return "waited"
            default: return n == 1 ? "used a tool" : "used \(n) tools"
            }
        }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// What a tool call did, for its row and for grouping.
enum StepKind: Equatable {
    case ran, waited, sentInput, edited, read, searched, browsed, delegated, plan, other(String)
    init(_ step: ChatMessage) {
        let name = (step.tool ?? "").lowercased()
        if step.text.hasPrefix("// @exec") || name == "wait" { self = .waited; return }
        if step.text.contains("write_stdin") { self = .sentInput; return }
        switch name {
        case "exec", "bash", "shell", "exec_command", "local_shell": self = .ran
        case "edit", "write", "multiedit", "apply_patch", "notebookedit": self = .edited
        case "read", "view_image": self = .read
        case "grep", "glob", "toolsearch": self = .searched
        case "webfetch", "websearch", "web_search": self = .browsed
        case "agent", "task", "spawn_agent": self = .delegated
        case "todowrite", "update_plan": self = .plan
        default: self = .other(step.tool ?? "Tool")
        }
    }
    var verb: String {
        switch self {
        case .ran: "Ran"
        case .waited: "Waited"
        case .sentInput: "Sent input"
        case .edited: "Edited"
        case .read: "Read"
        case .searched: "Searched"
        case .browsed: "Browsed"
        case .delegated: "Delegated"
        case .plan: "Updated the plan"
        case .other(let name): name
        }
    }
    var group: String {
        switch self {
        case .ran, .sentInput: "ran"
        case .waited: "waited"
        case .edited: "edited"
        case .read: "read"
        case .searched: "searched"
        case .browsed: "browsed"
        default: "other"
        }
    }
    var symbol: String {
        switch self {
        case .ran, .waited, .sentInput: "terminal"
        case .edited: "pencil"
        case .read: "doc.text"
        case .searched: "magnifyingglass"
        case .browsed: "globe"
        case .delegated: "person.2"
        case .plan: "checklist"
        case .other: "gearshape"
        }
    }
}

/// A folded run of tool calls: one line that opens into each call.
private struct ToolRun: View {
    var steps: [ChatMessage]
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Text(StepItem.summary(steps)).font(.system(size: 13, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(AppAppearance.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(steps) { ChatStepRow(step: $0) }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(AppAppearance.separator).frame(width: 1) }
            }
        }
    }
}

/// The turn's plan, as the Claude app shows it: done, doing (spinning while live) and to do.
private struct PlanCard: View {
    var items: [ChatPlanItem]
    var live: Bool
    var body: some View {
        let done = items.filter { $0.status == .completed }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Plan", systemImage: "checklist").font(.system(size: 12, weight: .semibold)).foregroundStyle(AppAppearance.secondary)
                Spacer()
                Text("\(done) of \(items.count) done").font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary).monospacedDigit()
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Group {
                        switch item.status {
                        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(AppAppearance.green.opacity(0.85))
                        case .inProgress:
                            if live { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "circle.lefthalf.filled").foregroundStyle(AppAppearance.secondary) }
                        case .pending: Image(systemName: "circle.dashed").foregroundStyle(AppAppearance.tertiary)
                        }
                    }
                    .font(.system(size: 13)).frame(width: 16)
                    Text(item.text).font(.system(size: 13.5))
                        .foregroundStyle(item.status == .completed ? AppAppearance.tertiary : AppAppearance.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppAppearance.separator))
    }
}

/// While a turn runs: a strip under the conversation saying what the agent is doing right now
/// and for how long ("Running swift test · 1m 12s").
struct LiveActivity: View {
    var steps: [ChatMessage]
    var body: some View {
        let current = steps.last { $0.kind == .tool }
        let running = current.map { $0.output == nil } ?? false
        let since = running ? current?.at : steps.last?.at
        HStack(spacing: 8) {
            PulsingDots()
            Text(running ? Self.describe(current!) : "Thinking").font(.system(size: 12.5)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
            if let since {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("· " + WorkedSection.duration(max(0, context.date.timeIntervalSince(since))))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                }
            }
        }
        .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 7)
        .background(AppAppearance.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(AppAppearance.separator))
        .frame(maxWidth: 560)
    }
    /// "Locating the build config", or "Running swift test" when the call gave no description.
    nonisolated static func describe(_ step: ChatMessage) -> String {
        if let note = step.note, !note.isEmpty { return note }
        let kind = StepKind(step)
        let doing: String = switch kind {
        case .ran: "Running"
        case .edited: "Editing"
        case .read: "Reading"
        case .searched: "Searching"
        case .browsed: "Browsing"
        case .delegated: "Waiting on a subagent"
        case .waited: "Waiting"
        default: "Using " + kind.verb.replacingOccurrences(of: "_", with: " ")
        }
        let detail = step.text == step.tool || step.text.hasPrefix("// @exec") || step.text.hasPrefix("mcp__") || kind.group == "other" ? "" : step.text
        return detail.isEmpty || kind == .delegated ? doing : doing + " " + (detail.hasPrefix("/") ? URL(fileURLWithPath: detail).lastPathComponent : detail)
    }
}

/// Three dots that breathe in turn.
private struct PulsingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3) { index in
                    Circle().fill(AppAppearance.amber)
                        .frame(width: 4.5, height: 4.5)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 4 - Double(index) * 0.9)))
                }
            }
        }
        .frame(width: 22)
    }
}

/// One tool call: what it did and on what (hover for its own description), click for its output.
private struct ChatStepRow: View {
    var step: ChatMessage
    @State private var expanded = false
    var body: some View {
        let kind = StepKind(step)
        VStack(alignment: .leading, spacing: 6) {
            Button { if step.output?.isEmpty == false { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } } label: {
                HStack(spacing: 8) {
                    Image(systemName: kind.symbol).font(.system(size: 11, weight: .medium)).frame(width: 16).foregroundStyle(AppAppearance.tertiary)
                    Text(kind.verb).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(AppAppearance.secondary)
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 12, design: kind == .delegated ? .default : .monospaced)).foregroundStyle(AppAppearance.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if step.output?.isEmpty == false {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(AppAppearance.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(step.note ?? "")
            if expanded, let output = step.output, !output.isEmpty {
                Text(output).font(.system(size: 11, design: .monospaced)).foregroundStyle(AppAppearance.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(AppAppearance.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.leading, 24)
            }
        }
    }
    private var detail: String {
        let name = (step.tool ?? "").lowercased()
        if StepKind(step) == .delegated { return step.note ?? step.text }
        if step.text.hasPrefix("// @exec") || step.text.contains("write_stdin") || step.text.hasPrefix("mcp__") { return "" }
        if ["read", "edit", "write", "multiedit"].contains(name), step.text.hasPrefix("/") { return URL(fileURLWithPath: step.text).lastPathComponent }
        return step.text == step.tool ? "" : step.text
    }
}

/// Markdown for chat replies: headings, bullet and numbered lists, paragraphs with inline
/// styling, fenced code blocks in monospace, and images or videos linked by absolute path.
/// Parsed per render from the message text.
struct MarkdownBlock: View {
    var text: String
    var size: CGFloat = 14
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    Text(code).font(.system(size: size - 2, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(AppAppearance.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                case .heading(let line, let level):
                    Text(Self.inline(line)).font(.system(size: level <= 1 ? size + 4 : size + 1, weight: .semibold))
                        .padding(.top, 4).frame(maxWidth: .infinity, alignment: .leading)
                case .item(let marker, let line, let depth):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).font(.system(size: size, weight: .medium)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                            .frame(width: 18, alignment: .trailing)
                        Text(Self.inline(line)).font(.system(size: size)).lineSpacing(3).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(depth) * 18)
                case .paragraph(let line):
                    Text(Self.inline(line)).font(.system(size: size)).lineSpacing(3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .media(let caption, let path):
                    ChatMediaView(caption: caption, path: path).padding(.vertical, 4)
                }
            }
        }
    }

    enum Block: Equatable { case code(String), heading(String, Int), item(String, String, Int), paragraph(String), media(String, String) }

    /// `![caption](/absolute/path.png)` links to an image or video file; other images stay as text.
    nonisolated static func media(in line: String) -> (rest: String, media: [(String, String)])? {
        var media: [(String, String)] = []
        var rest = line
        for match in line.matches(of: /!\[([^\]]*)\]\(<?(?:file:\/\/)?(\/[^)>]+?)>?\)/) {
            let path = String(match.2).removingPercentEncoding ?? String(match.2)
            guard ChatMedia.kind(of: path) != nil else { continue }
            media.append((String(match.1), path))
            rest = rest.replacingOccurrences(of: String(match.0), with: "")
        }
        return media.isEmpty ? nil : (rest.trimmingCharacters(in: .whitespaces), media)
    }

    nonisolated static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        for (index, part) in text.components(separatedBy: "```").enumerated() {
            if index % 2 == 1 {
                // Drop the language tag on the fence's first line.
                let lines = part.split(separator: "\n", omittingEmptySubsequences: false)
                let body = lines.count > 1 && !lines[0].contains(" ") ? lines.dropFirst().joined(separator: "\n") : part
                blocks.append(.code(body.trimmingCharacters(in: .newlines)))
                continue
            }
            var paragraph: [String] = []
            func flush() {
                let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { blocks.append(.paragraph(joined)) }
                paragraph = []
            }
            for raw in part.components(separatedBy: "\n") {
                let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { flush(); continue }
                if let found = media(in: line) {
                    flush()
                    if !found.rest.isEmpty { blocks.append(.paragraph(found.rest)) }
                    blocks += found.media.map { Block.media($0.0, $0.1) }
                    continue
                }
                if let match = line.wholeMatch(of: /(#{1,6})\s+(.+)/) {
                    flush(); blocks.append(.heading(String(match.2), match.1.count)); continue
                }
                if let match = line.wholeMatch(of: /[-*•]\s+(.+)/) {
                    flush(); blocks.append(.item("•", String(match.1), indent / 2)); continue
                }
                if let match = line.wholeMatch(of: /(\d{1,3})[.)]\s+(.+)/) {
                    flush(); blocks.append(.item(match.1 + ".", String(match.2), indent / 2)); continue
                }
                paragraph.append(line)
            }
            flush()
        }
        return blocks
    }

    nonisolated static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
