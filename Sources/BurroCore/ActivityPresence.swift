// Whether you're at the Mac, judged only by input: two minutes without a key press, click, scroll or
// mouse move means away, and the first input after that means back. Nothing else ends idleness, so
// an agent switching apps while you're away is not counted as you. Both changes are dated from the
// last input, which may be well before the moment they're noticed.
import Foundation

public struct ActivityPresence: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        /// Away since the last input.
        case away(since: Date)
        /// Back since the latest input.
        case back(since: Date)
    }

    public let idleAfter: TimeInterval
    public private(set) var idle = false

    public init(idleAfter: TimeInterval = 120) { self.idleAfter = idleAfter }

    /// Starts over from how long input has been quiet (tracking began, or the Mac woke or unlocked), without a change to report.
    public mutating func reset(quiet: TimeInterval) { idle = quiet >= idleAfter }

    /// `quiet` is the seconds since the last input, measured at `now`.
    public mutating func update(quiet: TimeInterval, at now: Date) -> Change? {
        let since = now.addingTimeInterval(-max(0, quiet))
        if !idle && quiet >= idleAfter {
            idle = true
            return .away(since: since)
        }
        if idle && quiet < idleAfter {
            idle = false
            return .back(since: since)
        }
        return nil
    }
}
