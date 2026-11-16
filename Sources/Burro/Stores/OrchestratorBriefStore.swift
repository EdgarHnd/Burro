// Keeps the Brief current: watches every agent sample with its own ChatAlertTracker (so it works
// whether or not notifications are on), queues your chats that start waiting on you or finish a
// turn, and every 30–45 seconds sends at most five of them to triage in one small-model call
// (OrchestratorTriage.swift), one call at a time. Before a call it reads the end of each chat's
// transcript (this Mac, or over SSH like Chats does) and skips chats whose last messages were
// already triaged. Results become Brief items in `brief.json`; a drafted reply becomes a proposal
// you Send, Edit or Discard; nothing is ever sent from here. Chats working with no sign of life get
// a "stuck" item without any model call (StuckWatch: Codex by its thread time, Claude Code on this
// Mac by looking at its transcript once its status has been quiet for 45 minutes, a long single
// tool call or a Claude chat elsewhere only after three hours). A morning brief triages chats still waiting
// or unread from the last day, once per local day on the first activation after 05:00.
//
// Every run is gated (TriageScheduler.gate): automatic triage on (`orchestrator.autoTriage`,
// default on; turning it off stops a call in flight and drops its results), under the daily cap (`orchestrator.triageDailyCap`, at most 150) and 30 an hour, and
// Claude's session window at 15% or more and weekly at 10% or more when known. Each run is appended
// to the Orchestrator's runs log (`OrchestratorRuns`), the same file and lock as its own runs, so the
// footer's count and the Runs tab agree. When triage has a headline for a chat that needs you,
// `headlineReady` passes it on (the needs-you banner uses it). Inert until `start()`, so stores built in tests never read or write files.
// "Run triage now" on the Orchestrator page (`runNow`) reads the newest chats waiting on you or
// unread (up to 30, newest first, stopping once five need triage; chats on a machine that isn't
// configured or answering are skipped) and puts up to five whose latest messages haven't been triaged at the front of
// the queue, due at once, through the same gate (Off switch, caps, Claude's limits), checked again
// after the read; when every chat it looked at is already triaged it says "Nothing new to triage".
// A run uses the same skip rule (`TriageNow.needsTriage`). Nothing is logged.
import AppKit
import Foundation
import Observation
import BurroCore

@MainActor @Observable final class OrchestratorBriefStore {
    private(set) var file = BriefFile()
    /// Chats in the triage call running now (0 when none).
    private(set) var triaging = 0
    private(set) var runsToday = 0
    private(set) var gate: TriageGate = .open
    /// Why the last run produced nothing (Claude missing, signed out, unreadable answer).
    private(set) var problem: String?
    /// "Run triage now" is reading chats to find ones not triaged yet.
    private(set) var checkingNow = false

    var autoTriage: Bool {
        didSet {
            defaults.set(autoTriage, forKey: Self.autoTriageKey)
            if !autoTriage { scheduler.clear(); inFlight?.cancel() }
            refreshGate(now: Date())
        }
    }
    var dailyCap: Int {
        didSet { defaults.set(dailyCap, forKey: Self.dailyCapKey); refreshGate(now: Date()) }
    }
    var morningBrief: Bool { didSet { defaults.set(morningBrief, forKey: Self.morningKey) } }

    nonisolated static let autoTriageKey = "orchestrator.autoTriage"
    nonisolated static let dailyCapKey = "orchestrator.triageDailyCap"
    nonisolated static let morningKey = "orchestrator.morningBrief"
    nonisolated static let morningDayKey = "orchestrator.morningBriefDay"
    nonisolated static let caps = [25, 50, 100, 150]

