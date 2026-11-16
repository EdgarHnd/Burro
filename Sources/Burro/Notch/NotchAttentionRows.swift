// The expanded notch's Agents rows. A chat that needs you is a card: its title (click opens it,
// the way any notch row does), machine · folder, how long it has waited, the Brief's question
// when triage wrote one, and either a one-line quick reply with Send or the single hand-off that
// works for it (Open in Codex / Open in Claude / Attach in Terminal / Attach on <Machine>, else
// Open in Burro). The quick reply decides and sends exactly as the Chats composer does: the same
// `ChatReply.composerPlan` (with the same Claude open-session check, run off the main thread and
// cached for a minute per chat and state) and the same `ChatReply.send`, stopping an idle Claude
// background session first only when the plan says so; Send is never pressed for you. When the
// Brief has a drafted reply for the chat it is prefilled, and sending it records that draft as
// sent (as the Brief's own Send does); an untouched draft follows the Brief (replaced or cleared
// when the draft changes or goes) and is sent only by clicking Send: Return sends only text you
// typed or changed (NotchReplyField). Text that came from a draft goes only while that draft is
// the current one and the store could mark it as going out: a draft sent or changed elsewhere is
// refused ("That draft was sent or changed elsewhere. Nothing was sent.") and the same text can't
// be sent again until it is changed; a send Burro couldn't confirm empties the field. A sub-agent
// never gets a reply field, only Open. The card
// is rebuilt whenever the chat it answers changes, and Send re-checks that the card still
// answers the chat it shows before anything goes. No field takes focus by itself: you click
// into it. A working chat is one compact line: state, machine · folder and, when Burro saw the
// turn start, how long it has run.
// While a reply field has focus (and the panel is key) or holds text you typed or edited, the
// card asks the notch to stay open; an untouched prefilled draft doesn't hold it open.
import AppKit
import SwiftUI
import BurroCore

/// The Claude open-session checks behind the notch's quick replies and Home's working-card Stop,
/// shared across cards and kept for a minute per chat and state, so hovering the notch or showing
/// Home doesn't run `claude agents` (or SSH) each time.
@MainActor @Observable final class NotchReplyChecks {
    static let shared = NotchReplyChecks()
    private struct Entry { var key: String; var check: ChatReply.ClaudeCheck; var at: Date }
    private var entries: [String: Entry] = [:]
    @ObservationIgnored private var running: Set<String> = []
    private static let freshFor: TimeInterval = 60

    private static func key(_ session: AgentSession) -> String { "\(session.id)|\(session.state.rawValue)" }
    func check(for session: AgentSession) -> ChatReply.ClaudeCheck? {
        guard let entry = entries[session.id], entry.key == Self.key(session) else { return nil }
        return entry.check
    }
    func refresh(_ session: AgentSession, host: RemoteHost?) async {
        guard session.provider == .claude else { return }
        let key = Self.key(session)
        if let entry = entries[session.id], entry.key == key, Date().timeIntervalSince(entry.at) < Self.freshFor { return }
        guard running.insert(session.id).inserted else { return }
        defer { running.remove(session.id) }
        let check = await Task.detached(priority: .utility) { ChatReply.claudeCheck(session, host: host) }.value
        entries[session.id] = Entry(key: key, check: check, at: Date())
    }
    func invalidate(_ id: String) { entries[id] = nil }
}

/// Invented values for snapshot tests only (drafts, Brief questions, Claude checks and turn
/// durations by chat id), so a rendering never touches the owner's Brief or runs a check.
struct NotchFixture {
    var drafts: [String: OrchestratorAction] = [:]
    var questions: [String: String] = [:]
    var checks: [String: ChatReply.ClaudeCheck] = [:]
    var turns: [String: TimeInterval] = [:]
}

struct NotchSectionHeader: View {
    var title: String
    var count: Int
    var tint: Color
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text("\(title) · \(count)".uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.7)
                .foregroundStyle(tint == NotchStyle.attention ? NotchStyle.attention : AppAppearance.tertiary)
            Spacer(minLength: 0)
        }
        .frame(height: NotchListLayout.headerHeight)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A chat waiting on you: title, one status line and the action row.
