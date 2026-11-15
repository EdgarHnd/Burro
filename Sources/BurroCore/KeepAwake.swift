// Keep Awake: when Burro keeps this Mac from sleeping, and the system calls that do it.
// A process-held idle-sleep assertion covers an open lid with no password; a closed lid needs
// `pmset -a disablesleep 1`, which always runs under a watchdog that turns sleep back on.
import Darwin
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import CSystem

public struct BatteryState: Equatable, Sendable {
    public var onBattery: Bool
    public var percent: Int
    public init(onBattery: Bool, percent: Int) { self.onBattery = onBattery; self.percent = percent }
}

public struct KeepAwakeInputs: Sendable {
    public var now: Date
    /// When a manual request ends; `Date.distantFuture` means until you stop it.
    public var manualUntil: Date?
    public var agentsMode: Bool
    /// Chats working on this Mac right now.
    public var workingAgents: Int
    /// The last time any chat on this Mac was seen working.
    public var lastWorkingAt: Date?
    public var linger: TimeInterval
    public var battery: BatteryState?
    /// sudoers allows Burro's pmset commands without a password, so lid-closed sessions start on their own.
    public var passwordless: Bool
    /// A session started after an administrator prompt is running; it can't be restarted without another one.
    public var administratorSession: Bool
    public init(now: Date, manualUntil: Date? = nil, agentsMode: Bool = false, workingAgents: Int = 0, lastWorkingAt: Date? = nil,
                linger: TimeInterval = 300, battery: BatteryState? = nil, passwordless: Bool = false, administratorSession: Bool = false) {
        self.now = now; self.manualUntil = manualUntil; self.agentsMode = agentsMode; self.workingAgents = workingAgents
        self.lastWorkingAt = lastWorkingAt; self.linger = linger; self.battery = battery; self.passwordless = passwordless
        self.administratorSession = administratorSession
    }
}

public enum KeepAwakeReason: Equatable, Sendable {
    case off
    /// Asked for by you; nil until you stop it.
    case manual(until: Date?)
    case agents(Int)
    /// The last agent finished; staying awake a little longer in case another turn starts.
    case lingering(until: Date)
    /// Would be awake, but the battery is nearly empty.
    case lowBattery(Int)
}

public struct KeepAwakeDecision: Equatable, Sendable {
    /// Hold the idle-sleep assertion (an open lid stays awake).
    public var awake: Bool
    /// Also keep a closed lid awake (`pmset -a disablesleep 1`).
    public var lidClosed: Bool
    public var reason: KeepAwakeReason
    public static let off = KeepAwakeDecision(awake: false, lidClosed: false, reason: .off)
    public init(awake: Bool, lidClosed: Bool, reason: KeepAwakeReason) { self.awake = awake; self.lidClosed = lidClosed; self.reason = reason }
}

public enum KeepAwakePolicy {
    /// On battery at or below this, Burro lets the Mac sleep whatever was asked.
    public static let lowBatteryPercent = 10
    /// How often Burro touches the session marker; the watchdog gives up on a marker 15 minutes old.
    public static let heartbeat: TimeInterval = 60
    public static let lingerChoices = [0, 5, 15, 30]
    public static let durations: [(title: String, seconds: TimeInterval?)] = [("1 hour", 3600), ("2 hours", 7200), ("4 hours", 14_400), ("Until I stop", nil)]

    public static func decide(_ input: KeepAwakeInputs) -> KeepAwakeDecision {
        let manual = input.manualUntil.flatMap { $0 > input.now ? $0 : nil }
        let working = input.agentsMode && input.workingAgents > 0
        let lingerEnd = input.agentsMode && input.linger > 0 ? input.lastWorkingAt.map { $0.addingTimeInterval(input.linger) } : nil
        let reason: KeepAwakeReason
        if let manual { reason = .manual(until: manual == .distantFuture ? nil : manual) }
        else if working { reason = .agents(input.workingAgents) }
        else if let lingerEnd, lingerEnd > input.now { reason = .lingering(until: lingerEnd) }
        else { return .off }
        if let battery = input.battery, battery.onBattery, battery.percent <= lowBatteryPercent {
            return KeepAwakeDecision(awake: false, lidClosed: false, reason: .lowBattery(battery.percent))
        }
        let lidClosed = input.passwordless || (input.administratorSession && manual != nil)
        return KeepAwakeDecision(awake: true, lidClosed: lidClosed, reason: reason)
    }
}

