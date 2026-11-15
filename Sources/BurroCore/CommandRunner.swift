// Run fixed executables without a shell, with bounded output and a hard timeout.
// Waiting is event-driven: the child's exit, the deadline and output growth each wake a private
// serial queue, so nothing polls. The async form never holds a Swift concurrency thread while the
// child runs (and stops the child if its task is cancelled); the synchronous form blocks only its caller.
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
    /// Output beyond this (either stream) stops the command and returns code -2.
    static let outputLimit: Int64 = 8 * 1024 * 1024
    public init() {}
    public func run(_ executable: String, _ arguments: [String], timeout: Double = 20, input: Data? = nil) -> CommandResult {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        CommandExecution.start(executable, arguments, timeout: timeout, input: input) { box.value = $0; done.signal() }
        done.wait()
        return box.value ?? CommandResult(code: -1, output: "", error: "The command did not report a result", timedOut: false)
    }
    /// Same as `run`, awaiting the child's exit instead of blocking a thread.
    public func run(_ executable: String, _ arguments: [String], timeout: Double = 20, input: Data? = nil) async -> CommandResult {
        let execution = CommandExecution.Handle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CommandResult, Never>) in
                execution.attach(CommandExecution.start(executable, arguments, timeout: timeout, input: input) { continuation.resume(returning: $0) })
            }
        } onCancel: { execution.cancel() }
    }
    public func git(_ path: String, _ arguments: [String], timeout: Double = 20) -> CommandResult {
        // Git's index preload starts up to 20 threads per status. With several worktrees scanned
        // at once they only contend in the kernel: the same answer for several times the CPU.
        run("/usr/bin/git", ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.preloadIndex=false", "-C", path] + arguments, timeout: timeout)
    }
}

private final class ResultBox: @unchecked Sendable { var value: CommandResult? }

/// One child process. All state is touched only on `queue`, except the exit semaphore.
final class CommandExecution: @unchecked Sendable {
    enum Stop { case exited, timedOut, tooLarge, cancelled }

    /// Lets a cancellation that arrives before (or after) the process starts reach it.
    final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var execution: CommandExecution?
        private var cancelled = false
        func attach(_ execution: CommandExecution?) {
            lock.lock(); self.execution = execution; let cancelled = cancelled; lock.unlock()
            if cancelled { execution?.cancel() }
        }
        func cancel() {
            lock.lock(); cancelled = true; let execution = execution; lock.unlock()
            execution?.cancel()
        }
    }

    private let queue = DispatchQueue(label: "app.burro.command", qos: .utility)
    private let process = Process()
    private let exited = DispatchSemaphore(value: 0)
    private let folder: URL
    private let outURL: URL, errURL: URL
    private var out: FileHandle?, err: FileHandle?, inputHandle: FileHandle?
    private var sources: [DispatchSourceProtocol] = []
    private var completion: (@Sendable (CommandResult) -> Void)?
    private var finished = false

    private init(folder: URL, completion: @escaping @Sendable (CommandResult) -> Void) {
        self.folder = folder
        outURL = folder.appendingPathComponent("out"); errURL = folder.appendingPathComponent("err")
        self.completion = completion
    }

    /// Starts the child; `completion` is called exactly once, on a private queue.
    @discardableResult
    static func start(_ executable: String, _ arguments: [String], timeout: Double, input: Data?,
                      completion: @escaping @Sendable (CommandResult) -> Void) -> CommandExecution? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-\(UUID().uuidString)")
        let execution = CommandExecution(folder: folder, completion: completion)
        do {
            try execution.launch(executable, arguments, timeout: timeout, input: input)
            return execution
        } catch {
            execution.cleanUp()
            completion(CommandResult(code: -1, output: "", error: error.localizedDescription, timedOut: false))
            return nil
        }
    }

    private func launch(_ executable: String, _ arguments: [String], timeout: Double, input: Data?) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        self.out = out; self.err = err
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = out; process.standardError = err
        if let input {
            let inputURL = folder.appendingPathComponent("input")
            try input.write(to: inputURL)
            inputHandle = try FileHandle(forReadingFrom: inputURL)
        }
        process.standardInput = inputHandle ?? FileHandle.nullDevice
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        var env = ProcessInfo.processInfo.environment
        // Do not inherit a surrounding agent's Git repository/index overrides.
        for key in env.keys where key.hasPrefix("GIT_") { env.removeValue(forKey: key) }
        env["GIT_OPTIONAL_LOCKS"] = "0"; env["GIT_TERMINAL_PROMPT"] = "0"; env["LC_ALL"] = "C"
        process.environment = env
        // The handlers below hold this object until `finish` releases them.
        process.terminationHandler = { [exited, queue] _ in
            exited.signal()
            queue.async { self.finish(.exited) }
        }
        // Starting on the queue means the exit, the deadline and output growth are all handled after this block.
        try queue.sync {
            try process.run()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + max(0, timeout))
            timer.setEventHandler { self.finish(.timedOut) }
            sources.append(timer)
            for handle in [out, err] {
                // Output files grow only through writes, so a vnode event is the moment to check the bound.
                let growth = DispatchSource.makeFileSystemObjectSource(fileDescriptor: handle.fileDescriptor, eventMask: [.write, .extend], queue: queue)
                growth.setEventHandler { if self.tooLarge() { self.finish(.tooLarge) } }
                sources.append(growth)
            }
            sources.forEach { $0.resume() }
        }
    }

    func cancel() { queue.async { self.finish(.cancelled) } }

    private func tooLarge() -> Bool {
        func large(_ handle: FileHandle?) -> Bool {
            guard let handle else { return false }
            var info = stat()
            return fstat(handle.fileDescriptor, &info) == 0 && info.st_size > CommandRunner.outputLimit
        }
        return large(out) || large(err)
    }

    /// Runs once on `queue`: stops the child if it is still running, reads its output and reports.
    private func finish(_ reason: Stop) {
        guard !finished else { return }
        finished = true
        for source in sources { source.cancel() }
        sources = []
        // The deadline or a write may race the exit notification: judge by whether the child is still running.
        let stillRunning = process.isRunning
        if stillRunning {
            process.terminate()
            if exited.wait(timeout: .now() + 0.25) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        } else {
            process.waitUntilExit()
        }
        process.terminationHandler = nil
        let expired = stillRunning && reason == .timedOut
        let result: CommandResult
        if reason == .cancelled && stillRunning {
            result = CommandResult(code: -3, output: "", error: "The command was cancelled", timedOut: false)
        } else if reason == .tooLarge || tooLarge() {
            result = CommandResult(code: -2, output: "", error: "Command output exceeded the inspection limit", timedOut: expired)
        } else {
            result = CommandResult(code: process.terminationStatus, output: read(outURL), error: read(errURL), timedOut: expired)
        }
        let completion = self.completion
        self.completion = nil
        cleanUp()
        completion?(result)
    }

    private func read(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        return String(decoding: (try? handle.read(upToCount: Int(CommandRunner.outputLimit))) ?? Data(), as: UTF8.self)
    }

    private func cleanUp() {
        process.terminationHandler = nil
        try? out?.close(); try? err?.close(); try? inputHandle?.close()
        out = nil; err = nil; inputHandle = nil
        try? FileManager.default.removeItem(at: folder)
    }
}
