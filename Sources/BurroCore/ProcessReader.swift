// Match live process identities and working directories, excluding this observer and its children.
import Foundation
import CSystem
import Darwin

public struct ProcessSnapshot: Sendable {
    public var processes: [LocalProcess]
    public var warnings: [String]
}
public enum ProcessReader {
    static func isCurrent(_ process: LocalProcess) -> Bool {
        var info = BurroProcess()
        return burro_process_info(Int32(process.pid), &info) == 1 && info.uid == getuid()
            && Double(info.started) == process.started.timeIntervalSince1970
            && (process.parentPID == nil || Int(info.ppid) == process.parentPID)
    }
    public static func snapshot() -> ProcessSnapshot {
        let count = burro_list_pids(nil, 0)
        guard count > 0 else { return ProcessSnapshot(processes: [], warnings: ["Local processes could not be inspected"]) }
        var pids = [Int32](repeating: 0, count: Int(count) + 1024)
        let found = pids.withUnsafeMutableBufferPointer { burro_list_pids($0.baseAddress, Int32($0.count)) }
        guard found > 0, found < pids.count else { return ProcessSnapshot(processes: [], warnings: ["Process listing was incomplete"]) }
        var values: [(LocalProcess, Int)] = []; var deniedAgent = false
        var canonical = SnapshotPaths()
        for pid in pids.prefix(Int(found)) where pid > 0 {
            var info = BurroProcess()
            guard burro_process_info(pid, &info) == 1, info.uid == getuid() else { continue }
            let path = withUnsafePointer(to: &info.executable) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            let name = path.contains("/claude/versions/") ? "claude" : URL(fileURLWithPath: path).lastPathComponent
            if info.cwd_readable == 0 && ["codex", "claude"].contains(name) { deniedAgent = true }
            let cwd = withUnsafePointer(to: &info.cwd) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            values.append((LocalProcess(pid: Int(pid), name: name, cwd: cwd.isEmpty ? "" : canonical.canonical(cwd), started: Date(timeIntervalSince1970: Double(info.started)), parentPID: Int(info.ppid)), Int(info.ppid)))
        }
        var excluded: Set<Int> = [Int(getpid())]
        var previous = 0
        while previous != excluded.count {
            previous = excluded.count
            for (value, parent) in values where excluded.contains(parent) { excluded.insert(value.pid) }
        }
        var warnings: [String] = []
        if values.isEmpty { warnings.append("No local process identities could be read") }
        if deniedAgent { warnings.append("An agent process has an unreadable working directory") }
        return ProcessSnapshot(processes: values.map(\.0).filter { !excluded.contains($0.pid) }, warnings: warnings)
    }
}