/// Plain-language status lines shared by the Mac Health card, the menu bar and the notch.
public enum KeepAwakeText {
    public static func headline(_ decision: KeepAwakeDecision, time: (Date) -> String) -> String {
        switch decision.reason {
        case .off: "Off"
        case .manual(nil): "Awake until you stop it"
        case .manual(let until?): "Awake until \(time(until))"
        case .agents(let count): "Awake while \(count) agent\(count == 1 ? "" : "s") work\(count == 1 ? "s" : "")"
        case .lingering(let until): "Awake until \(time(until)), after the last agent finished"
        case .lowBattery(let percent): "Paused at \(percent)% battery"
        }
    }
    /// What the current state covers, or nil when off.
    public static func coverage(_ decision: KeepAwakeDecision, lidClosedActive: Bool) -> String? {
        switch decision.reason {
        case .off: return nil
        case .lowBattery: return "Plug in to keep the Mac awake; it sleeps as usual below \(KeepAwakePolicy.lowBatteryPercent)% on battery."
        default: return lidClosedActive ? "Closing the lid won't put it to sleep." : "Only while the lid is open. Closing the lid still sleeps."
        }
    }
}

public enum KeepAwakeAuthorization: String, Codable, Sendable {
    /// Started through the sudoers rule; Burro can stop and restart it without asking.
    case passwordless
    /// Started after an administrator prompt; the watchdog runs as root.
    case administrator
}

public struct KeepAwakeSession: Codable, Equatable, Sendable {
    public var watcher: Int32
    /// The watchdog's start time (seconds since 1970), so a reused pid is never mistaken for it.
    public var watcherStarted: UInt64
    public var lock: String
    public var marker: String
    public var authorization: KeepAwakeAuthorization
    public var startedAt: Date
    public init(watcher: Int32, watcherStarted: UInt64, lock: String, marker: String, authorization: KeepAwakeAuthorization, startedAt: Date) {
        self.watcher = watcher; self.watcherStarted = watcherStarted; self.lock = lock; self.marker = marker
        self.authorization = authorization; self.startedAt = startedAt
    }
}

public enum KeepAwakeError: Error, Equatable, Sendable {
    case cancelled, notAllowed, busy
    case failed(String)
    public var message: String {
        switch self {
        case .cancelled: "The administrator prompt was cancelled."
        case .notAllowed: "Burro isn't allowed to change sleep without a password yet."
        case .busy: "Another keep-awake session is still turning sleep back on. Try again in a few seconds."
        case .failed(let reason): reason
        }
    }
}

/// Everything Keep Awake asks of the system, so the store can be tested without touching sleep.
public protocol KeepAwakeSystem: Sendable {
    /// `SleepDisabled` from the power manager, nil if unreadable.
    func sleepDisabled() -> Bool?
    func battery() -> BatteryState?
    func passwordlessAllowed() -> Bool
    func ruleInstalled() -> Bool
    func startSession(owner: Int32, marker: URL, authorization: KeepAwakeAuthorization) -> Result<KeepAwakeSession, KeepAwakeError>
    func isAlive(_ session: KeepAwakeSession) -> Bool
    /// Asks a running watchdog to treat `owner` as its Burro; true once it confirms.
    func adopt(_ session: KeepAwakeSession, owner: Int32) -> Bool
    /// Removes the marker; the watchdog turns sleep back on within a couple of seconds.
    func stop(_ session: KeepAwakeSession)
    /// Removes every session marker in `folder`, for watchdogs Burro lost track of.
    func stopAll(in folder: URL)
    func touch(_ session: KeepAwakeSession)
    func restoreSleep(authorization: KeepAwakeAuthorization) -> Result<Void, KeepAwakeError>
    func installRule(user: String) -> Result<Void, KeepAwakeError>
    func removeRule() -> Result<Void, KeepAwakeError>
    /// The open-lid assertion, held by this process and released automatically if it exits.
    func setAssertion(_ held: Bool)
}

