// The Usage page's local token cards, all from this Mac's own logs and explicitly separate from
// subscription quotas and paid charges: today by project (Home's project activity: named projects,
// then "Other folders"), today by model (with the model of any low limit marked), and the last
// seven days as a strip. Each is a `Panel` cell of the page's joined surface. Costs are estimated API value at reference rates, never a bill; the
// caveats (priced coverage, partial scans, other accounts' logs, remote work, Grok) stay visible.
import SwiftUI
import BurroCore

/// A cell of the page's joined surface: a `Panel` with the quiet note as its subtitle.
private struct UsageSectionCard<Content: View>: View {
    var title: String
    var note: String?
    @ViewBuilder var content: () -> Content
    var body: some View {
        Panel(title: title, subtitle: note.map { [TextRun($0)] } ?? []) {
            VStack(alignment: .leading, spacing: 0) { content() }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Labelled bars: name, bar scaled to the largest row, tokens and estimated cost, then a total.
struct UsageBreakdownBars: View {
    var rows: [UsageBreakdownRow]
    /// Rows drawn amber (a model whose limit is low).
    var highlighted: Set<String> = []
    @State private var width: CGFloat = 400
    /// Below this the bar goes under the name, so a third-width panel never cuts the figures off.
    private static let narrowBelow: CGFloat = 380
    var body: some View {
        let largest = max(1, rows.map(\.tokens).max() ?? 1)
        let narrow = width < Self.narrowBelow
        VStack(spacing: 0) {
            ForEach(rows) { row in
                Group {
                    if narrow {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 10) { name(row).frame(maxWidth: .infinity, alignment: .leading); figures(row) }
                            bar(row, largest: largest)
                        }
                    } else {
                        HStack(spacing: 12) { name(row).frame(width: 150, alignment: .leading); bar(row, largest: largest); figures(row) }
                    }
                }
                .font(.system(size: 13)).monospacedDigit().padding(.vertical, 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.title), \(UsagePageText.tokens(row.tokens)) tokens, \(row.apiValue.map(UsagePageText.cost) ?? "no estimate")")
            }
            Rectangle().fill(AppAppearance.separator).frame(height: 1).padding(.top, 6)
            HStack(spacing: 12) {
                Text("Total")
                Spacer()
                Text(UsagePageText.tokens(rows.reduce(0) { $0 + $1.tokens })).frame(width: 56, alignment: .trailing)
                Text(UsagePageText.cost(rows.reduce(0) { $0 + ($1.apiValue ?? 0) })).frame(width: 64, alignment: .trailing)
            }.font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(AppAppearance.text).padding(.vertical, 7)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }
    private func name(_ row: UsageBreakdownRow) -> some View {
        Text(row.title).foregroundStyle(row.isRest ? AppAppearance.secondary : AppAppearance.text).lineLimit(1).truncationMode(.middle)
    }
    private func figures(_ row: UsageBreakdownRow) -> some View {
        HStack(spacing: 12) {
            Text(UsagePageText.tokens(row.tokens)).frame(width: 56, alignment: .trailing).foregroundStyle(AppAppearance.text)
            Text(row.apiValue.map(UsagePageText.cost) ?? "—").frame(width: 64, alignment: .trailing).foregroundStyle(AppAppearance.secondary)
        }
    }
    private func bar(_ row: UsageBreakdownRow, largest: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(AppAppearance.raised)
                Capsule().fill(highlighted.contains(row.id) ? AppAppearance.amber : (row.isRest ? AppAppearance.tertiary : AppAppearance.secondary))
                    .frame(width: max(4, geometry.size.width * row.tokens / largest))
            }
        }.frame(height: narrowBar ? 4 : 10)
    }
    private var narrowBar: Bool { width < Self.narrowBelow }
}