struct NotchNeedsYouCard: View {
    var store: AppStore
    let session: AgentSession
    var place: String
    /// The Brief's question or headline for this chat, when triage wrote one.
    var question: String?
    /// The Brief's drafted reply for this chat, still waiting to be sent.
    var draft: OrchestratorAction?
    var host: RemoteHost?
    var available = true
    /// The panel is open: checks run and fields keep focus only then.
    var active: Bool
    var now: Date = Date()
    /// Fixed only for snapshots; otherwise the shared cached check.
    var checkOverride: ChatReply.ClaudeCheck? = nil
    var open: () -> Void
    /// Show in Burro (the card's context menu), whatever "Open chats in Burro" says.
    var inspect: () -> Void = {}
    /// The chat this card's group targets right now (read when Send is pressed).
    var currentTarget: () -> String? = { nil }
    /// (chat id, field focused, text typed or edited) for the notch's stay-open rule.
    var hold: (String, Bool, Bool) -> Void = { _, _, _ in }
    @State private var field = NotchReplyField()
    @State private var sending = false
    @State private var notice: String?
    @State private var error: String?
    @State private var hovering = false
    @FocusState private var focused: Bool
    private var checks: NotchReplyChecks { .shared }

    private var agent: String { session.provider == .codex ? "Codex" : "Claude" }
    private var check: ChatReply.ClaudeCheck? { checkOverride ?? checks.check(for: session) }
    private var plan: ComposerPlan {
        ChatReply.composerPlan(session, host: host, check: check, setupProblem: nil,
                               queued: ReplyQueueModel.shared.item(for: session.id) != nil, hasURL: session.chatURL != nil)
    }
    private var subagent: Bool { session.isSubagent == true }
    private var mode: NotchReplyMode {
        NotchReplyMode.decide(plan, provider: session.provider, checked: session.provider != .claude || check != nil, subagent: subagent)
    }
    private var trimmed: String { field.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Text the owner typed or changed (an untouched draft doesn't count).
    private var edited: Bool { field.edited }

    var body: some View {
        let mode = mode
        VStack(alignment: .leading, spacing: 6) {
            Button(action: open) {
                HStack(spacing: 8) {
                    Text(session.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppAppearance.text).lineLimit(1)
                    Text(place).font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(Self.age(now.timeIntervalSince(session.updatedAt))).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(AppAppearance.tertiary)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!available)
            .help(available ? "Open this chat\n\(session.title)" : "No longer present in the latest scan.")
            .contextMenu {
                Button("Show in Burro", action: inspect).disabled(!available)
                if let url = session.chatURL { Button("Open in \(agent)") { NSWorkspace.shared.open(url) }.disabled(!available) }
            }
            statusLine(mode).frame(height: 16, alignment: .leading)
            actionRow(mode).frame(height: 28)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(height: NotchListLayout.cardHeight, alignment: .top)
        .background(AppAppearance.background.opacity(hovering ? 1 : 0.85), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NotchStyle.attention.opacity(0.32)))
        .onHover { hovering = $0 }
        .opacity(available ? 1 : 0.55)
        .task(id: "\(session.id)|\(session.state.rawValue)|\(active)") {
            guard active, checkOverride == nil else { return }
            await checks.refresh(session, host: host)
        }
        .onAppear { prefill() }
        .onChange(of: draft?.id) { _, _ in prefill() }
        .onChange(of: active) { _, active in if !active { focused = false } }
        .onChange(of: focused) { _, _ in report() }
        .onChange(of: edited) { _, _ in report() }
        .onDisappear { hold(session.id, false, false) }
    }

    @ViewBuilder private func statusLine(_ mode: NotchReplyMode) -> some View {
        if let notice {
            Label(notice, systemImage: "checkmark.circle.fill").font(.system(size: 11.5)).foregroundStyle(AppAppearance.green).lineLimit(1)
        } else if let error {
            Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(NotchStyle.attention).lineLimit(1).help(error)
        } else {
            Text(NotchReplyMode.status(question: question, mode: mode)).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                .lineLimit(1).truncationMode(.tail).help(question ?? "")
        }
    }

    @ViewBuilder private func actionRow(_ mode: NotchReplyMode) -> some View {
        switch mode {
        case .reply, .checking:
            HStack(spacing: 6) {
                TextField(draft == nil ? "Reply to \(agent)…" : "Edit the drafted reply…",
                          text: Binding(get: { field.text }, set: { field.type($0) }))
                    .textFieldStyle(.plain).font(.system(size: 12)).focused($focused)
                    // Return sends only what the owner typed or changed; a draft goes by Send.
                    .onSubmit { if field.returnSends { send() } }
                    .disabled(sending || !available)
                    .padding(.horizontal, 9).frame(height: 28)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? AppAppearance.hairline : AppAppearance.separator))
                    .accessibilityLabel("Reply to \(session.title)")
                NotchAmberButton(title: "Send", busy: sending || mode == .checking,
                                 enabled: field.sendable && !sending && mode != .checking && available, action: send)
                    .help(mode == .checking ? "Checking whether this chat can take a reply…" : ChatReply.sendHelp(plan))
            }
        case .handOff(let action):
            HStack(spacing: 8) {
                if let title = NotchReplyMode.handOffTitle(action, provider: session.provider, machine: session.remote?.hostName), let action {
                    NotchAmberButton(title: title, enabled: available) { perform(action) }.help(plan.reason ?? title)
                } else {
                    NotchAmberButton(title: "Open", enabled: available, action: open).help(plan.reason ?? "Open this chat")
                }
                if let reason = NotchReplyMode.handOffReason(plan, subagent: subagent) {
                    Text(reason).font(.system(size: 10.5)).foregroundStyle(AppAppearance.tertiary).lineLimit(2).help(reason)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func prefill() { field.follow(draftID: draft?.id, text: draft?.text) }

    private func report() { hold(session.id, focused && active, edited) }

    /// Sends through the composer's own path: the same plan, the same checks, the same call.
    private func send() {
        let plan = plan
        guard case .reply = NotchReplyMode.decide(plan, provider: session.provider, checked: session.provider != .claude || check != nil,
                                                  subagent: subagent),
              plan.canSend, !sending, available else { return }
        // The chat this card was built for must still be the one its group targets now.
        let target = session
        guard currentTarget() == target.id else {
            error = "This card now answers a different chat. Nothing was sent."; return
        }
        let message = trimmed
        guard !message.isEmpty else { return }
        let stops = plan.sendStopsFirst
        // Text from a draft goes only as that draft, while it is still the current one, and only
        // once the store has marked it as going out; otherwise nothing is sent.
        let decision = field.sendDecision(currentDraftID: draft?.id)
        var draftID: String?
        var began = false
        if case .draft(let id) = decision { began = store.orchestrator.beginSending(id); if began { draftID = id } }
        if let refusal = NotchReplyField.gate(decision, began: began,
                                               alreadySending: draftID == nil && draft.map { store.orchestrator.sendingActions.contains($0.id) } == true) {
            if decision == .stale { field.dropStaleDraft() }
            error = refusal; notice = nil
            return
        }
        sending = true; error = nil; notice = nil
        let session = target, host = host, store = store
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                Result { try ChatReply.send(ReplyRequest(text: message), to: session, host: host, stopIdleBackground: stops) }
            }.value
            if let draftID { store.orchestrator.finishSending(draftID, text: message, outcome: result.map { (message: $0, chatID: nil) }) }
            sending = false
            switch result {
            case .success(let confirmation):
                notice = confirmation; field.clearAfterSend()
                NotchReplyChecks.shared.invalidate(session.id)
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if session.remote == nil { await store.refreshAgents() } else { await store.refreshRemotes() }
                }
            case .failure(let failure):
                error = (failure as? LocalizedError)?.errorDescription ?? "Couldn't send."
                // It may have gone: the text isn't left ready for a one-click resend.
                if SendOutcome.isUnconfirmed(failure) { field.clearAfterSend() }
            }
        }
    }

    private func perform(_ action: ComposerPlan.Action) {
        switch action {
        case .openInProvider: if let url = session.chatURL { NSWorkspace.shared.open(url) }
        case .attachInTerminal(let handle):
            store.open(LaunchResult(provider: .claude, sessionID: session.id, handle: handle, folder: session.cwd))
        case .attachOnMachine(let handle):
            guard let host else { return }
            error = RemoteAttachOpener.open(host: host, handle: handle)
        case .queue: break
        }
    }

    static func age(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes < 48 * 60 ? "\(minutes / 60) h" : "\(minutes / 1440) d"
    }
}

/// The notch's one amber action per card.
struct NotchAmberButton: View {
    var title: String
    var busy = false
    var enabled = true
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if busy { ProgressView().controlSize(.mini).tint(.black) }
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(Color.black.opacity(enabled ? 0.88 : 0.6))
            .padding(.horizontal, 12).frame(height: 28)
            .background(NotchStyle.attention.opacity(enabled ? 1 : 0.45), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
    }
}

/// A working (or scheduled, or uncertain) chat as one line: dot, title, state (left out while
/// simply running: the green dot says it) · machine · folder,
/// and how long its turn has run when Burro saw it start.
struct NotchWorkingLine: View {
    let session: AgentSession
    var place: String
    var available = true
    /// "Worker running" / "Worker needs you" when a worker, not the chat itself, is busy.
    var workerState: AgentState? = nil
    var turn: TimeInterval?
    var workers: Int = 0
    var workersExpanded = false
    var toggleWorkers: (() -> Void)? = nil
    var select: () -> Void
    var inspect: () -> Void
    @State private var hovering = false
    @AppStorage(AppStore.openChatsInBurroKey) private var openInBurro = true
    private var agent: String { session.provider == .codex ? "Codex" : "Claude" }
    private var opensInBurro: Bool { session.chatURL == nil || openInBurro }

    private var state: (label: String, color: Color) {
        if !available { return ("Unavailable", .secondary) }
        if workerState == .waiting { return ("Worker needs you", NotchStyle.attention) }
        if session.remote?.stale == true { return ("Last seen", .secondary) }
        switch session.state {
        case .working: return ("Running", AgentState.working.color)
        case .waiting: return ("Needs you", NotchStyle.attention)
        case .scheduled: return ("Scheduled", AgentState.scheduled.color)
        case .unknown, .recent: return (workerState == .working ? "Worker running" : "Recently active", workerState == .working ? AgentState.working.color : .secondary)
        default: return (workerState == .working ? "Worker running" : (session.isDone ? "Done" : "Idle"),
                         workerState == .working ? AgentState.working.color : (session.isDone ? AppAppearance.blue : .secondary))
        }
    }

    var body: some View {
        let state = state
        HStack(spacing: 6) {
            Button(action: select) {
                HStack(spacing: 9) {
                    Circle().fill(state.color).frame(width: 6, height: 6)
                    Text(session.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppAppearance.text)
                        .lineLimit(1).frame(maxWidth: 190, alignment: .leading).layoutPriority(1)
                    // A running chat's green dot says "Running"; other states are spelled out.
                    Text(state.label == "Running" ? place : "\(state.label) · \(place)").font(.system(size: 11.5))
                        .foregroundStyle(AppAppearance.secondary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 6)
                    if let turn {
                        Text(TurnClock.text(turn)).font(.system(size: 11)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                            .help("This turn has run for \(TurnClock.text(turn))")
                    }
                }
                .padding(.horizontal, 6).frame(height: NotchListLayout.lineHeight)
                .background(hovering ? AppAppearance.hover : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover { hovering = $0 }.disabled(!available)
            .help(available ? (opensInBurro ? "Open in Burro" : "Open chat in \(agent)") + "\n" + session.title
                  : "No longer present in the latest scan. Update the list to remove this row.")
            .accessibilityHint(opensInBurro ? "Opens this chat in Burro" : "Opens this chat in \(agent)")
            .contextMenu {
                Button("Show in Burro", action: inspect).disabled(!available)
                if let url = session.chatURL { Button("Open in \(agent)") { NSWorkspace.shared.open(url) }.disabled(!available) }
            }
            if workers > 0, let toggleWorkers {
                Button(action: toggleWorkers) {
                    HStack(spacing: 3) {
                        Text("\(workers)").monospacedDigit()
                        Image(systemName: workersExpanded ? "chevron.down" : "chevron.right")
                    }.font(.system(size: 10, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                        .frame(height: NotchListLayout.lineHeight).padding(.horizontal, 4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(workers) background workers")
                .accessibilityLabel("\(workersExpanded ? "Hide" : "Show") workers for \(session.title)")
            }
        }
    }
}

/// A machine's workers without a known parent chat, folded into one line.
struct NotchWorkersLine: View {
    var count: Int
    var machine: String
    var needsYou: Bool
    var running: Bool
    var expanded: Bool
    var toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 9) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 10)).frame(width: 6)
                Text("Background workers").font(.system(size: 12, weight: .semibold)).foregroundStyle(AppAppearance.text)
                Text("\(count) \(count == 1 ? "worker" : "workers") · \(machine)").font(.system(size: 11.5)).foregroundStyle(AppAppearance.secondary)
                Spacer(minLength: 6)
                if needsYou { Text("Needs input").font(.system(size: 10.5, weight: .medium)).foregroundStyle(NotchStyle.attention) }
                else if running { Text("Running").font(.system(size: 10.5, weight: .medium)).foregroundStyle(AgentState.working.color) }
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppAppearance.secondary)
            }
            .padding(.horizontal, 6).frame(height: NotchListLayout.lineHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(expanded ? "Hide" : "Show") \(count) background workers on \(machine)")
    }
}
