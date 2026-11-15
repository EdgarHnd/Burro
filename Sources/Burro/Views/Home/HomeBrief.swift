// Home's Orchestrator card, now the Brief: what triage has to say about your chats, kept current
// between questions. Sections, each hidden when empty: Needs you (the chat's title, the question in
// one line and, when that chat has a draft — triage's, or a reply the Orchestrator proposed — the
// reply inline with Send / Edit / Discard; Send uses the proposal card's own send path (an idle
// Claude background session is stopped and continued with the reply, as its help says), Edit opens
// that card in place; clicking the row opens the chat), Finished (one-line outcome), Stuck
// (working with no sign of life; see StuckWatch), and one Shipped line from the cached Shipped
// summary. The attention strip above lists every chat waiting on you with its Open button; this
// card adds only what triage found (the question and a draft), with no avatar or Open button of
// its own, and also catches chats that ended a turn on a question, which the strip doesn't show.
// A quiet footer shows today's triage runs and toggles automatic triage, or says why it is paused.
// The composer stays, collapsed under the brief; an earlier answer is only ever a link with its
// age, never shown as if current. Monochrome; amber only for Needs you.
import SwiftUI
import BurroCore

struct HomeBrief: View {
    @Bindable var store: AppStore
    @State private var composing = false
    @State private var editing: String?

