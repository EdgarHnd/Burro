// The Timeline page: how the main project evolved, from the Shipped summaries Burro keeps.
// Months newest first, each with its counts and a few written lines per person, then its weeks:
// a small monochrome day grid (darker = more merged; click a day to open it on Today) beside
// the week's own summary. Built from the summary cache only; no GitHub reads here.
import SwiftUI
import BurroCore

struct ShippedTimelineView: View {
    @Bindable var store: AppStore
    private var shipped: ShippedStore { store.shipped }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 34) {
                header
                if shipped.timeline.isEmpty {
                    HomeEmptyCard(symbol: "chart.bar.doc.horizontal", title: shipped.repository == nil ? "Open Today first" : "Nothing recorded yet",
                                  detail: shipped.repository == nil
                                    ? "The Timeline is built from the Shipped summaries. Open Today once so Burro knows the main project's repository."
                                    : "Days appear here as Shipped reads them. To fill in the past, run burro-inspect --shipped-backfill <owner/name>.") { EmptyView() }
                }
                ForEach(shipped.timeline, id: \.self) { month in
                    MonthSection(store: store, month: month)
                        .onAppear { shipped.summarize(month) }
                }
            }
            .padding(.horizontal, 36).padding(.vertical, 28)
            .frame(maxWidth: 980, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(AppAppearance.background)
        .task(id: shipped.repository ?? "") { shipped.refreshTimeline() }
        .task(id: store.mainProject?.path ?? "") {
            // The repository is learned by reading a day; do that if Today hasn't yet.
            if shipped.repository == nil { shipped.refresh(Date()) }
        }
    }

    private var header: some View {
        let months = shipped.timeline.compactMap { shipped.period($0) }
        let merged = months.reduce(0) { $0 + $1.report.mergedCount }
        // Days something reached production: early on that meant pushing straight to main, so
        // counting releases one by one would count every push.
        let productionDays = months.reduce(0) { $0 + $1.report.productionDays }
        let first = months.last?.report.days.first { $0.digest != nil }?.day
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("TIMELINE").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
                if let repository = shipped.repository {
                    Text(repository.split(separator: "/").last.map(String.init) ?? repository)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(AppAppearance.tertiary)
                }
            }
            Text("How the project evolved").font(.system(size: 26, weight: .semibold)).foregroundStyle(AppAppearance.text)
            if let first {
                Text("Since \(first.formatted(.dateTime.day().month(.wide).year())) · \(merged.formatted()) pull requests merged into staging · production on \(ShippedDay.count(productionDays, "day"))")
                    .font(.system(size: 13)).monospacedDigit().foregroundStyle(AppAppearance.secondary)
            }
        }
    }
}

/// One month: name and stat pills, its highlights as bullets, a lane of its weeks, then each week.
private struct MonthSection: View {
    @Bindable var store: AppStore
    var month: ShippedPeriod

    var body: some View {
        let shipped = store.shipped
        let state = shipped.period(month)
        let report = state?.report
        // A week belongs to the month its Thursday falls in, so each appears once.
        let weeks = month.weeks().filter { month.contains(Calendar.current.date(byAdding: .day, value: 3, to: $0.start) ?? $0.start) }
            .filter { $0.start <= Date() }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(month.start.formatted(.dateTime.month(.wide).year())).font(.system(size: 19, weight: .semibold))
                if !month.isClosed() { Text("so far").font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary) }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    if let report, !report.isEmpty {
                        HStack(spacing: 6) {
                            StatPill(text: "\(report.mergedCount.formatted()) merged")
                            if report.productionDays > 0 { StatPill(text: "production on \(ShippedDay.count(report.productionDays, "day"))") }
                            let people = report.tallies.filter { $0.merged > 0 }.prefix(3).map { "\($0.person.name) \($0.merged)" }
                            if !people.isEmpty { StatPill(text: people.joined(separator: " · ")) }
                        }
                    }
                    Highlights(summary: state?.summary, empty: report?.isEmpty == true ? "Nothing reached GitHub this month." : nil, tag: false)
                    if weeks.count > 1, let report, !report.isEmpty {
                        WeekLane(weeks: weeks, reports: weeks.map { shipped.period($0)?.report })
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(weeks.reversed(), id: \.self) { week in
                    Divider().overlay(AppAppearance.separator)
                    WeekRow(store: store, week: week)
                }
            }
            .modifier(AppCardSurface(radius: HomeStyle.cardRadius))
        }
    }
}

private struct StatPill: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 11.5, weight: .medium)).monospacedDigit().foregroundStyle(AppAppearance.secondary)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(AppAppearance.separator))
    }
}