    /// Wired by AppStore: machines, Claude profiles, Claude's limits, a chat's project, and a hook
    /// to reload the Orchestrator's proposals after a draft is added or discarded.
    @ObservationIgnored var hosts: () -> [RemoteHost] = { [] }
    @ObservationIgnored var profiles: () -> [UsageProvider: String] = { [:] }
    @ObservationIgnored var usage: () -> TriageUsage? = { nil }
    @ObservationIgnored var project: (AgentSession) -> (name: String, path: String?) = { (URL(fileURLWithPath: $0.cwd).lastPathComponent, nil) }
    @ObservationIgnored var proposalsChanged: () -> Void = {}
    /// A run was logged (the Runs tab reloads).
    @ObservationIgnored var runLogged: () -> Void = {}
    /// Triage's headline for a chat that needs you, as soon as it exists.
    @ObservationIgnored var headlineReady: (_ chatID: String, _ headline: String) -> Void = { _, _ in }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: BriefStore
    @ObservationIgnored private let actions: OrchestratorActionStore
    @ObservationIgnored private let runs: OrchestratorRuns
    @ObservationIgnored private let runner: TriageRunner
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var started = false
    @ObservationIgnored private var tracker = ChatAlertTracker()
    @ObservationIgnored private var scheduler = TriageScheduler()
    @ObservationIgnored private var stuckWatch = StuckWatch()
    @ObservationIgnored private var sessions: [String: AgentSession] = [:]
    @ObservationIgnored private var stops: [String: TriageInput.Stop] = [:]
    @ObservationIgnored private var runTimes: [Date] = []
    @ObservationIgnored private var morningPending = false
    @ObservationIgnored private var activation: NSObjectProtocol?
    /// Transcript looks for stuck detection in flight.
    @ObservationIgnored private var glancing: Set<String> = []
    /// Stops the triage call running now when automatic triage is turned off.
    @ObservationIgnored private var inFlight: ProcessCancel?

    init(defaults: UserDefaults = .standard, store: BriefStore = .standard, actions: OrchestratorActionStore = .standard,
         runs: OrchestratorRuns = .standard, runner: TriageRunner = .live, calendar: Calendar = .current) {
        self.defaults = defaults; self.store = store; self.actions = actions; self.runs = runs; self.runner = runner; self.calendar = calendar
        autoTriage = defaults.object(forKey: Self.autoTriageKey) as? Bool ?? true
        let cap = defaults.object(forKey: Self.dailyCapKey) as? Int ?? TriageBudget.maxDaily
        dailyCap = max(1, min(TriageBudget.maxDaily, cap))
        morningBrief = defaults.object(forKey: Self.morningKey) as? Bool ?? true
    }

