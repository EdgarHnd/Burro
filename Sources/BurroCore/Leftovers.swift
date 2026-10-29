// Read-only detection of processes and simulators still running after the work that started them ended.
import Foundation
import CSystem
import Darwin

public struct ProcessSample: Sendable, Equatable, Identifiable {
    public var pid: Int
    public var parentPID: Int
    public var started: Date
    public var executable: String
    /// Used only to classify the process; never displayed or persisted.
    public var arguments: [String]
    public var cwd: String
    public var cpuTime: TimeInterval?
    public var resident: UInt64?
    public var listeningPorts: [Int]
    public var connections: Int
    public var id: String { "\(pid)@\(Int(started.timeIntervalSince1970))" }
    public init(pid: Int, parentPID: Int, started: Date, executable: String, arguments: [String] = [], cwd: String = "",
                cpuTime: TimeInterval? = nil, resident: UInt64? = nil, listeningPorts: [Int] = [], connections: Int = 0) {
        self.pid = pid; self.parentPID = parentPID; self.started = started; self.executable = executable
        self.arguments = arguments; self.cwd = cwd; self.cpuTime = cpuTime; self.resident = resident
        self.listeningPorts = listeningPorts; self.connections = connections
    }
}

public struct ProcessInventory: Sendable, Equatable {
    public var processes: [ProcessSample]
    public var sampledAt: Date
    public var complete: Bool
    public init(processes: [ProcessSample], sampledAt: Date, complete: Bool = true) {
        self.processes = processes; self.sampledAt = sampledAt; self.complete = complete
    }

    /// Same-user processes, excluding Burro and its children. Sockets are read only for processes outside app bundles.
    public static func read(now: Date = Date()) -> ProcessInventory {
        let count = burro_list_pids(nil, 0)
        guard count > 0 else { return ProcessInventory(processes: [], sampledAt: now, complete: false) }
        var pids = [Int32](repeating: 0, count: Int(count) + 1024)
        let found = pids.withUnsafeMutableBufferPointer { burro_list_pids($0.baseAddress, Int32($0.count)) }
        guard found > 0, found < pids.count else { return ProcessInventory(processes: [], sampledAt: now, complete: false) }
        var samples: [ProcessSample] = []
        var argumentBuffer = [CChar](repeating: 0, count: 16 * 1024)
        var socketBuffer = [BurroSocket](repeating: BurroSocket(), count: 256)
        for pid in pids.prefix(Int(found)) where pid > 0 {
            var info = BurroProcess()
            guard burro_process_info(pid, &info) == 1, info.uid == getuid() else { continue }
            let executable = withUnsafePointer(to: &info.executable) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            let cwd = withUnsafePointer(to: &info.cwd) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            var usage = BurroTaskUsage()
            let measured = burro_process_usage(pid, &usage) == 1
            // Apps and macOS services are never classified by arguments; launchd_sim's name its simulator.
            let app = LeftoverPolicy.isApp(executable), system = LeftoverPolicy.isSystem(executable)
            var arguments: [String] = []
            if !app && (!system || LeftoverPolicy.baseName(executable) == "launchd_sim") {
                var length: Int32 = 0
                let argc = argumentBuffer.withUnsafeMutableBufferPointer { burro_process_arguments(pid, $0.baseAddress, Int32($0.count), &length) }
                if argc > 0 {
                    arguments = argumentBuffer.prefix(Int(length)).split(separator: 0, omittingEmptySubsequences: false)
                        .prefix(Int(argc)).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
                }
            }
            var sample = ProcessSample(pid: Int(pid), parentPID: Int(info.ppid), started: Date(timeIntervalSince1970: Double(info.started)),
                executable: executable, arguments: arguments, cwd: cwd,
                cpuTime: measured ? Double(usage.cpu_ns) / 1_000_000_000 : nil, resident: measured ? usage.resident : nil)
            if !app && !system {
                let sockets = socketBuffer.withUnsafeMutableBufferPointer { burro_process_sockets(pid, $0.baseAddress, Int32($0.count)) }
                if sockets > 0 {
                    let open = socketBuffer.prefix(Int(sockets))
                    sample.listeningPorts = Array(Set(open.filter { $0.listening == 1 }.map { Int($0.local_port) })).sorted()
                    sample.connections = open.filter { $0.listening == 0 }.count
                }
            }
            samples.append(sample)
        }
        var excluded: Set<Int> = [Int(getpid())]
        var previous = 0
        while previous != excluded.count {
            previous = excluded.count
            for sample in samples where excluded.contains(sample.parentPID) { excluded.insert(sample.pid) }
        }
        return ProcessInventory(processes: samples.filter { !excluded.contains($0.pid) }, sampledAt: now)
    }
    /// Percent of one core used by each process since `previous`, keyed by process identity.
    public func cpuPercent(since previous: ProcessInventory?) -> [String: Double] {
        guard let previous else { return [:] }
        let interval = sampledAt.timeIntervalSince(previous.sampledAt)
        guard interval > 0.2 else { return [:] }
        let before = Dictionary(previous.processes.compactMap { process in process.cpuTime.map { (process.id, $0) } }, uniquingKeysWith: { first, _ in first })
        var result: [String: Double] = [:]
        for process in processes {
            guard let now = process.cpuTime, let then = before[process.id], now >= then else { continue }
            result[process.id] = (now - then) / interval * 100
        }
        return result
    }
}

