// Whether you're at the Mac, judged only by input: a stretch without a key press, click, scroll or
// mouse move (2 minutes by default; 5 or 10 with the `activity.idleAfter` preference) means away,
// and the first input after that means back. Changing the threshold applies at the next check. Nothing else ends idleness, so
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

    /// The thresholds you can pick, in seconds: 2, 5 or 10 minutes.
    public static let idleChoices: [TimeInterval] = [120, 300, 600]
    public static let defaultIdleAfter: TimeInterval = 120

    /// The `activity.idleAfter` preference as a threshold: seconds (120, 300, 600) or minutes (2, 5,
    /// 10), snapped to the nearest choice; anything else, or nothing, is the default.
    public static func idleAfter(preference value: Any?) -> TimeInterval {
        let number: Double?
        switch value {
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): number = n.doubleValue
        case let text as String: number = Double(text.trimmingCharacters(in: .whitespaces))
        default: number = nil
        }
        guard let number, number.isFinite, number > 0 else { return defaultIdleAfter }
        let seconds = number <= 10 ? number * 60 : number
        return idleChoices.min { abs($0 - seconds) < abs($1 - seconds) } ?? defaultIdleAfter
    }

    /// Takes effect at the next `update`.
    public var idleAfter: TimeInterval
    public private(set) var idle = false

    public init(idleAfter: TimeInterval = ActivityPresence.defaultIdleAfter) { self.idleAfter = idleAfter }

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
