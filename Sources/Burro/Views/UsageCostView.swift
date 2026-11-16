// The Usage page's local token cards, all from this Mac's own logs and explicitly separate from
// subscription quotas and paid charges: today by project (Home's project activity: named projects,
// then "Other folders"), today by model (with the model of any low limit marked), and the last
// seven days as a strip. Costs are estimated API value at reference rates, never a bill; the
// caveats (priced coverage, partial scans, other accounts' logs, remote work, Grok) stay visible.
import SwiftUI
import BurroCore

/// A card with an uppercase section title and a quiet note on the right.
private struct UsageSectionCard<Content: View>: View {
    var title: String
    var note: String?
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
                Spacer()
                if let note { Text(note).font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary) }
            }.padding(.bottom, 8)
            content()
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(AppCardSurface())
    }
}

/// Labelled bars: name, bar scaled to the largest row, tokens and estimated cost, then a total.
struct UsageBreakdownBars: View {
    var rows: [UsageBreakdownRow]
    /// Rows drawn amber (a model whose limit is low).
    var highlighted: Set<String> = []
    var body: some View {
        let largest = max(1, rows.map(\.tokens).max() ?? 1)
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HStack(spacing: 12) {
                    Text(row.title).font(.system(size: 13)).foregroundStyle(row.isRest ? AppAppearance.secondary : AppAppearance.text)
                        .lineLimit(1).truncationMode(.middle).frame(width: 150, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(AppAppearance.raised)
                            Capsule().fill(highlighted.contains(row.id) ? AppAppearance.amber : (row.isRest ? AppAppearance.tertiary : AppAppearance.secondary))
                                .frame(width: max(4, geometry.size.width * row.tokens / largest))
                        }
                    }.frame(height: 10)
                    Text(UsagePageText.tokens(row.tokens)).frame(width: 56, alignment: .trailing).foregroundStyle(AppAppearance.text)
                    Text(row.apiValue.map(UsagePageText.cost) ?? "—").frame(width: 64, alignment: .trailing).foregroundStyle(AppAppearance.secondary)
                }
                .font(.system(size: 13)).monospacedDigit().padding(.vertical, 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.title), \(UsagePageText.tokens(row.tokens)) tokens, \(row.apiValue.map(UsagePageText.cost) ?? "no estimate")")
            }
            Rectangle().fill(AppAppearance.separator).frame(height: 1).padding(.top, 6)
            HStack(spacing: 12) {
                Text("Total").frame(width: 150, alignment: .leading)
                Spacer()
                Text(UsagePageText.tokens(rows.reduce(0) { $0 + $1.tokens })).frame(width: 56, alignment: .trailing)
                Text(UsagePageText.cost(rows.reduce(0) { $0 + ($1.apiValue ?? 0) })).frame(width: 64, alignment: .trailing)
            }.font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(AppAppearance.text).padding(.vertical, 7)
        }
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
                UsageBreakdownBars(rows: rows, highlighted: Set(rows.filter { row in low.contains { $0.title == row.title } }.map(\.id)))
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