/// A brief's themes as bullets (bold area for a month, a tag for a week) and its production line;
/// an older plain summary as it is; or where it stands.
private struct Highlights: View {
    var summary: ShippedStore.Summary?
    var empty: String?
    var tag: Bool
    var body: some View {
        if let text = summary?.text, let brief = ShippedBrief(json: text) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(brief.themes.enumerated()), id: \.offset) { _, theme in
                    if tag {
                        BriefBullet(theme: theme)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Circle().fill(AppAppearance.tertiary).frame(width: 3.5, height: 3.5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                            (Text(theme.area.map { $0 + "  " } ?? "").fontWeight(.semibold).foregroundStyle(AppAppearance.text)
                                + Text(theme.text).foregroundStyle(AppAppearance.text.opacity(0.85)))
                                .font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let production = brief.production {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "flag").font(.system(size: 10, weight: .medium))
                        Text(production).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).padding(.top, 2)
                }
            }
            .opacity(summary?.current == true ? 1 : 0.55)
        } else if let summary, summary.text != nil {
            ShippedSummaryText(summary: summary)
        } else if let empty {
            Text(empty).font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary)
        } else {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Writing…") }
                .font(.system(size: 12.5)).foregroundStyle(AppAppearance.tertiary)
        }
    }
}

/// The month's weeks in a row, shaded by how much merged, with a dot per production day.
private struct WeekLane: View {
    var weeks: [ShippedPeriod]
    var reports: [ShippedPeriodReport?]
    var body: some View {
        let most = max(1, reports.compactMap { $0?.mergedCount }.max() ?? 1)
        HStack(spacing: 5) {
            ForEach(Array(weeks.enumerated()), id: \.element) { index, week in
                let report = reports[index]
                let merged = report?.mergedCount ?? 0
                let strength = 0.08 + 0.62 * Double(merged) / Double(most)
                VStack(alignment: .leading, spacing: 4) {
                    Text(week.start.formatted(.dateTime.day().month(.abbreviated)) + (merged > 0 ? " · \(merged)" : ""))
                        .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(strength > 0.45 ? AppAppearance.background : AppAppearance.text)
                        .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                        .background(AppAppearance.text.opacity(strength), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    HStack(spacing: 3) {
                        ForEach(0..<(report?.productionDays ?? 0), id: \.self) { _ in Circle().fill(AppAppearance.secondary).frame(width: 4, height: 4) }
                    }
                    .frame(height: 4)
                }
                .help("Week of \(week.start.formatted(.dateTime.day().month(.wide))) · \(merged) merged" + ((report?.productionDays ?? 0) > 0 ? " · production on \(ShippedDay.count(report!.productionDays, "day"))" : ""))
            }
        }
    }
}

/// One week: dates and total with a bar per day (click to open it), then three tagged bullets.
private struct WeekRow: View {
    @Bindable var store: AppStore
    var week: ShippedPeriod

    var body: some View {
        let state = store.shipped.period(week)
        let report = state?.report
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(week.start.formatted(.dateTime.day().month(.abbreviated)) + " – "
                     + (Calendar.current.date(byAdding: .day, value: -1, to: week.end) ?? week.end).formatted(.dateTime.day().month(.abbreviated)))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(AppAppearance.text)
                if let report, !report.isEmpty {
                    Text("\(report.mergedCount) merged" + (report.productionDays > 0 ? " · prod \(report.productionDays)d" : ""))
                        .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                }
                DayBars(week: week, report: report) { day in
                    store.today.show(day)
                    store.page = .today
                }
            }
            .frame(width: 150, alignment: .leading)
            Highlights(summary: state?.summary, empty: report?.isEmpty == true ? "Nothing reached GitHub." : nil, tag: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}

/// Seven bars, Monday to Sunday: height for how much merged, a dot under days something went to
/// production, an outline for days not read or still to come. Click a day to open it on Today.
private struct DayBars: View {
    var week: ShippedPeriod
    var report: ShippedPeriodReport?
    var open: (Date) -> Void

    var body: some View {
        let digests = Dictionary((report?.days ?? []).map { ($0.day, $0.digest) }, uniquingKeysWith: { first, _ in first })
        let most = max(8, digests.values.compactMap { $0?.merged.count }.max() ?? 8)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(week.days(), id: \.self) { day in
                let digest = digests[day] ?? nil
                let merged = digest?.merged.count ?? 0
                Button { open(day) } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2.5).fill(AppAppearance.text.opacity(0.06)).frame(width: 13, height: 30)
                            if digest != nil {
                                RoundedRectangle(cornerRadius: 2.5).fill(AppAppearance.text.opacity(merged > 0 ? 0.62 : 0.12))
                                    .frame(width: 13, height: max(2, 30 * CGFloat(merged) / CGFloat(most)))
                            }
                        }
                        Circle().fill(AppAppearance.secondary).frame(width: 3, height: 3).opacity((digest?.shippedCount ?? 0) > 0 ? 1 : 0)
                        Text(day.formatted(.dateTime.weekday(.narrow))).font(.system(size: 9)).foregroundStyle(AppAppearance.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(day > Date())
                .help(Self.help(day, digest))
            }
        }
    }

    static func help(_ day: Date, _ digest: ShippedDigest?) -> String {
        let date = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        guard let digest else { return day > Date() ? date : "\(date) · not read yet" }
        return "\(date) · \(ShippedPeriodReport.counts(digest))"
    }
}