    func start() {
        guard !started else { return }
        started = true
        file = store.load()
        runTimes = runs.triageRunTimes()
        morningPending = true
        refreshGate(now: Date())
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.morningPending = true }
        }
    }

    // MARK: Sections for Home

    var needsYou: [BriefItem] { BriefReducer.needsYou(file) }
    var finished: [BriefItem] { BriefReducer.finished(file) }
    var stuck: [BriefItem] { BriefReducer.stuck(file) }
    /// The draft a chat has waiting (triage's or one the Orchestrator proposed), if any.
    func draft(chatID: String, actions: [OrchestratorAction], now: Date = Date()) -> OrchestratorAction? {
        BriefDrafts.draft(chatID: chatID, file: file, actions: actions, now: now)
    }
    /// Proposals the Brief shows inline (so Home doesn't count them twice).
    func shownInline(_ actions: [OrchestratorAction], now: Date = Date()) -> Set<String> {
        BriefDrafts.shownInline(file: file, actions: actions, now: now)
    }

    /// "Triage: 9 today · On", or the reason it's paused.
    var footer: String {
        let count = "Triage: \(runsToday) today"
        if let reason = gate.reason { return gate == .off ? count + " · Off" : count + " · " + reason }
        return count + " · On"
    }

    // MARK: Samples

    /// Feeds the latest chats (every machine, the Orchestrator's own excluded). Cheap; called on
    /// every agent sample.
    func update(_ all: [AgentSession], now: Date = Date()) {
        guard started else { return }
        let counted = all.filter { ChatAlertSample.counts($0) && !Orchestrator.owns($0) }
        sessions = Dictionary(counted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let unavailable = Set(all.filter(ChatAlertSample.unavailable).map(\.id))
        let events = tracker.update(counted.map(ChatAlertSample.init), unavailable: unavailable, at: now)
        var states = counted.map(BriefChatState.init)
        let stuckNow = stuckWatch.update(states, now: now)
        states = states.map { state in var copy = state; copy.lastSignal = stuckWatch.lastSignal(state); return copy }
        glance(stuckWatch.dueChecks(states, now: now), now: now)
        if autoTriage {
            for case .post(let kind, let chat) in events {
                stops[chat] = kind == .needsYou ? .waiting : .finished
                scheduler.enqueue(chat, at: now)
            }
        }
        // Resolve items whose chat moved on; add stuck items (no model call).
        var next = file
        _ = BriefReducer.reconcile(&next, chats: states, now: now)
        if autoTriage {
            for entry in stuckNow {
                guard let session = sessions[entry.id] else { continue }
                BriefReducer.stuck(chatID: entry.id, title: session.title, machine: machine(session), since: entry.since,
                                   chatUpdatedAt: entry.updatedAt, longStep: stuckWatch.longStep(entry.id), in: &next, now: now)
            }
        }
        if next != file {
            var discard: [String] = []
            try? store.update(now: now) { stored in
                discard = BriefReducer.reconcile(&stored, chats: states, now: now)
                if autoTriage {
                    for entry in stuckNow {
                        guard let session = sessions[entry.id] else { continue }
                        BriefReducer.stuck(chatID: entry.id, title: session.title, machine: machine(session), since: entry.since,
                                           chatUpdatedAt: entry.updatedAt, longStep: stuckWatch.longStep(entry.id), in: &stored, now: now)
                    }
                }
            }
            discardProposals(discard)
            file = store.load()
        }
        if morningPending && !all.isEmpty { morning(now: now) }
        refreshGate(now: now)
        pump(now: now)
    }

    private func machine(_ session: AgentSession) -> String { session.remote?.hostName ?? "This Mac" }

    /// Looks at the end of each quiet local chat's transcript (the worker answers "unchanged" for a
    /// revision it already gave), off the main thread, at most three at a time. Never over SSH.
    private func glance(_ ids: [String], now: Date) {
        let profiles = profiles()
        for id in ids where glancing.count < 3 && !glancing.contains(id) {
            guard let session = sessions[id], session.remote == nil else { continue }
            glancing.insert(id)
            let revision = stuckWatch.revision(id)
            Task {
                let read = await Task.detached(priority: .utility) {
                    try? ChatTranscripts.read(session, host: nil, profiles: profiles, limit: 4, after: revision)
                }.value
                glancing.remove(id)
                switch read {
                case .unchanged?: stuckWatch.record(id, glance: nil, now: Date())
                case .loaded(let transcript, let revision)?: stuckWatch.record(id, glance: StuckWatch.Glance(transcript, revision: revision), now: Date())
                case nil: stuckWatch.record(id, glance: nil, unreadable: true, now: Date())
                }
            }
        }
    }

    private func refreshGate(now: Date) {
        let next = TriageScheduler.gate(enabled: autoTriage, runs: runTimes, now: now, calendar: calendar, usage: usage(),
                                        budget: TriageBudget(dailyCap: dailyCap))
        if next != gate { gate = next }
        let today = runTimes.filter { calendar.isDate($0, inSameDayAs: now) }.count
        if today != runsToday { runsToday = today }
    }

    /// Once per local day after 05:00, on the first sample after launch or an activation: queue
    /// chats still waiting on you or unread from the last day (newest five).
    private func morning(now: Date) {
        morningPending = false
        guard autoTriage, morningBrief,
              MorningBrief.isDue(now: now, lastDay: defaults.string(forKey: Self.morningDayKey), calendar: calendar) else { return }
        defaults.set(TodoDay.key(now, calendar: calendar), forKey: Self.morningDayKey)
        let candidates = sessions.values.filter { ($0.state == .waiting || $0.isDone) && now.timeIntervalSince($0.updatedAt) < 86_400 }
            .sorted { $0.updatedAt > $1.updatedAt }.prefix(TriageScheduler.batchSize)
        // Queued as if they arrived a minute ago, so they go in the next run.
        for session in candidates {
            stops[session.id] = session.state == .waiting ? .waiting : .finished
            scheduler.enqueue(session.id, trigger: "morning", at: now.addingTimeInterval(-60))
        }
    }

    // MARK: Runs

    /// When triage last ran (from the runs log), for the Orchestrator page's header.
    var lastRunAt: Date? { runTimes.max() }

    /// "Run triage now": reads the newest chats waiting on you or unread (up to
    /// `TriageNow.lookLimit`, off the main thread), picks up to five whose latest messages haven't
    /// been triaged, and puts them at the front of the queue, due at once (a run starts now, or
    /// right after the one in progress). Only through the gate, checked before and after reading:
    /// off, a cap or a Claude window below its floor queues nothing and says why.
    @discardableResult
    func runNow(now: Date = Date()) async -> TriageNow.Outcome {
        guard started else { return .paused("Triage hasn't started yet") }
        guard !checkingNow else { return .paused("Already looking for chats to triage") }
        refreshGate(now: now)
        let plan = TriageNow.plan(chats: sessions.values.map(BriefChatState.init), gate: gate)
        if let outcome = plan.outcome { return outcome }
        let total = sessions.values.map(BriefChatState.init).filter { $0.waiting || $0.unread }.count
        let hosts = hosts(), profiles = profiles(), triaged = file.triaged
        // A chat on a machine that isn't configured or answering is skipped (no SSH wait for it).
        let targets: [(id: String, session: AgentSession, host: RemoteHost?)] = plan.chatIDs.compactMap { id in
            guard let session = sessions[id] else { return nil }
            let host = hosts.first { $0.id == session.remote?.hostID }
            if let remote = session.remote, host == nil || remote.stale { return nil }
            return (id, session, host)
        }
        checkingNow = true
        defer { checkingNow = false }
        // Newest first, stopping once a batch's worth needs triage.
        let inputs = await Task.detached(priority: .userInitiated) { () -> [(id: String, input: TriageInput?)] in
            var read: [(id: String, input: TriageInput?)] = []
            for target in targets {
                if read.filter({ TriageNow.needsTriage($0.input, triaged: triaged) }).count >= TriageScheduler.batchSize { break }
                let transcript = try? ChatTranscripts.load(target.session, host: target.host, profiles: profiles, limit: 120)
                read.append((target.id, transcript.map {
                    TriageInput.build(chatID: target.id, title: "", project: "", machine: "", stop: .finished, messages: $0.messages, notes: [])
                }))
            }
            return read
        }.value
        // "in the 30 newest" only when older candidates really weren't looked at.
        let picked = TriageNow.pick(inputs, triaged: triaged, total: total > plan.chatIDs.count ? Int.max : inputs.count)
        guard !picked.chatIDs.isEmpty else { return picked.outcome }
        // The gate again: a cap or a limit may have been reached while the chats were read.
        refreshGate(now: Date())
        if !gate.allowsRun { return .paused(gate == .off ? "Triage is off" : gate.reason ?? "Triage is paused") }
        for id in picked.chatIDs { stops[id] = sessions[id]?.state == .waiting ? .waiting : .finished }
        scheduler.prioritize(picked.chatIDs, at: Date())
        pump(now: Date())
        return picked.outcome
    }

    #if DEBUG
    /// Render harnesses only: a brief to show without reading `brief.json` or the runs log.
    func preview(file: BriefFile, runsToday: Int, lastRun: Date?, gate: TriageGate = .open, triaging: Int = 0) {
        self.file = file; self.runsToday = runsToday; self.gate = gate; self.triaging = triaging
        runTimes = lastRun.map { [$0] } ?? []
    }
    #endif

    private func pump(now: Date) {
        guard triaging == 0, scheduler.isDue(now: now), gate.allowsRun else { return }
        let batch = scheduler.takeBatch()
        let trigger = batch.contains { $0.trigger == "triage" } ? "triage" : "morning"
        let hosts = hosts(), profiles = profiles(), triaged = file.triaged
        let targets: [Target] = batch.compactMap { pending in
            guard let session = sessions[pending.chatID] else { return nil }
            let project = project(session)
            return Target(session: session, host: hosts.first { $0.id == session.remote?.hostID }, stop: stops[pending.chatID] ?? .finished,
                          projectName: project.name, projectPath: project.path, machine: machine(session))
        }
        guard !targets.isEmpty else { return }
        triaging = targets.count
        let runner = runner, cancel = ProcessCancel()
        inFlight = cancel
        Task {
            let inputs = await Task.detached(priority: .utility) {
                targets.compactMap { target -> TriageInput? in
                    guard let transcript = try? ChatTranscripts.load(target.session, host: target.host, profiles: profiles, limit: 120) else { return nil }
                    let input = TriageInput.build(chatID: target.session.id, title: target.session.title, project: target.projectName,
                                                  machine: target.machine, stop: target.stop, messages: transcript.messages,
                                                  notes: TriageMemory.notes(project: target.projectPath ?? target.session.cwd))
                    return TriageNow.needsTriage(input, triaged: triaged) ? input : nil
                }
            }.value
            // Off since the batch was taken: no call; off during the call: it is stopped and
            // whatever it found is dropped.
            if !autoTriage { cancel.cancel() }
            if !inputs.isEmpty, let run = await Task.detached(priority: .utility, operation: {
                OrchestratorTriage.run(inputs, trigger: trigger, runner: runner, cancel: cancel)
            }).value {
                let log = runs, record = run.record
                await Task.detached(priority: .utility) { try? log.append(record) }.value
                runTimes.append(record.at)
                runLogged()
                if autoTriage && !cancel.isCancelled { apply(run, inputs: inputs, targets: targets) }
            }
            if inFlight === cancel { inFlight = nil }
            triaging = 0
            refreshGate(now: Date())
            pump(now: Date())
        }
    }

    private struct Target: Sendable {
        var session: AgentSession
        var host: RemoteHost?
        var stop: TriageInput.Stop
        var projectName: String
        var projectPath: String?
        var machine: String
    }

    private func apply(_ run: OrchestratorTriage.Run, inputs: [TriageInput], targets: [Target]) {
        problem = run.failure.map { $0 == .noClaude || $0 == .signedOut ? $0.short.replacingOccurrences(of: " for a written summary", with: "") : "Last triage failed" }
        guard run.failure == nil else { return }
        let now = Date()
        let inputByID = Dictionary(inputs.map { ($0.chatID, $0) }, uniquingKeysWith: { first, _ in first })
        let targetByID = Dictionary(targets.map { ($0.session.id, $0) }, uniquingKeysWith: { first, _ in first })
        var drafts: [(itemID: String, text: String, target: Target)] = []
        var discard: [String] = []
        var headlines: [(String, String)] = []
        try? store.update(now: now) { stored in
            for result in run.results {
                guard let input = inputByID[result.chatID], let target = targetByID[result.chatID] else { continue }
                // As of the transcript that was read: anything newer means the chat moved on.
                let change = BriefReducer.apply(result, title: target.session.title, machine: target.machine, sourceHash: input.sourceHash,
                                                chatUpdatedAt: target.session.updatedAt, to: &stored, now: now)
                discard += change.discard
                if let draft = change.draft { drafts.append((draft.itemID, draft.text, target)) }
                if result.kind.needsYou { headlines.append((result.chatID, result.headline)) }
            }
            // A chat the answer skipped still counts as triaged for these messages.
            for input in inputs where stored.triaged[input.chatID] != input.sourceHash { stored.triaged[input.chatID] = input.sourceHash }
        }
        discardProposals(discard)
        for draft in drafts {
            let action = OrchestratorAction(kind: .reply, createdAt: now, text: draft.text, chatID: draft.target.session.id,
                                            chatTitle: draft.target.session.title, machine: draft.target.machine,
                                            conversation: BriefDrafts.triageConversation)
            guard let saved = try? actions.propose(action, now: now) else { continue }
            try? store.update(now: now) { BriefReducer.attach(proposal: saved.action.id, to: draft.itemID, in: &$0) }
        }
        file = store.load()
        proposalsChanged()
        for (chat, headline) in headlines { headlineReady(chat, headline) }
    }

    /// Removes drafts of resolved or replaced items that are still waiting (never a sent one).
    private func discardProposals(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        try? actions.update { $0.removeAll { set.contains($0.id) && $0.status == .pending } }
        proposalsChanged()
    }

    /// Dismisses an item by hand (the row's ×); its waiting draft goes too.
    func dismiss(_ item: BriefItem) {
        try? store.update { stored in
            guard let index = stored.items.firstIndex(where: { $0.id == item.id }) else { return }
            stored.items[index].resolvedAt = Date()
        }
        if let proposal = item.proposalID { discardProposals([proposal]) }
        file = store.load()
    }
}