public enum PowerReader {
    /// `SleepDisabled` is `pmset -a disablesleep`. Read through IOPMCopySystemPowerSettings, which IOKit
    /// exports without a public header, so no process is launched; `pmset -g` is the fallback.
    public static func sleepDisabled() -> Bool? {
        if let settings = copySystemPowerSettings() {
            switch settings["SleepDisabled"] {
            case let number as NSNumber: return number.boolValue
            case nil: return false
            default: break
            }
        }
        let result = CommandRunner().run("/usr/bin/pmset", ["-g"], timeout: 5)
        return result.succeeded ? parsePMSet(result.output) : nil
    }
    /// `SleepDisabled  1` in `pmset -g`; macOS leaves the line out when it has never been set.
    public static func parsePMSet(_ output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0].caseInsensitiveCompare("SleepDisabled") == .orderedSame else { continue }
            if fields[1] == "1" { return true }
            if fields[1] == "0" { return false }
        }
        return output.contains("Currently in use") || output.contains("System-wide power settings") ? false : nil
    }
    public static func battery() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let state = description[kIOPSPowerSourceStateKey] as? String
            return BatteryState(onBattery: state == kIOPSBatteryPowerValue, percent: Int((Double(current) / Double(maximum) * 100).rounded()))
        }
        return nil
    }
    private typealias CopySettings = @convention(c) () -> Unmanaged<CFDictionary>?
    // Looked up once and never changed.
    nonisolated(unsafe) private static let copySettings: CopySettings? = {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let symbol = dlsym(iokit, "IOPMCopySystemPowerSettings") else { return nil }
        return unsafeBitCast(symbol, to: CopySettings.self)
    }()
    private static func copySystemPowerSettings() -> [String: Any]? {
        copySettings?()?.takeRetainedValue() as? [String: Any]
    }
}

public final class LiveKeepAwakeSystem: KeepAwakeSystem, @unchecked Sendable {
    private let runner = CommandRunner()
    private let lock = NSLock()
    private var assertion: IOPMAssertionID?
    public init() {}

    public func sleepDisabled() -> Bool? { PowerReader.sleepDisabled() }
    public func battery() -> BatteryState? { PowerReader.battery() }
    public func passwordlessAllowed() -> Bool {
        ["1", "0"].allSatisfy { runner.run("/usr/bin/sudo", ["-n", "-k", "-l", "/usr/bin/pmset", "-a", "disablesleep", $0], timeout: 5).succeeded }
    }
    public func ruleInstalled() -> Bool { FileManager.default.fileExists(atPath: KeepAwakeScript.rulePath) }

