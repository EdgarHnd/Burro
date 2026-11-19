// `DashboardStat` (BurroCore's plain strip cell) as a `StatCellData`: the amber dot for something
// that needs you now, the value amber for a page's existing warning, "—" drawn grey, and the
// footnote as a quiet second line. Used by the pages that came after Today (Machines, the
// Orchestrator); a page adds its own accessory or footer after mapping.
import SwiftUI
import BurroCore

extension StatCellData {
    init(_ stat: DashboardStat) {
        self.init(id: stat.id, label: stat.label, dot: stat.dot ? AppAppearance.amber : nil, value: stat.value, muted: stat.unknown,
                  valueColor: stat.warning ? AppAppearance.amber : nil, sub: stat.sub, help: stat.help)
        if let footnote = stat.footnote {
            footer = AnyView(Text(footnote).font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.tertiary).lineLimit(1))
        }
    }
}