public enum LeftoverKind: String, Sendable, CaseIterable {
    case runaway, watcher, devServer, agentScript, orphan, simulator
    public var title: String {
        switch self {
        case .runaway: "Still busy"
        case .watcher: "Long-running watcher"
        case .devServer: "Idle server"
        case .agentScript: "Agent script"
        case .orphan: "Orphaned"
        case .simulator: "Headless simulator"
        }
    }
}

public struct Leftover: Identifiable, Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case process(pid: Int, started: Date, executable: String)
        case simulator(udid: String)
    }
    public var kind: LeftoverKind
    public var name: String
    public var folder: String
    public var reason: String
    public var started: Date
    public var cpuTime: TimeInterval?
    public var cpuPercent: Double?
    public var resident: UInt64?
    public var children: Int
    public var target: Target
    /// Stable across restarts so Ignore keeps working for the same tool in the same folder.
    public var signature: String
    public var id: String {
        switch target {
        case .process(let pid, let started, _): "\(pid)@\(Int(started.timeIntervalSince1970))"
        case .simulator(let udid): "simulator:\(udid)"
        }
    }
    public var pid: Int? { if case .process(let pid, _, _) = target { pid } else { nil } }
}

public struct ProcessLine: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var cpuPercent: Double?
    public var resident: UInt64?
}

public struct LeftoverReport: Sendable, Equatable {
    public var leftovers: [Leftover]
    public var busiest: [ProcessLine]
    public var agentProcesses: Int
    public var agentMemory: UInt64
    public var complete: Bool
    public static let empty = LeftoverReport(leftovers: [], busiest: [], agentProcesses: 0, agentMemory: 0, complete: false)
    public var reclaimable: UInt64 { leftovers.compactMap(\.resident).reduce(0, +) }
}

