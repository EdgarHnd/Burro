// Keep Awake: keeps this Mac from sleeping while you ask, or while agents work on it.
// An open lid needs nothing but an assertion Burro holds. A closed lid needs `pmset -a disablesleep 1`:
// started silently only through the one-time sudoers rule you allow, otherwise only after an
// administrator prompt you asked for. A watchdog turns sleep back on even if Burro dies.
import AppKit
import Foundation
import Observation
import BurroCore

/// What Burro finds at launch, read off the main thread.
private struct KeepAwakeLaunchChecks: Sendable {
    var passwordless: Bool, rule: Bool, sleep: Bool?, battery: BatteryState?, adopted: Bool
}

@MainActor @Observable final class KeepAwakeStore {
    enum Leftover: Equatable {
        /// A Burro session ended without turning sleep back on (its watchdog was killed).
        case burro
        /// Something else turned sleep off (NoSleepBar, Amphetamine, a `pmset` command).
        case outside
    }
    private enum Keys {
        static let agents = "keepAwake.agents", linger = "keepAwake.lingerMinutes", manual = "keepAwake.manualUntil"
        static let session = "keepAwake.session", turnedOff = "keepAwake.turnedSleepOff", lastWorking = "keepAwake.lastWorkingAt"
    }
    static let tick: Duration = .seconds(15)
    /// How long a stopped session's watchdog is given to turn sleep back on before a disabled setting counts as left over.
    static let settle: TimeInterval = 8

    var agentsMode: Bool { didSet { defaults.set(agentsMode, forKey: Keys.agents); reconcile() } }
    var lingerMinutes: Int { didSet { defaults.set(lingerMinutes, forKey: Keys.linger); reconcile() } }
    private(set) var manualUntil: Date? { didSet { defaults.set(manualUntil, forKey: Keys.manual) } }
    private(set) var session: KeepAwakeSession? {
        didSet { defaults.set(session.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.session) }
    }
    private(set) var decision = KeepAwakeDecision.off
    private(set) var sleepDisabled: Bool?
    private(set) var passwordless = false
    private(set) var ruleInstalled = false
    private(set) var battery: BatteryState?
    private(set) var workingAgents = 0
    /// A session is starting, or a permission change is waiting on its prompt.
    private(set) var busy = false
    /// Launch checks (permission, adopting a session from the previous run) are done.
    private(set) var ready = false
    var message: String?

    /// Saved now and then so the linger also covers a relaunch.
    @ObservationIgnored private var lastWorkingAt: Date?
    @ObservationIgnored private var savedWorkingAt = Date.distantPast
    /// Until the first agent sample after launch, an adopted session is kept rather than judged on zero agents.
    @ObservationIgnored private var agentsSampled = false
    @ObservationIgnored private var turnedSleepOff: Bool { didSet { defaults.set(turnedSleepOff, forKey: Keys.turnedOff) } }
    @ObservationIgnored private var lastTouch = Date.distantPast
    @ObservationIgnored private var lastStop = Date.distantPast
    @ObservationIgnored private var retryAfter = Date.distantPast
    @ObservationIgnored private var assertionHeld = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private(set) var pending: Task<Void, Never>?
    @ObservationIgnored private let system: any KeepAwakeSystem
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let owner: Int32
    @ObservationIgnored let folder: URL

    init(defaults: UserDefaults = .standard, system: any KeepAwakeSystem = LiveKeepAwakeSystem(),
         folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Burro/KeepAwake", isDirectory: true),
         owner: Int32 = getpid()) {
        self.defaults = defaults; self.system = system; self.folder = folder; self.owner = owner
        agentsMode = defaults.bool(forKey: Keys.agents)
        lingerMinutes = defaults.object(forKey: Keys.linger) as? Int ?? 5
        manualUntil = defaults.object(forKey: Keys.manual) as? Date
        session = defaults.data(forKey: Keys.session).flatMap { try? JSONDecoder().decode(KeepAwakeSession.self, from: $0) }
        turnedSleepOff = defaults.bool(forKey: Keys.turnedOff)
        lastWorkingAt = defaults.object(forKey: Keys.lastWorking) as? Date
    }