/// One stacked bar of today's models (each a share of the day's tokens, the low-limit one amber)
/// over a small table: a swatch, the model, tokens and estimated value, then the total.
struct UsageModelsTable: View {
    var rows: [UsageBreakdownRow]
    var highlighted: Set<String> = []
    var body: some View {
        let total = max(1, rows.reduce(0) { $0 + $1.tokens })
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                let gaps = CGFloat(max(0, rows.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        Rectangle().fill(color(row, index))
                            .frame(width: max(3, (geometry.size.width - gaps) * row.tokens / total))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 10).accessibilityHidden(true)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(color(row, index)).frame(width: 8, height: 8)
                        Text(row.title).foregroundStyle(row.isRest ? AppAppearance.secondary : AppAppearance.text)
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        Text(UsagePageText.tokens(row.tokens)).frame(width: 50, alignment: .trailing)
                        Text(row.apiValue.map(UsagePageText.cost) ?? "—").frame(width: 56, alignment: .trailing).foregroundStyle(AppAppearance.secondary)
                    }
                    .font(.system(size: 12.5)).monospacedDigit().padding(.vertical, 5)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.title), \(UsagePageText.tokens(row.tokens)) tokens, \(row.apiValue.map(UsagePageText.cost) ?? "no estimate")")
                }
                Rectangle().fill(AppAppearance.separator).frame(height: 1).padding(.top, 4)
                HStack(spacing: 8) {
                    Text("Total").frame(maxWidth: .infinity, alignment: .leading)
                    Text(UsagePageText.tokens(rows.reduce(0) { $0 + $1.tokens })).frame(width: 50, alignment: .trailing)
                    Text(UsagePageText.cost(rows.reduce(0) { $0 + ($1.apiValue ?? 0) })).frame(width: 56, alignment: .trailing)
                }.font(.system(size: 12.5, weight: .semibold)).monospacedDigit().foregroundStyle(AppAppearance.text).padding(.vertical, 6)
            }
        }
    }
    /// Greys from strong to faint by rank; a low-limit model amber.
    private func color(_ row: UsageBreakdownRow, _ index: Int) -> Color {
        if highlighted.contains(row.id) { return AppAppearance.amber }
        if row.isRest { return AppAppearance.raised }
        return AppAppearance.text.opacity([0.62, 0.42, 0.28, 0.18, 0.12][min(index, 4)])
    }
}

private struct UsageCardNote: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary).fixedSize(horizontal: false, vertical: true)
    }
}

struct UsageProjectsCard: View {
    var rows: [UsageBreakdownRow]?
    var partial: Bool
    var body: some View {
        UsageSectionCard(title: "Today by project", note: "tokens · est. cost") {
            if let rows, !rows.isEmpty {
                UsageBreakdownBars(rows: rows)
                UsageCardNote(text: (partial ? "Partial: a scan limit was reached or a provider didn’t answer. " : "")
                              + "This Mac’s Codex and Claude logs; work on other machines isn’t here.").padding(.top, 4)
            } else {
                UsageCardNote(text: rows == nil ? "Reading today’s logs on this Mac…" : "No local tokens yet today.")
                    .padding(.vertical, 8)
            }
        }
    }
}

