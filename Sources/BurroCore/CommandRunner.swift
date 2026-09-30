// Run fixed executables without a shell, with bounded output and a hard timeout.
import Foundation
import Darwin

public struct CommandResult: Sendable {
    public var code: Int32
    public var output: String
    public var error: String
    public var timedOut: Bool
    public var succeeded: Bool { code == 0 && !timedOut }
}
public struct CommandRunner: Sendable {
    private let deadline: Date?
    public init(deadline: Date? = nil) { self.deadline = deadline }
    public func run(_ executable: String, _ arguments: [String], timeout: Double = 20, input: Data? = nil) -> CommandResult {
        let timeout = min(timeout, deadline?.timeIntervalSinceNow ?? timeout)
        guard timeout > 0 else { return CommandResult(code: -1, output: "", error: "Inspection timed out", timedOut: true) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let outURL = folder.appendingPathComponent("out"), errURL = folder.appendingPathComponent("err")
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            FileManager.default.createFile(atPath: errURL.path, contents: nil)
            let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
            defer { try? out.close(); try? err.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardOutput = out; process.standardError = err
            var inputHandle: FileHandle?
            if let input {
                let inputURL = folder.appendingPathComponent("input")
                try input.write(to: inputURL)
                inputHandle = try FileHandle(forReadingFrom: inputURL)
            }
            defer { try? inputHandle?.close() }
            process.standardInput = inputHandle ?? FileHandle.nullDevice
            process.currentDirectoryURL = URL(fileURLWithPath: "/")
            var env = ProcessInfo.processInfo.environment
            // Do not inherit a surrounding agent's Git repository/index overrides.
            for key in env.keys where key.hasPrefix("GIT_") { env.removeValue(forKey: key) }
            env["GIT_OPTIONAL_LOCKS"] = "0"; env["GIT_TERMINAL_PROMPT"] = "0"; env["LC_ALL"] = "C"
            process.environment = env
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            var outputExceeded = false
            while process.isRunning && Date() < deadline {
                outputExceeded = [outURL, errURL].contains { url in
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
                    return (size?.intValue ?? 0) > 8 * 1024 * 1024
                }
                if outputExceeded { break }
                Thread.sleep(forTimeInterval: 0.025)
            }
            let expired = process.isRunning && !outputExceeded
            if process.isRunning {
                process.terminate()
                let grace = Date().addingTimeInterval(0.25)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            func read(_ url: URL) -> String {
                guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
                defer { try? handle.close() }
                return String(decoding: (try? handle.read(upToCount: 8 * 1024 * 1024)) ?? Data(), as: UTF8.self)
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size]) as? NSNumber
            if outputExceeded || (size?.intValue ?? 0) > 8 * 1024 * 1024 {
                return CommandResult(code: -2, output: "", error: "Command output exceeded the inspection limit", timedOut: expired)
            }
            return CommandResult(code: process.terminationStatus, output: read(outURL), error: read(errURL), timedOut: expired)
        } catch { return CommandResult(code: -1, output: "", error: error.localizedDescription, timedOut: false) }
    }
    public func git(_ path: String, _ arguments: [String], timeout: Double = 20) -> CommandResult {
        run("/usr/bin/git", ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", path] + arguments, timeout: timeout)
    }
}
