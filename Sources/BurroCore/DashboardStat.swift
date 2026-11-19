// One cell of a dashboard page's number strip as plain values, for the pages that adopted Today's
// layout after it (Mac Health, Worktrees, Usage): a label, the big value ("—" when unknown), one
// sub-line of toned runs (one fact, so it never truncates), an optional quiet footnote line and the
// help text. Today and Home keep their own `TodayStat`; the view maps either onto `StatCellData`.
import Foundation

public struct DashboardStat: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var value: String
    public var sub: [TextRun]
    public var help: String
    /// An amber dot before the label (only for something that needs you now).
    public var dot = false
    /// A second quiet line under the sub-line (a unit, "of 36 GB used").
    public var footnote: String? = nil
    /// The value drawn amber (Worktrees' uncommitted work, as before).
    public var warning = false

    public init(id: String, label: String, value: String, sub: [TextRun], help: String, dot: Bool = false,
                footnote: String? = nil, warning: Bool = false) {
        self.id = id; self.label = label; self.value = value; self.sub = sub; self.help = help
        self.dot = dot; self.footnote = footnote; self.warning = warning
    }

    /// No number to show.
    public var unknown: Bool { value == "—" }
}