public enum LeftoverPolicy {
    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/",
                                 "/Library/Developer/PrivateFrameworks/", "/Library/Developer/CoreSimulator/"]
    // Command-line tools that ship inside an app bundle are still checked.
    static let bundledTools = ["/Python.app/Contents/MacOS/", "/claude.app/Contents/MacOS/claude"]
    // Long-lived background services people start on purpose.
    static let services: Set<String> = ["watchman", "syncthing", "ssh-agent", "gpg-agent", "tailscaled", "ollama", "colima", "limactl"]
    static let interpreters: Set<String> = ["Python", "node", "bun", "deno", "ruby", "perl", "php", "bash", "zsh", "sh", "dash", "fish", "java"]
    static let runners: Set<String> = ["jest", "vitest", "expo", "vite", "webpack", "next", "nodemon", "tsc", "react-native", "metro", "storybook", "turbo"]
    static let agents: Set<String> = ["claude", "codex"]

    /// Bundle executables and their helpers, including relocated copies such as Chromium's code-sign clones.
    public static func isApp(_ executable: String) -> Bool {
        (executable.contains(".app/Contents/") || executable.contains("/Contents/MacOS/")) && !bundledTools.contains { executable.contains($0) }
    }
    public static func isSystem(_ executable: String) -> Bool { systemPrefixes.contains { executable.hasPrefix($0) } }

    public static func report(_ inventory: ProcessInventory, cpu: [String: Double], now: Date = Date(), home: String,
                              ignored: Set<String> = [], deviceName: (String) -> String? = { _ in nil }) -> LeftoverReport {
        let processes = inventory.processes
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [Int: [ProcessSample]] = [:]
        for process in processes where process.parentPID != process.pid { children[process.parentPID, default: []].append(process) }
        func descendants(of pid: Int) -> [ProcessSample] {
            var result: [ProcessSample] = [], queue = children[pid] ?? [], seen: Set<Int> = [pid]
            while let next = queue.popLast() {
                guard seen.insert(next.pid).inserted else { continue }
                result.append(next); queue += children[next.pid] ?? []
            }
            return result
        }
        func total(_ tree: [ProcessSample]) -> (cpu: Double?, resident: UInt64?) {
            let percents = tree.compactMap { cpu[$0.id] }, sizes = tree.compactMap(\.resident)
            return (percents.isEmpty ? nil : percents.reduce(0, +), sizes.isEmpty ? nil : sizes.reduce(0, +))
        }

        // Helpers an open app or agent spawned directly (extension backends, MCP servers) belong to it.
        func ownedByOpenParent(_ process: ProcessSample) -> Bool {
            guard let parent = byPID[process.parentPID] else { return false }
            return isApp(parent.executable) || isAgentCLI(parent.executable)
        }
        var leftovers: [Leftover] = []
        // One launchd_sim runs per booted simulator; everything inside it belongs to that device.
        let windowOpen = processes.contains { $0.executable.hasSuffix("/Simulator.app/Contents/MacOS/Simulator") }
        var simulated: Set<Int> = []
        for sim in processes where baseName(sim.executable) == "launchd_sim" {
            let tree = [sim] + descendants(of: sim.pid)
            simulated.formUnion(tree.map(\.pid))
            guard let udid = simulatorID(sim.arguments), !windowOpen, now.timeIntervalSince(sim.started) >= 30 * 60 else { continue }
            let signature = "simulator|\(udid)"
            guard !ignored.contains(signature) else { continue }
            let apps = Array(Set(processes.filter { $0.executable.contains("/Devices/\(udid)/data/Containers/Bundle/Application/") }
                .compactMap { appName($0.executable) })).sorted()
            let usage = total(tree)
            leftovers.append(Leftover(kind: .simulator, name: deviceName(udid) ?? "iOS Simulator",
                folder: apps.isEmpty ? "No apps running" : "Running " + apps.joined(separator: ", "),
                reason: "Booted \(duration(now.timeIntervalSince(sim.started))) ago with no Simulator window open.",
                started: sim.started, cpuPercent: usage.cpu, resident: usage.resident, children: tree.count - 1,
                target: .simulator(udid: udid), signature: signature))
        }

        var flagged: [Int: Leftover] = [:]
        for process in processes where !simulated.contains(process.pid) && !process.executable.isEmpty {
            guard !isApp(process.executable), !isSystem(process.executable), !process.executable.contains("/CoreSimulator/") else { continue }
            // Open agent CLIs are in use, not disposable; they are summarized separately.
            guard !services.contains(baseName(process.executable)), !isAgentCLI(process.executable) else { continue }
            let age = now.timeIntervalSince(process.started), percent = cpu[process.id]
            let kind: LeftoverKind, reason: String
            if let used = process.cpuTime, used >= 3600, let percent, percent >= 25 {
                kind = .runaway; reason = "Still using \(Int(percent.rounded()))% CPU after \(duration(used)) of CPU time."
            } else if isWatcher(process), process.listeningPorts.isEmpty, age >= 2 * 3600 {
                // Runners that serve clients (expo, vite) are judged as servers below instead.
                kind = .watcher; reason = "Running for \(duration(age)). Test runners and watchers normally stop when the work is done."
            } else if !process.listeningPorts.isEmpty, process.connections == 0, age >= 12 * 3600, !ownedByOpenParent(process) {
                kind = .devServer
                reason = "Listening on \(process.listeningPorts.prefix(3).map { ":\($0)" }.joined(separator: ", ")) with no open connections; up \(duration(age))."
            } else if isAgentScript(process), age >= 6 * 3600 {
                kind = .agentScript; reason = "Started from a coding agent's temporary folder \(duration(age)) ago."
            } else if process.parentPID == 1, age >= 3600 {
                kind = .orphan; reason = "The program that started it has exited, so nothing is waiting for it. Up \(duration(age))."
            } else { continue }
            let name = label(executable: process.executable, arguments: process.arguments)
            let folder = abbreviate(process.cwd, home: home)
            let signature = "\(kind.rawValue)|\(name)|\(folder)"
            guard !ignored.contains(signature) else { continue }
            flagged[process.pid] = Leftover(kind: kind, name: name, folder: folder, reason: reason, started: process.started,
                cpuTime: process.cpuTime, cpuPercent: percent, resident: process.resident, children: 0,
                target: .process(pid: process.pid, started: process.started, executable: process.executable), signature: signature)
        }
        // Workers and wrappers under a flagged process are reported as part of it.
        for pid in Array(flagged.keys) {
            var parent = byPID[pid]?.parentPID, hops = 0
            while let current = parent, current > 1, hops < 64 {
                if flagged[current] != nil { flagged[pid] = nil; break }
                parent = byPID[current]?.parentPID; hops += 1
            }
        }
        for (pid, var item) in flagged {
            let tree = descendants(of: pid)
            guard !tree.isEmpty, let root = byPID[pid] else { continue }
            let usage = total([root] + tree)
            item.cpuPercent = usage.cpu; item.resident = usage.resident; item.children = tree.count
            flagged[pid] = item
        }
        let order = Dictionary(uniqueKeysWithValues: LeftoverKind.allCases.enumerated().map { ($1, $0) })
        leftovers += flagged.values
        leftovers.sort { a, b in
            if a.kind != b.kind { return order[a.kind, default: 0] < order[b.kind, default: 0] }
            return (a.resident ?? 0) > (b.resident ?? 0)
        }

        let agentProcesses = processes.filter { isAgentCLI($0.executable) }
        // Name only the rows that are shown.
        let busiest = processes.filter { !simulated.contains($0.pid) }
            .sorted { a, b in
                let left = cpu[a.id] ?? -1, right = cpu[b.id] ?? -1
                if left != right { return left > right }
                return (a.resident ?? 0) > (b.resident ?? 0)
            }
            .prefix(6)
            .map { ProcessLine(id: $0.id, name: label(executable: $0.executable, arguments: $0.arguments), cpuPercent: cpu[$0.id], resident: $0.resident) }
        return LeftoverReport(leftovers: leftovers, busiest: Array(busiest), agentProcesses: agentProcesses.count,
            agentMemory: agentProcesses.compactMap(\.resident).reduce(0, +), complete: inventory.complete)
    }
    static func isAgentCLI(_ executable: String) -> Bool {
        executable.contains("/claude/versions/") || executable.hasSuffix("/claude.app/Contents/MacOS/claude") || agents.contains(baseName(executable))
    }

    /// A short display name built from the executable and, for interpreters, the script's file name only.
    public static func label(executable: String, arguments: [String]) -> String {
        if isApp(executable) { return appName(executable) ?? baseName(executable) }
        var base = baseName(executable)
        if executable.contains("/claude/versions/") || executable.hasSuffix("/claude.app/Contents/MacOS/claude") { return "claude" }
        if base.lowercased().hasPrefix("python") { base = "Python" }
        guard interpreters.contains(base) else { return base }
        if let runner = runner(arguments) { return "\(base) · \(runner)" }
        var rest = Array(arguments.dropFirst())
        while !rest.isEmpty {
            let argument = rest.removeFirst()
            switch argument {
            case "-": return "\(base) · stdin script"
            case "-c", "-e", "--eval": return "\(base) · inline command"
            case "-m": return rest.first.map { "\(base) · \(String($0.prefix(40)))" } ?? base
            default:
                if argument.hasPrefix("-") { continue }
                return "\(base) · \(String(baseName(argument).prefix(48)))"
            }
        }
        return base
    }
    static func runner(_ arguments: [String]) -> String? {
        if arguments.contains(where: { $0.hasSuffix("jest-worker/build/workers/processChild.js") }) { return "jest worker" }
        for argument in arguments.dropFirst().prefix(3) {
            var name = baseName(argument)
            for suffix in [".js", ".cjs", ".mjs", ".ts"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
            if runners.contains(name) { return name }
        }
        return nil
    }
    static func isWatcher(_ process: ProcessSample) -> Bool {
        let flags = process.arguments.dropFirst()
        if baseName(process.executable) == "tail" {
            return flags.contains("--follow") || flags.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && ($0.contains("f") || $0.contains("F")) }
        }
        return runner(process.arguments) != nil || flags.contains("--watch") || flags.contains("--watchAll")
    }
    static func isAgentScript(_ process: ProcessSample) -> Bool {
        // Shell wrappers around a running agent command are not leftovers by themselves.
        guard !process.arguments.contains(where: { $0.contains("/shell-snapshots/") }) else { return false }
        return process.arguments.dropFirst().contains { $0.contains("/tmp/claude-") } || process.cwd.contains("/tmp/claude-")
    }
    static func simulatorID(_ arguments: [String]) -> String? {
        for argument in arguments {
            guard let range = argument.range(of: "/Devices/") else { continue }
            let candidate = String(argument[range.upperBound...].prefix(36))
            if UUID(uuidString: candidate) != nil { return candidate.uppercased() }
        }
        return nil
    }
    public static func simulatorName(udid: String, home: String) -> String? {
        guard UUID(uuidString: udid) != nil else { return nil }
        let url = URL(fileURLWithPath: home).appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)/device.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["name"] as? String
    }
    /// The innermost bundle name; iOS apps are flat bundles without a Contents folder.
    static func appName(_ executable: String) -> String? {
        executable.split(separator: "/").last { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
    }
    /// The last path component without building a URL; this runs for every process on each sample.
    static func baseName(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
    static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
    public static func duration(_ seconds: TimeInterval) -> String {
        if seconds >= 2 * 86400 { return "\(Int(seconds / 86400)) days" }
        if seconds >= 3600 { return "\(Int(seconds / 3600)) h" }
        return "\(max(1, Int(seconds / 60))) min"
    }
}

public enum LeftoverActionResult: Sendable, Equatable {
    case done, changed, stillRunning, failed(String)
}

public enum LeftoverActions {
    /// Signals only the exact process Burro reported: same user, start time and executable.
    public static func stop(pid: Int, started: Date, executable: String, force: Bool) -> LeftoverActionResult {
        guard pid > 1, pid != Int(getpid()) else { return .failed("Burro cannot stop this process.") }
        guard isRunning(pid: pid, started: started, executable: executable) else { return .changed }
        guard kill(pid_t(pid), force ? SIGKILL : SIGTERM) == 0 else { return .failed(String(cString: strerror(errno))) }
        return .done
    }
    public static func isRunning(pid: Int, started: Date, executable: String) -> Bool {
        guard let current = identity(of: pid) else { return false }
        return current.started == started && current.executable == executable
    }
    /// The same-user identity a stop request is checked against, or nil when the process is gone or belongs to someone else.
    public static func identity(of pid: Int) -> (started: Date, executable: String)? {
        var info = BurroProcess()
        guard burro_process_info(Int32(pid), &info) == 1, info.uid == getuid() else { return nil }
        let path = withUnsafePointer(to: &info.executable) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
        return (Date(timeIntervalSince1970: Double(info.started)), path)
    }
    /// Shuts down one booted simulator through Xcode's own tool; the identifier is validated before use.
    public static func shutdownSimulator(_ udid: String) -> LeftoverActionResult {
        guard UUID(uuidString: udid) != nil else { return .failed("Invalid simulator identifier.") }
        let result = CommandRunner().run("/usr/bin/xcrun", ["simctl", "shutdown", udid], timeout: 60)
        if result.succeeded { return .done }
        let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(result.timedOut ? "Simulator shutdown timed out." : (message.isEmpty ? "Simulator shutdown failed." : message))
    }
}