struct UsageModelsCard: View {
    var week: UsageWeek?
    var scanning: Bool
    var alerts: [UsageAlert]
    var body: some View {
        UsageSectionCard(title: "Today by model", note: "tokens · est. cost") {
            if let week, !week.todayModels.isEmpty {
                let rows = Self.rows(week.todayModels)
                let low = Self.lowModels(week.todayModels, alerts: alerts)
                UsageModelsTable(rows: rows, highlighted: Set(rows.filter { row in low.contains { $0.title == row.title } }.map(\.id)))
                if let first = low.first, let today = week.today, today.tokens > 0 {
                    let share = Int((first.tokens / today.tokens * 100).rounded())
                    UsageCardNote(text: "\(UsageWeek.modelTitle(first.model)) is \(share)% of today’s tokens and has a low limit.").padding(.top, 4)
                }
            } else {
                UsageCardNote(text: week == nil ? (scanning ? "Reading today’s logs on this Mac…" : "Local token figures are unavailable: Burro’s usage reader isn’t running.")
                              : "No local tokens yet today.").padding(.vertical, 8)
            }
        }
    }
    /// The five largest models, then the rest as "Other models".
    static func rows(_ models: [UsageWeek.Model]) -> [UsageBreakdownRow] {
        var rows = models.prefix(5).map { UsageBreakdownRow(title: $0.title, tokens: $0.tokens, apiValue: $0.apiValue) }
        let rest = models.dropFirst(5)
        if !rest.isEmpty {
            rows.append(UsageBreakdownRow(title: "Other models", tokens: rest.reduce(0) { $0 + $1.tokens },
                                          apiValue: rest.reduce(0) { $0 + ($1.apiValue ?? 0) }, isRest: true))
        }
        return rows
    }
    /// Today's models whose own limit (a per-model window such as Fable weekly) is low.
    static func lowModels(_ models: [UsageWeek.Model], alerts: [UsageAlert]) -> [UsageWeek.Model] {
        models.filter { model in
            alerts.contains { alert in
                guard let name = alert.model?.lowercased(), !name.isEmpty, alert.provider == model.provider else { return false }
                return UsageWeek.modelTitle(model.model).lowercased().hasPrefix(name) || model.model.lowercased().contains(name)
            }
        }
    }
}

struct UsageWeekCard: View {
    var week: UsageWeek?
    var scanning: Bool
    var calendar: Calendar
    var body: some View {
        UsageSectionCard(title: "Last 7 days", note: week.map { week in
            "\(UsagePageText.tokens(week.tokens)) tokens" + (week.pricedRecords > 0 ? " · about \(UsagePageText.cost(week.apiValue))" : "")
        }) {
            if let week {
                strip(week)
                VStack(alignment: .leading, spacing: 6) {
                    if week.partial {
                        Label("Partial history: the scan reached a file, size, or time limit, or a provider didn’t answer.", systemImage: "info.circle")
                            .font(.system(size: 11.5)).foregroundStyle(AppAppearance.secondary)
                    }
                    UsageCardNote(text: "Reference API value, not your bill. Standard short-context rates, checked Sep 29, 2026; excludes tool fees, tier/context premiums and unknown models. Priced \(week.pricedRecords) of \(week.records) records. Logs may include multiple accounts and exclude remote work. Grok isn’t counted: it reports only cumulative session tokens.")
                    HStack(spacing: 14) {
                        Link("Claude pricing ↗", destination: URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!)
                        Link("OpenAI pricing ↗", destination: URL(string: "https://developers.openai.com/api/docs/pricing")!)
                    }.font(.system(size: 11.5))
                }.padding(.top, 12)
            } else {
                UsageCardNote(text: scanning ? "Reading the last seven days of logs on this Mac…" : "Local token figures are unavailable: Burro’s usage reader isn’t running.")
                    .padding(.vertical, 8)
            }
        }
    }

    private func strip(_ week: UsageWeek) -> some View {
        let largest = max(1, week.days.map(\.tokens).max() ?? 1)
        return VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(week.days) { day in
                    let today = day.id == week.days.last?.id
                    VStack(spacing: 6) {
                        Text(day.tokens > 0 ? UsagePageText.tokens(day.tokens) : "—").font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(today ? AppAppearance.text : AppAppearance.tertiary)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(today ? AppAppearance.secondary : AppAppearance.hairline)
                            .frame(height: max(3, 96 * day.tokens / largest))
                    }.frame(maxWidth: .infinity)
                }
            }.frame(height: 120, alignment: .bottom)
            HStack(spacing: 10) {
                ForEach(week.days) { day in
                    let today = day.id == week.days.last?.id
                    Text(today ? "Today" : weekday(day.date)).font(.system(size: 12))
                        .foregroundStyle(today ? AppAppearance.text : AppAppearance.tertiary).frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily tokens, last seven days")
        .accessibilityValue(week.days.map { "\(weekday($0.date)) \(UsagePageText.tokens($0.tokens))" }.joined(separator: ", "))
    }

    private func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: date)
    }
}
