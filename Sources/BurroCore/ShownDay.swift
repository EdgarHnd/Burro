// Which day the Today page shows. It follows the calendar: left on today, it moves on to the new
// day at midnight; on a past day you picked, it stays there until you come back to today.
import Foundation

public struct ShownDay: Sendable, Equatable {
    /// Start of the day shown.
    public private(set) var day: Date
    /// The page is on today, so it moves on with the calendar.
    public private(set) var following: Bool

    public init(now: Date = Date(), calendar: Calendar = .current) {
        day = calendar.startOfDay(for: now)
        following = true
    }

    /// Shows `date`'s day, never later than today. Today follows the calendar again; a past day stays
    /// put. Returns whether the day changed.
    @discardableResult
    public mutating func show(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let today = calendar.startOfDay(for: now)
        let target = min(calendar.startOfDay(for: date), today)
        following = target == today
        guard target != day else { return false }
        day = target
        return true
    }

    /// Catches up with the calendar: a page that was on today moves to the new today, and a day later
    /// than today (the clock went back) becomes today. Returns whether the day changed.
    @discardableResult
    public mutating func update(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let today = calendar.startOfDay(for: now)
        guard (following && day != today) || day > today else { return false }
        day = today
        following = true
        return true
    }
}