    public func startSession(owner: Int32, marker: URL, authorization: KeepAwakeAuthorization) -> Result<KeepAwakeSession, KeepAwakeError> {
        let arguments = ["start", "\(owner)", marker.path]
        let result: CommandResult
        switch authorization {
        case .passwordless:
            result = runner.run("/bin/sh", KeepAwakeScript.shellArguments(KeepAwakeScript.session, arguments), timeout: 30)
        case .administrator:
            result = runAsAdministrator(KeepAwakeScript.commandLine(KeepAwakeScript.session, arguments),
                prompt: "Burro wants to keep this Mac awake with the lid closed. Sleep comes back on when you stop, when the time is up, or 30 seconds after Burro quits.")
        }
        if let error = Self.error(result) { return .failure(error) }
        let fields = result.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1)
        var info = BurroProcess()
        guard fields.count == 2, let watcher = Int32(fields[0]), burro_process_info(watcher, &info) == 1 else {
            return .failure(.failed("Sleep was turned off, but Burro couldn't find its watchdog: \(result.output)"))
        }
        return .success(KeepAwakeSession(watcher: watcher, watcherStarted: info.started, lock: String(fields[1]), marker: marker.path,
                                         authorization: authorization, startedAt: Date()))
    }
    public func isAlive(_ session: KeepAwakeSession) -> Bool {
        var info = BurroProcess()
        return burro_process_info(session.watcher, &info) == 1 && info.started == session.watcherStarted
            && FileManager.default.fileExists(atPath: session.marker)
    }
    public func adopt(_ session: KeepAwakeSession, owner: Int32) -> Bool {
        let folder = URL(fileURLWithPath: session.marker).deletingLastPathComponent()
        let request = folder.appendingPathComponent("adopt"), answer = URL(fileURLWithPath: session.lock).appendingPathComponent("owner")
        guard (try? Data("\(owner)\n".utf8).write(to: request, options: .atomic)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: request) }
        // The watchdog notices its old Burro is gone within a couple of seconds, then checks every second.
        for _ in 0..<50 {
            if let text = try? String(contentsOf: answer, encoding: .utf8),
               Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) == owner { return true }
            guard isAlive(session) else { return false }
            usleep(100_000)
        }
        return false
    }
    public func stop(_ session: KeepAwakeSession) { try? FileManager.default.removeItem(atPath: session.marker) }
    public func stopAll(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("session-") { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    }
    public func touch(_ session: KeepAwakeSession) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: session.marker)
    }
    public func restoreSleep(authorization: KeepAwakeAuthorization) -> Result<Void, KeepAwakeError> {
        let result = authorization == .passwordless
            ? runner.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"], timeout: 10)
            : runAsAdministrator("/usr/bin/pmset -a disablesleep 0", prompt: "Burro wants to turn sleep back on for this Mac.")
        return Self.error(result).map { .failure($0) } ?? .success(())
    }
    public func installRule(user: String) -> Result<Void, KeepAwakeError> {
        let result = runAsAdministrator(KeepAwakeScript.commandLine(KeepAwakeScript.setup, ["install", user]),
            prompt: "Burro wants to turn lid-closed sleep off and back on without asking each time. This allows only “pmset -a disablesleep 0” and “… 1” without a password.")
        return Self.error(result).map { .failure($0) } ?? .success(())
    }
    public func removeRule() -> Result<Void, KeepAwakeError> {
        let result = runAsAdministrator(KeepAwakeScript.commandLine(KeepAwakeScript.setup, ["remove"]),
            prompt: "Burro wants to remove its permission to change sleep without a password.")
        return Self.error(result).map { .failure($0) } ?? .success(())
    }
    public func setAssertion(_ held: Bool) {
        lock.lock(); defer { lock.unlock() }
        if held, assertion == nil {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Burro is keeping this Mac awake" as CFString, &id) == kIOReturnSuccess { assertion = id }
        } else if !held, let id = assertion {
            IOPMAssertionRelease(id); assertion = nil
        }
    }

    private func runAsAdministrator(_ command: String, prompt: String) -> CommandResult {
        // Waits for you to answer the prompt.
        runner.run("/usr/bin/osascript", KeepAwakeScript.administratorArguments(command: command, prompt: prompt), timeout: 600)
    }
    static func error(_ result: CommandResult) -> KeepAwakeError? {
        if result.succeeded { return nil }
        let text = (result.error + "\n" + result.output).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("(-128)") || text.localizedCaseInsensitiveContains("User canceled") { return .cancelled }
        if result.timedOut { return .failed("Timed out waiting for the command.") }
        // Through osascript the script's exit status ends its message, as in "… (4)".
        switch result.code {
        case 3: return .notAllowed
        case 4: return .busy
        case _ where text.hasSuffix("(4)"): return .busy
        default:
            // osascript reports the script's own message as "execution error: <message> (<code>)".
            let message = text.components(separatedBy: "execution error: ").last ?? text
            return .failed(message.isEmpty ? "The command failed (\(result.code))." : message)
        }
    }
}
