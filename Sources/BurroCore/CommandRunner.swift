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
    public init() {}
    public func run(_ executable: String, _ arguments: [String], timeout: Double = 20, input: Data? = nil) -> CommandResult {
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
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            try process.run()
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            func tooLarge(_ handle: FileHandle) -> Bool {
                var info = stat()
                return fstat(handle.fileDescriptor, &info) == 0 && info.st_size > 8 * 1024 * 1024
            }
            var outputExceeded = false
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                outputExceeded = tooLarge(out) || tooLarge(err)
                if outputExceeded { break }
                // Exit notifications return immediately, even for very short Git commands.
                // Only output bounds need a periodic check; avoid 40 filesystem polls/second.
                let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
                if exited.wait(timeout: .now() + min(0.25, remaining)) == .success { break }
            }
            let expired = process.isRunning && !outputExceeded
            if process.isRunning {
                process.terminate()
                _ = exited.wait(timeout: .now() + 0.25)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            func read(_ url: URL) -> String {
                guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
                defer { try? handle.close() }
                return String(decoding: (try? handle.read(upToCount: 8 * 1024 * 1024)) ?? Data(), as: UTF8.self)
            }
            if outputExceeded || tooLarge(out) || tooLarge(err) {
                return CommandResult(code: -2, output: "", error: "Command output exceeded the inspection limit", timedOut: expired)
            }
            return CommandResult(code: process.terminationStatus, output: read(outURL), error: read(errURL), timedOut: expired)
        } catch { return CommandResult(code: -1, output: "", error: error.localizedDescription, timedOut: false) }
    }
    public func git(_ path: String, _ arguments: [String], timeout: Double = 20) -> CommandResult {
        run("/usr/bin/git", ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", path] + arguments, timeout: timeout)
    }
}