    var awake: Bool { decision.awake }
    var lidClosedActive: Bool { session != nil }
    var manualActive: Bool { manualUntil.map { $0 > Date() } ?? false }
    var headline: String { KeepAwakeText.headline(decision) { $0.formatted(date: .omitted, time: .shortened) } }
    var coverage: String? { KeepAwakeText.coverage(decision, lidClosedActive: lidClosedActive) }
    var leftover: Leftover? {
        guard ready, sleepDisabled == true, session == nil, !busy, Date().timeIntervalSince(lastStop) > Self.settle else { return nil }
        return turnedSleepOff ? .burro : .outside
    }
    /// A manual request is on but a closed lid isn't covered, and covering it needs a prompt.
    var canIncludeClosedLid: Bool { manualActive && session == nil && !passwordless && !busy && decision.awake }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.launch()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tick)
                guard let self else { return }
                await self.refreshState()
            }
        }
    }
    /// The app is quitting: the watchdog keeps a lid-closed session for 30 seconds so a relaunch can take it over.
    func stop() {
        loop?.cancel(); loop = nil
        system.setAssertion(false); assertionHeld = false
    }

    // MARK: Requests

    /// Keeps the Mac awake for `seconds`, or until you stop it. Without the passwordless rule this asks for the
    /// administrator prompt so a closed lid is covered too; cancelling it still keeps an open lid awake.
    func keepAwake(for seconds: TimeInterval?) {
        manualUntil = seconds.map { Date().addingTimeInterval($0) } ?? .distantFuture
        message = nil
        reconcile()
        if session == nil, !passwordless { includeClosedLid() }
    }
    func stopManual() {
        manualUntil = nil; message = nil
        reconcile()
    }
    func includeClosedLid() {
        guard session == nil, !busy, ready else { return }
        begin(passwordless ? .passwordless : .administrator)
    }
    /// Chats working on this Mac, from each agent refresh.
    func agentsChanged(working: Int, now: Date = Date()) {
        agentsSampled = true
        if working > 0 {
            lastWorkingAt = now
            if now.timeIntervalSince(savedWorkingAt) >= 30 { defaults.set(now, forKey: Keys.lastWorking); savedWorkingAt = now }
        }
        if working != workingAgents { workingAgents = working }
        reconcile(now: now)
    }

    // MARK: Permission

    /// Installs the sudoers rule (one administrator prompt) so lid-closed sessions start and stop without asking.
    func allowWithoutPassword() {
        guard !busy else { return }
        busy = true; message = nil
        let system = system, user = NSUserName()
        pending = Task {
            let (result, allowed, installed) = await Task.detached(priority: .userInitiated) {
                let result = system.installRule(user: user)
                return (result, system.passwordlessAllowed(), system.ruleInstalled())
            }.value
            busy = false; passwordless = allowed; ruleInstalled = installed
            switch result {
            case .success where !allowed:
                message = "The permission was saved, but sudo still asks for a password. Check that /etc/sudoers includes /private/etc/sudoers.d."
            case .success, .failure(.cancelled): break
            case .failure(let error): message = error.message
            }
            reconcile()
        }
    }
    /// Removes Burro's sudoers rule. Not while a lid-closed session runs: its watchdog needs the rule to turn sleep back on.
    func removePermission() {
        guard !busy, session == nil else { return }
        busy = true; message = nil
        let system = system
        pending = Task {
            let (result, allowed, installed) = await Task.detached(priority: .userInitiated) {
                (system.removeRule(), system.passwordlessAllowed(), system.ruleInstalled())
            }.value
            busy = false; passwordless = allowed; ruleInstalled = installed
            if case .failure(let error) = result, error != .cancelled { message = error.message }
            reconcile()
        }
    }
    /// Turns sleep back on when it was left off (by an ended Burro session or something else).
    func turnSleepBackOn(quietly: Bool = false) {
        guard !busy else { return }
        busy = true
        let system = system, authorization: KeepAwakeAuthorization = passwordless ? .passwordless : .administrator
        pending = Task {
            let (result, disabled) = await Task.detached(priority: .userInitiated) {
                let result = system.restoreSleep(authorization: authorization)
                return (result, system.sleepDisabled())
            }.value
            busy = false; sleepDisabled = disabled
            switch result {
            case .success:
                turnedSleepOff = false
                if quietly { message = "Turned sleep back on: an earlier keep-awake session ended without doing it." }
            case .failure(.cancelled): break
            case .failure(let error): message = error.message
            }
        }
    }

    // MARK: State

    func reconcile(now: Date = Date()) {
        if let until = manualUntil, until <= now { manualUntil = nil }
        let next = KeepAwakePolicy.decide(KeepAwakeInputs(now: now, manualUntil: manualUntil, agentsMode: agentsMode,
            workingAgents: workingAgents, lastWorkingAt: lastWorkingAt, linger: TimeInterval(lingerMinutes * 60), battery: battery,
            passwordless: passwordless, administratorSession: session?.authorization == .administrator))
        if next != decision { decision = next }
        if next.awake != assertionHeld { system.setAssertion(next.awake); assertionHeld = next.awake }
        guard ready, !busy else { return }
        if let session, !next.lidClosed { if !agentsMode || agentsSampled { end(session) } }
        else if session == nil, next.lidClosed, passwordless, now >= retryAfter { begin(.passwordless) }
    }
    func refreshState() async {
        let system = system, current = session
        let (disabled, battery, alive) = await Task.detached(priority: .utility) {
            (system.sleepDisabled(), system.battery(), current.map { system.isAlive($0) })
        }.value
        if disabled != sleepDisabled { sleepDisabled = disabled }
        if battery != self.battery { self.battery = battery }
        if let current, session == current, alive == false {
            session = nil; lastStop = Date()
            message = "Keep awake's watchdog ended on its own, so a closed lid sleeps again."
        }
        if let session, Date().timeIntervalSince(lastTouch) >= KeepAwakePolicy.heartbeat { system.touch(session); lastTouch = Date() }
        if disabled == false, session == nil { turnedSleepOff = false }
        if leftover == .burro, passwordless { turnSleepBackOn(quietly: true) }
        reconcile()
    }

    func launch() async {
        let system = system, saved = session, owner = owner, folder = folder
        let checks = await Task.detached(priority: .utility) {
            let adopted = saved.map { system.isAlive($0) && system.adopt($0, owner: owner) } ?? false
            // Any other marker belongs to a watchdog nobody can take over now; removing it turns sleep back on.
            if !adopted { system.stopAll(in: folder) }
            return KeepAwakeLaunchChecks(passwordless: system.passwordlessAllowed(), rule: system.ruleInstalled(),
                                sleep: system.sleepDisabled(), battery: system.battery(), adopted: adopted)
        }.value
        passwordless = checks.passwordless; ruleInstalled = checks.rule; sleepDisabled = checks.sleep; battery = checks.battery
        if saved != nil, !checks.adopted {
            session = nil; lastStop = Date()
            if manualActive, !passwordless { message = "Burro restarted, so a closed lid isn't covered any more. Use Include closed lid to cover it again." }
        }
        if checks.adopted { lastTouch = .distantPast }
        ready = true
        reconcile()
    }
    private func begin(_ authorization: KeepAwakeAuthorization) {
        guard !busy else { return }
        busy = true
        let system = system, folder = folder, owner = owner
        pending = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.startSession(system: system, folder: folder, owner: owner, authorization: authorization)
            }.value
            busy = false
            switch result {
            case .success(let started):
                session = started; turnedSleepOff = true; sleepDisabled = true; lastTouch = Date(); message = nil
            case .failure(.cancelled):
                message = "A closed lid still puts the Mac to sleep: the administrator prompt was cancelled."
            case .failure(let error):
                message = error.message; retryAfter = Date().addingTimeInterval(60)
            }
            reconcile()
        }
    }
    private func end(_ session: KeepAwakeSession) {
        system.stop(session)
        self.session = nil; lastStop = Date()
        // Read the setting again once the watchdog has turned sleep back on.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            await self?.refreshState()
        }
    }
    nonisolated static func startSession(system: any KeepAwakeSystem, folder: URL, owner: Int32,
                                         authorization: KeepAwakeAuthorization) -> Result<KeepAwakeSession, KeepAwakeError> {
        func attempt() -> Result<KeepAwakeSession, KeepAwakeError> {
            let marker = folder.appendingPathComponent("session-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard FileManager.default.createFile(atPath: marker.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    return .failure(.failed("Couldn't create \(marker.path)."))
                }
            } catch { return .failure(.failed(error.localizedDescription)) }
            let result = system.startSession(owner: owner, marker: marker, authorization: authorization)
            if case .failure = result { try? FileManager.default.removeItem(at: marker) }
            return result
        }
        let first = attempt()
        guard case .failure(.busy) = first else { return first }
        // A watchdog Burro lost track of (or one still turning sleep back on): stop it, give it a moment, try once more.
        system.stopAll(in: folder)
        Thread.sleep(forTimeInterval: 4)
        return attempt()
    }
}