    var body: some View {
        let brief = store.brief
        let orchestrator = store.orchestrator
        let needs = brief.needsYou, finished = brief.finished, stuck = brief.stuck
        let shipped = shippedLine
        VStack(alignment: .leading, spacing: 16) {
            header(brief: brief, orchestrator: orchestrator)
            if needs.isEmpty && finished.isEmpty && stuck.isEmpty && shipped == nil {
                Text(brief.autoTriage ? "Nothing new from your chats." : "Automatic triage is off. Turn it on below to keep this current.")
                    .font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary)
            }
            if !needs.isEmpty {
                section("Needs you", tint: AppAppearance.amber) {
                    ForEach(needs) { item in needsRow(item) }
                }
            }
            if !finished.isEmpty {
                section("Finished") { ForEach(finished.prefix(6)) { item in quietRow(item, symbol: "checkmark") } }
            }
            if !stuck.isEmpty {
                section("Stuck") { ForEach(stuck) { item in quietRow(item, symbol: "clock") } }
            }
            if let shipped {
                Button { store.today.show(Date()); store.page = .today } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).frame(width: 14)
                        Text("Shipped").font(.system(size: 12.5, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                        Text(shipped).font(.system(size: 12.5)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help("Open today's Shipped section")
            }
            otherProposals(brief: brief, orchestrator: orchestrator)
            ask(orchestrator)
            footer(brief)
        }
        .padding(20)
        .modifier(SoftSurface(radius: 22, shadowRadius: 14, y: 4))
        .task { await orchestrator.loadHistory() }
    }

    // MARK: Header and footer

    private func header(brief: OrchestratorBriefStore, orchestrator: OrchestratorStore) -> some View {
        HStack(spacing: 12) {
            OrchestratorAvatar(size: 34, working: orchestrator.running || brief.triaging > 0)
            VStack(alignment: .leading, spacing: 2) {
                Text("Brief").font(.system(size: 17, weight: .semibold))
                Text("What your chats need, kept current by the Orchestrator").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            PillButton(title: "Open", symbol: "arrow.up.left.and.arrow.down.right") { store.showOrchestrator() }
        }
    }

    private func footer(_ brief: OrchestratorBriefStore) -> some View {
        HStack(spacing: 10) {
            Button { brief.autoTriage.toggle() } label: {
                Text(brief.footer).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
            }
            .buttonStyle(.plain)
            .help(brief.autoTriage ? "Turn automatic triage off" : "Turn automatic triage on (\(OrchestratorTriage.modelTitle), at most \(brief.dailyCap) runs a day)")
            if brief.triaging > 0 {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Reading \(brief.triaging) chat\(brief.triaging == 1 ? "" : "s")…")
                }.font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary)
            } else if let problem = brief.problem, brief.autoTriage {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Sections

    private func section<Content: View>(_ title: String, tint: Color = AppAppearance.tertiary, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.8).foregroundStyle(tint)
            content()
        }
    }

    private func needsRow(_ item: BriefItem) -> some View {
        let actions = store.orchestrator.actions
        // Triage's own draft (also once sent), else a reply the Orchestrator proposed for this chat.
        let action = item.proposalID.flatMap { id in actions.first { $0.id == id } }
            ?? item.chatID.flatMap { store.brief.draft(chatID: $0, actions: actions) }
        return VStack(alignment: .leading, spacing: 8) {
            Button { open(item) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Circle().fill(AppAppearance.amber).frame(width: 6, height: 6)
                        Text(item.chatTitle ?? "A chat").font(.system(size: 13, weight: .semibold)).foregroundStyle(AppAppearance.text).lineLimit(1)
                        if let machine = item.machine, machine != "This Mac" {
                            Text(machine).font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text(age(item.updatedAt)).font(.system(size: 11)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                    }
                    Text(item.question ?? item.headline).font(.system(size: 12.5)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
                        .padding(.leading, 14).help(item.question.map { "\(item.headline)\n\($0)" } ?? item.headline)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Open this chat")
            if let action, action.status == .sent {
                Label(action.result ?? "Sent", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).padding(.leading, 14)
            } else if let action, action.isWaiting() {
                if editing == action.id {
                    OrchestratorActionCard(store: store, action: action)
                    Button("Done editing") { editing = nil }.buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppAppearance.secondary).padding(.leading, 14)
                } else {
                    draft(action)
                }
            } else {
                Text(item.detail ?? "Worth a look").font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary).padding(.leading, 14)
            }
        }
        .padding(10)
        .background(AppAppearance.raised.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu { Button("Dismiss") { store.brief.dismiss(item) } }
    }

    /// The drafted reply, inline, with Send / Edit / Discard.
    private func draft(_ action: OrchestratorAction) -> some View {
        let sending = store.orchestrator.sendingActions.contains(action.id)
        let blocked = blockedReason(action)
        return VStack(alignment: .leading, spacing: 6) {
            Text(action.text).font(.system(size: 12.5)).foregroundStyle(AppAppearance.text).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .help(action.text)
            if let error = action.error, !sending {
                Label(error, systemImage: "exclamationmark.bubble").font(.system(size: 11.5)).foregroundStyle(AppAppearance.amber).lineLimit(2)
            } else if let blocked {
                Text(blocked).font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary).lineLimit(2)
            }
            HStack(spacing: 12) {
                Text(action.conversation == BriefDrafts.triageConversation ? "Drafted reply · not sent" : "Proposed reply · not sent")
                    .font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
                Spacer(minLength: 6)
                Button("Discard") { store.orchestrator.discard(action) }.disabled(sending).help("Remove this draft without sending it")
                Button("Edit") { editing = action.id }.disabled(sending).help("Edit the reply before sending")
                Button {
                    let text = action.text
                    Task { await store.sendOrchestratorAction(action, text: text) }
                } label: {
                    HStack(spacing: 5) {
                        if sending { ProgressView().controlSize(.mini) }
                        Text(sending ? "Sending…" : "Send").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(OrchestratorStyle.onGold)
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(Capsule().fill(AppAppearance.amber))
                    .opacity(sending || blocked != nil ? 0.4 : 1)
                }
                .disabled(sending || blocked != nil)
                .help(ChatReply.cardSendHelp(provider: store.orchestratorTarget(action)?.session.provider))
            }
            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
        }
        .padding(.leading, 14)
    }

    private func quietRow(_ item: BriefItem, symbol: String) -> some View {
        Button { open(item) } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(AppAppearance.tertiary).frame(width: 14)
                Text(item.chatTitle ?? "A chat").font(.system(size: 12.5, weight: .medium)).foregroundStyle(AppAppearance.text).lineLimit(1)
                    .layoutPriority(1)
                Text(item.headline).font(.system(size: 12.5)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
                Spacer(minLength: 6)
                Text(age(item.updatedAt)).font(.system(size: 11)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
            }
            .padding(.vertical, 3).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Open this chat")
        .contextMenu { Button("Dismiss") { store.brief.dismiss(item) } }
    }

    /// Proposals the Orchestrator made in conversation (not drafts shown above).
    @ViewBuilder private func otherProposals(brief: OrchestratorBriefStore, orchestrator: OrchestratorStore) -> some View {
        let shown = brief.shownInline(orchestrator.actions)
        let count = orchestrator.waitingActions.filter { !shown.contains($0.id) }.count
        if count > 0 {
            Button { store.showOrchestrator() } label: {
                Label(count == 1 ? "1 proposed action waits for you" : "\(count) proposed actions wait for you", systemImage: "hand.raised")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.amber)
            }
            .buttonStyle(.plain).help("Review and send or discard them on the Orchestrator page")
        }
    }

    /// The composer, collapsed to one line until clicked. Never shows an earlier answer's text.
    @ViewBuilder private func ask(_ orchestrator: OrchestratorStore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if composing || orchestrator.running || !orchestrator.draft.isEmpty {
                OrchestratorComposer(orchestrator: orchestrator, placeholder: "Ask about your chats, machines and projects, or have it start work…")
            } else {
                Button { composing = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "text.bubble").font(.system(size: 11))
                        Text("Ask the Orchestrator…").font(.system(size: 12.5))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(AppAppearance.tertiary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(AppAppearance.raised.opacity(0.35), in: Capsule())
                    .contentShape(Capsule())
                }.buttonStyle(.plain)
            }
            if let activity = orchestrator.activity {
                Button { store.showOrchestrator() } label: {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text(activity).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                    }
                }.buttonStyle(.plain).help("Open the conversation")
            } else if let error = orchestrator.error {
                Label(error, systemImage: "exclamationmark.bubble").font(.system(size: 12)).foregroundStyle(AppAppearance.amber).lineLimit(2)
            } else if let answered = orchestrator.messages.last(where: { $0.kind == .assistant })?.at {
                let ago = age(answered)
                Button("Last answer \(ago == "now" ? "just now" : ago + " ago") · Open") { store.showOrchestrator() }
                    .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary)
                    .help("Open the conversation")
            }
            if let problem = orchestrator.setupProblem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(AppAppearance.amber)
            }
        }
    }

    // MARK: Helpers

    private var shippedLine: String? {
        store.shipped.daySummary(Date()).flatMap { ShippedBrief(json: $0)?.headline }.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func open(_ item: BriefItem) {
        guard let id = item.chatID else { return }
        if let session = store.notchChatSessions.first(where: { $0.id == id }) { store.showChat(session); return }
        store.search = ""; store.page = .remote; store.remoteSelection = id
    }

    private func blockedReason(_ action: OrchestratorAction) -> String? {
        guard let (session, host) = store.orchestratorTarget(action) else { return "Burro can't see this chat right now." }
        return ChatReply.unavailable(session, host: host)
    }

    private func age(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}
