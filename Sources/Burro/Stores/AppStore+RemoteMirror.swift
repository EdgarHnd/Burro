// Keeps Burro's copies of remote transcripts within bounds: at launch and then hourly, copies not
// opened for 30 days are removed, then the least recently opened until all fit in 512 MB. A chat open
// on screen is never removed (`RemoteTranscriptMirror.Hold`). Runs off the main thread; logs nothing.
import Foundation
import BurroCore

extension AppStore {
    /// Starts the hourly sweep once per run.
    func startTranscriptMirrorSweeps() {
        guard TranscriptMirrorSweeps.start() else { return }
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                RemoteTranscriptMirror.shared.sweep()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }
}

private enum TranscriptMirrorSweeps {
    nonisolated(unsafe) private static var started = false
    private static let lock = NSLock()
    static func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if started { return false }
        started = true
        return true
    }
}
