// The Today page's Shipped section: what reached GitHub that day for the main project, read
// through the GitHub CLI. One plain sentence on top (who merged how much, what went to
// production) and a few written lines on what the work was, per person (by a small Claude model,
// cached per day), then Production, Merged into staging and Pushed, each grouped by person.
// On today it also offers yesterday, and opens on yesterday until something ships today.
import AppKit
import SwiftUI
import BurroCore

struct TodayShippedSection: View {
    @Bindable var store: AppStore
    @State private var pick: Pick?
    @State private var copied = false

    enum Pick: Hashable { case today, yesterday }

    var body: some View {
        let today = store.today, shipped = store.shipped
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today.day) ?? today.day
        let showing: Pick = today.isToday ? (pick ?? automatic(shipped.state(today.day))) : .today
        let day = showing == .yesterday ? yesterday : today.day
        let state = shipped.state(day)
        let recap = recapRows(for: day, isToday: today.isToday && showing == .today)
        VStack(alignment: .leading, spacing: 12) {
            header(state: state, today: today, yesterday: yesterday, showing: showing, recap: recap)
            switch state {
            case .loaded(let value):
                ShippedDayView(day: value, live: today.isToday && showing == .today, summary: shipped.summary(day), recap: recap,
                               retry: { shipped.retrySummary(day) }, open: open)
            case .failed(let failure):
                HomeEmptyCard(symbol: "exclamationmark.triangle", title: failure.title, detail: failure.detail) {
                    PillButton(title: "Try again", symbol: "arrow.clockwise") { shipped.refresh(day, force: true) }
                }
            case nil where store.mainProject == nil && store.didScan:
                HomeEmptyCard(symbol: "shippingbox", title: "No main project yet",
                              detail: "Shipped reads the main project's GitHub repository. Pick one on Home.") { EmptyView() }
            case .loading, nil:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading GitHub…").font(.system(size: 13)).foregroundStyle(AppAppearance.secondary)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .modifier(AppCardSurface(radius: HomeStyle.cardRadius))
            }
        }
        // Again once the main project is known (the first scan may still be running).
        .task(id: "\(day.timeIntervalSince1970)|\(store.mainProject?.path ?? "")") { shipped.refresh(day) }
        .task(id: "recap|\(day.timeIntervalSince1970)|\(shipped.digestVersion)|\(shipped.repository ?? "")") { shipped.refreshRecap(day) }
        .onChange(of: today.day) { _, _ in pick = nil }
    }

    /// The day before, the week so far and the week before, each as written lines.
    private func recapRows(for day: Date, isToday: Bool) -> [RecapRow] {
        let calendar = Calendar.current, shipped = store.shipped
        let before = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        let week = ShippedPeriod.containing(day, .week)
        var rows: [RecapRow] = []
        let beforeDigest = shipped.dayDigest(before)
        rows.append(RecapRow(id: "day", title: isToday ? "Yesterday" : "Day before", text: shipped.daySummary(before),
                             writing: shipped.summaries[calendar.startOfDay(for: before)]?.writing == true,
                             empty: shipped.hasDay(before) ? "Nothing reached GitHub." : nil, target: .day(before),
                             count: beforeDigest?.merged.count, areas: AreaShare.from(beforeDigest?.areas() ?? []),
                             productionDays: (beforeDigest?.shippedCount ?? 0) > 0 ? 1 : 0))
        // On the week's first day the week so far is that day: nothing to add.
        if week.start < calendar.startOfDay(for: day) {
            let state = shipped.period(week, through: day)
            rows.append(RecapRow(id: "week", title: isToday ? "This week so far" : "Week so far", text: state?.summary?.text,
                                 writing: state?.summary?.writing == true, empty: state.map { $0.report.isEmpty ? "Nothing reached GitHub." : nil } ?? nil,
                                 target: .timeline, count: state?.report.mergedCount, areas: AreaShare.from(state?.report.areas ?? []),
                                 productionDays: state?.report.productionDays ?? 0))
        }
        let last = shipped.period(week.previous())
        rows.append(RecapRow(id: "last", title: isToday ? "Last week" : "Week before", text: last?.summary?.text,
                             writing: last?.summary?.writing == true, empty: last.map { $0.report.isEmpty ? "Nothing reached GitHub." : nil } ?? nil,
                             target: .timeline, count: last?.report.mergedCount, areas: AreaShare.from(last?.report.areas ?? []),
                             productionDays: last?.report.productionDays ?? 0))
        return rows
    }

    private func open(_ target: RecapRow.Target) {
        switch target {
        case .day(let date):
            if store.today.isToday, Calendar.current.isDateInYesterday(date) { pick = .yesterday } else { store.today.show(date) }
        case .timeline:
            store.page = .timeline
        }
    }

    /// Today once anything has merged or gone out today; until then, yesterday's recap.
    private func automatic(_ state: ShippedStore.State?) -> Pick {
        if case .loaded(let value) = state, value.merged.isEmpty, value.production.isEmpty { return .yesterday }
        return .today
    }

    private func header(state: ShippedStore.State?, today: TodayStore, yesterday: Date, showing: Pick, recap: [RecapRow]) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text("SHIPPED").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
            if case .loaded(let value) = state {
                Button { openOnGitHub(value.repositoryURL) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.forward.square").font(.system(size: 10, weight: .medium))
                        Text(value.repository.split(separator: "/").last.map(String.init) ?? value.repository)
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(AppAppearance.tertiary)
                }
                .buttonStyle(.plain).help("Open \(value.repository) on GitHub")
            }
            Spacer()
            Button { store.page = .timeline } label: {
                HStack(spacing: 3) {
                    Text("Timeline")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                .padding(.trailing, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("How the project evolved, month by month and week by week")
            if case .loaded(let value) = state {
                Button {
                    NSPasteboard.general.clearContents()
                    let summary = store.shipped.summary(value.day).flatMap { $0.current ? $0.text : nil }
                    NSPasteboard.general.setString(ShippedText.render(value, summary: summary, recap: recap.compactMap { row in
                        row.text.map { (row.title, $0) }
                    }), forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                        .padding(.horizontal, 12).frame(height: 28)
                        .overlay(Capsule().strokeBorder(AppAppearance.separator))
                }
                .buttonStyle(.plain).help("Copy this summary as text, for a chat or a standup")
            }
            if today.isToday {
                CapsulePicker(options: [(Pick.today, title("Today", store.shipped.shipped(today.day))),
                                        (Pick.yesterday, title("Yesterday", store.shipped.shipped(yesterday)))],
                              selection: Binding(get: { showing }, set: { pick = $0 }))
            }
        }
        .padding(.horizontal, 2)
    }

    private func title(_ label: String, _ day: ShippedDay?) -> String {
        guard let day else { return label }
        let count = day.merged.count + day.production.count
        return count > 0 ? "\(label) · \(count)" : label
    }
}

/// One line of the recap under a day: what came just before it, in written form.
struct RecapRow: Identifiable, Equatable {
    enum Target: Equatable { case day(Date), timeline }
    var id: String
    var title: String
    var text: String?
    var writing: Bool
    /// What to say when the period had nothing (nil while unknown).
    var empty: String?
    var target: Target
    var count: Int?
    var areas: [AreaShare] = []
    var productionDays = 0
}

/// One area's share of the merged pull requests, for the thin theme bars.
struct AreaShare: Equatable, Identifiable {
    var area: String
    var count: Int
    var id: String { area }
    /// The biggest few, the rest folded into "Other".
    static func from(_ areas: [(area: String, count: Int)], keep: Int = 4) -> [AreaShare] {
        let named = areas.filter { $0.area != "Other" }
        let top = named.prefix(keep).map { AreaShare(area: $0.area, count: $0.count) }
        let rest = named.dropFirst(keep).reduce(0) { $0 + $1.count } + (areas.first { $0.area == "Other" }?.count ?? 0)
        return top + (rest > 0 ? [AreaShare(area: "Other", count: rest)] : [])
    }
}

/// Opens a GitHub (or deployment) page in the browser; only https links GitHub handed back.
@MainActor private func openOnGitHub(_ url: URL?) {
    guard let url, url.scheme == "https" else { return }
    NSWorkspace.shared.open(url)
}

// MARK: The day

private struct ShippedDayView: View {
    var day: ShippedDay
    var live: Bool
    var summary: ShippedStore.Summary?
    var recap: [RecapRow]
    var retry: () -> Void
    var open: (RecapRow.Target) -> Void

    var body: some View {
        let people = day.contributors
        VStack(alignment: .leading, spacing: 14) {
            summary(people)
            if !day.production.isEmpty {
                ShippedGroup(title: "Production", color: AppAppearance.green, count: day.production.count) {
                    ForEach(Array(day.production.enumerated()), id: \.element.id) { index, release in
                        if index > 0 { Divider().overlay(AppAppearance.separator).padding(.leading, 58) }
                        ReleaseRow(day: day, release: release)
                    }
                }
            }
            let merging = people.filter { !day.merged(by: $0.login).isEmpty }
            if !merging.isEmpty {
                let defaultOnly = day.merged.allSatisfy { $0.base == day.defaultBranch }
                ShippedGroup(title: defaultOnly ? "Merged into \(day.defaultBranch)" : "Merged", color: AppAppearance.blue, count: day.merged.count) {
                    ForEach(Array(merging.enumerated()), id: \.element.id) { index, person in
                        if index > 0 { Divider().overlay(AppAppearance.separator) }
                        MergedBlock(day: day, person: person)
                    }
                }
            }
            let pushing = people.filter { !day.branches(by: $0.login).isEmpty }
            if !pushing.isEmpty {
                ShippedGroup(title: "Pushed", color: .purple, count: day.pushCount) {
                    ForEach(Array(pushing.enumerated()), id: \.element.id) { index, person in
                        if index > 0 { Divider().overlay(AppAppearance.separator) }
                        PushedBlock(day: day, person: person)
                    }
                }
            }
        }
    }

    /// The Brief: a one-line gist beside the production pill, one column per person (counts, a
    /// thin bar of where their merges went, two or three tagged bullets), then the recap.
    private func summary(_ people: [ShippedDay.Person]) -> some View {
        let brief = summary?.text.flatMap(ShippedBrief.init(json:))
        let digest = ShippedDigest(day)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(day.isEmpty ? (live ? "Nothing on GitHub yet today." : "Nothing reached GitHub that day.") : (brief?.headline ?? day.headline))
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(AppAppearance.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(summary?.current == false && brief != nil ? 0.55 : 1)
                Spacer(minLength: 8)
                if !day.isEmpty { ProductionPill(day: day) }
            }
            if let text = summary?.text, brief == nil { ShippedSummaryText(summary: summary!) .id(text) }
            if !people.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 22, alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(people.prefix(6)) { person in
                        PersonBrief(day: day, person: person, areas: AreaShare.from(digest.areas(for: person.displayName)),
                                    themes: brief?.people.first { $0.name == person.displayName }?.themes ?? [],
                                    dimmed: summary?.current == false)
                    }
                }
            }
            if let production = brief?.production {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "flag").font(.system(size: 10.5, weight: .medium))
                    Text(production)
                }
                .font(.system(size: 12.5)).foregroundStyle(AppAppearance.secondary)
            }
            if !recap.isEmpty {
                Divider().overlay(AppAppearance.separator).padding(.vertical, 2)
                HStack(alignment: .top, spacing: 14) {
                    ForEach(recap) { row in RecapColumn(row: row) { open(row.target) } }
                }
                .padding(.horizontal, -8)
            }
            HStack(spacing: 6) {
                Text(live ? "Updated \(day.fetchedAt.formatted(date: .omitted, time: .shortened)) · every 5 minutes while open"
                          : "From GitHub at \(day.fetchedAt.formatted(date: .omitted, time: .shortened))")
                if day.partial { Text("· GitHub's lists were long, so some pushes may be missing").foregroundStyle(AppAppearance.amber) }
                if let summary { summaryNote(summary) }
            }
            .font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(AppCardSurface(radius: HomeStyle.cardRadius))
    }

    /// Where the summary came from, or why there isn't a current one.
    @ViewBuilder private func summaryNote(_ summary: ShippedStore.Summary) -> some View {
        if summary.writing, summary.text != nil {
            Text("· Updating the summary…")
        } else if let problem = summary.problem {
            if case .failed = problem {
                Button(action: retry) { Text("· \(problem.short) · ") + Text("Retry").foregroundStyle(AppAppearance.secondary) }
                    .buttonStyle(.plain).help(problem.detail)
            } else {
                Text("· \(problem.short)").help(problem.detail)
            }
        } else if summary.current {
            Text("· Summary by \(ShippedSummary.modelTitle)")
                .help("Written by Claude \(ShippedSummary.modelTitle) from the pull request titles, areas, branches and production status below. Rewritten only when they change.")
        }
    }
}

/// "Nothing to production", "Shipped to production", "Production failed" as a quiet pill.
private struct ProductionPill: View {
    var day: ShippedDay
    var body: some View {
        let failed = day.production.contains { $0.status == .failed }
        let shipped = day.production.filter { $0.status != .failed && $0.status != .cancelled }.count
        let (text, color): (String, Color) = day.production.isEmpty ? ("Nothing to production", AppAppearance.tertiary)
            : failed && shipped == 0 ? ("Production failed", Color(red: 0.92, green: 0.36, blue: 0.36))
            : (shipped > 1 ? "\(shipped)× to production" : "Shipped to production", AppAppearance.green)
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(AppAppearance.secondary)
        }
        .padding(.horizontal, 9).padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(AppAppearance.separator))
        .fixedSize()
    }
}

/// A thin bar of where merges went: one grey segment per area, darkest the biggest.
struct AreaBar: View {
    var areas: [AreaShare]
    var height: CGFloat = 6
    var body: some View {
        let total = max(1, areas.reduce(0) { $0 + $1.count })
        GeometryReader { geometry in
            HStack(spacing: 1.5) {
                ForEach(Array(areas.enumerated()), id: \.element.id) { index, share in
                    Rectangle().fill(AppAppearance.text.opacity(share.area == "Other" ? 0.14 : max(0.22, 0.78 - Double(index) * 0.16)))
                        .frame(width: max(2, (geometry.size.width - CGFloat(areas.count - 1) * 1.5) * CGFloat(share.count) / CGFloat(total)))
                        .help("\(share.area): \(share.count)")
                }
            }
        }
        .frame(height: height).clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
        .opacity(areas.isEmpty ? 0 : 1)
    }
}

/// One person in the Brief: avatar, name and counts with their theme bar, then tagged bullets.
private struct PersonBrief: View {
    var day: ShippedDay
    var person: ShippedDay.Person
    var areas: [AreaShare]
    var themes: [ShippedBrief.Theme]
    var dimmed: Bool
    var body: some View {
        let merged = day.merged(by: person.login).count
        let pushes = day.branches(by: person.login).reduce(0) { $0 + $1.pushes }
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                PersonAvatar(person: person, size: 22)
                Text(person.displayName).font(.system(size: 13, weight: .semibold))
                Text([merged > 0 ? "\(merged) merged" : nil, pushes > 0 ? ShippedDay.count(pushes, "push") : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                if !areas.isEmpty { AreaBar(areas: areas).frame(width: 90) }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(themes.enumerated()), id: \.offset) { _, theme in BriefBullet(theme: theme) }
            }
            .opacity(dimmed ? 0.55 : 1)
        }
    }
}

/// "• [Area] what changed", wrapping under itself.
struct BriefBullet: View {
    var theme: ShippedBrief.Theme
    var tag = true
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle().fill(AppAppearance.tertiary).frame(width: 3.5, height: 3.5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
            if tag, let area = theme.area { AreaTag(text: area) }
            Text(theme.text).font(.system(size: 13)).foregroundStyle(AppAppearance.text.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One recap column: label and count, its theme bar, three short bullets. Opens that day, or the Timeline.
private struct RecapColumn: View {
    var row: RecapRow
    var open: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(row.title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(AppAppearance.tertiary)
                    if let count = row.count, count > 0 { Text("· \(count)").font(.system(size: 10.5, weight: .semibold)).monospacedDigit().foregroundStyle(AppAppearance.tertiary) }
                    Spacer(minLength: 0)
                    if row.productionDays > 0 {
                        Image(systemName: "flag").font(.system(size: 9.5)).foregroundStyle(AppAppearance.tertiary)
                            .help(row.productionDays == 1 ? "Something went to production" : "Production on \(row.productionDays) days")
                    }
                }
                AreaBar(areas: row.areas, height: 5)
                Group {
                    if let text = row.text {
                        if let brief = ShippedBrief(json: text) {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(brief.bullets(3).enumerated()), id: \.offset) { _, theme in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Circle().fill(AppAppearance.tertiary).frame(width: 3, height: 3).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                                        Text(theme.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        } else {
                            Text(ShippedSummary.lines(text).map(\.text).joined(separator: " ")).lineLimit(4)
                        }
                    } else if row.writing {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Writing…") }.foregroundStyle(AppAppearance.tertiary)
                    } else {
                        Text(row.empty ?? "Not read yet").foregroundStyle(AppAppearance.tertiary)
                    }
                }
                .font(.system(size: 12.5)).foregroundStyle(AppAppearance.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(hovering ? AppAppearance.hover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .help(row.target == .timeline ? "Open the Timeline" : "Open that day")
    }
}

/// The written summary: one line per person, the name in the text colour and the rest a step
/// quieter, so it reads as part of the header card. Dimmed while a newer one is being written.
struct ShippedSummaryText: View {
    var summary: ShippedStore.Summary
    var body: some View {
        if let text = summary.text {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(ShippedSummary.lines(text).enumerated()), id: \.offset) { _, line in
                    (line.label.map { Text("\($0)  ").fontWeight(.semibold).foregroundStyle(AppAppearance.text) } ?? Text(""))
                        + Text(line.text).foregroundStyle(AppAppearance.secondary)
                }
            }
            .font(.system(size: 13.5)).lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .opacity(summary.current ? 1 : 0.55)
            .animation(.easeOut(duration: 0.2), value: summary)
        } else if summary.writing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("Writing a summary of the day…")
            }
            .font(.system(size: 12.5)).foregroundStyle(AppAppearance.tertiary)
        }
    }
}

private struct PersonTally: View {
    var day: ShippedDay
    var person: ShippedDay.Person
    var body: some View {
        let merged = day.merged(by: person.login).count
        let pushes = day.branches(by: person.login).reduce(0) { $0 + $1.pushes }
        let releases = day.production.filter { $0.actor == person.login }.count
        HStack(spacing: 8) {
            PersonAvatar(person: person, size: 24)
            Text(person.displayName).font(.system(size: 13, weight: .semibold))
            Text([releases > 0 ? "\(releases) to prod" : nil, merged > 0 ? "\(merged) merged" : nil,
                  pushes > 0 ? ShippedDay.count(pushes, "push") : nil].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.secondary)
        }
    }
}

/// A collapsible titled card, like the chat groups below it.
private struct ShippedGroup<Content: View>: View {
    var title: String
    var color: Color
    var count: Int
    @ViewBuilder var content: () -> Content
    @State private var expanded = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(AppAppearance.tertiary)
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text("\(count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                VStack(spacing: 0) { content() }
                    .clipShape(RoundedRectangle(cornerRadius: HomeStyle.cardRadius, style: .continuous))
                    .modifier(SoftSurface(radius: HomeStyle.cardRadius, shadowRadius: 8, y: 2))
            }
        }
    }
}

// MARK: Rows

private struct ReleaseRow: View {
    var day: ShippedDay
    var release: ShippedDay.Release
    @State private var hovering = false
    var body: some View {
        let promotion = release.kind == .promotion ? ShippedDay.promotion(release.title) : nil
        Button { openOnGitHub(release.url) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 30, height: 30).background(tint.opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(promotion?.text ?? release.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(AppAppearance.text)
                    Text(detail(promotion)).font(.system(size: 12)).lineLimit(1).foregroundStyle(AppAppearance.tertiary)
                }
                Spacer(minLength: 8)
                if let status = release.status { StatusPill(status: status) }
                Text(release.at, format: .dateTime.hour().minute()).font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(AppAppearance.tertiary).frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(hovering ? AppAppearance.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .help([release.title, release.target].compactMap { $0 }.joined(separator: "\n"))
    }

    private func detail(_ promotion: (text: String, from: String, to: String)?) -> String {
        var parts: [String] = []
        if let promotion {
            parts.append("Promoted \(promotion.from) → \(promotion.to)")
            parts.append(release.detail.components(separatedBy: " into ").first ?? release.detail)
        } else {
            parts.append(release.detail)
        }
        if let actor = release.actor { parts.append(day.person(actor).displayName) }
        return parts.joined(separator: " · ")
    }

    private var symbol: String {
        switch release.kind {
        case .promotion: "airplane.departure"
        case .push: "arrow.up.to.line"
        case .workflow: "gearshape.2"
        case .deployment: "icloud.and.arrow.up"
        }
    }
    private var tint: Color { release.status == .failed ? Color(red: 0.92, green: 0.36, blue: 0.36) : AppAppearance.green }
}

private struct StatusPill: View {
    var status: ShippedDay.Release.Status
    var body: some View {
        Text(ShippedText.title(status)).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
    }
    private var color: Color {
        switch status {
        case .live, .succeeded: AppAppearance.green
        case .running: AppAppearance.blue
        case .waiting: AppAppearance.amber
        case .failed: Color(red: 0.92, green: 0.36, blue: 0.36)
        case .cancelled: AppAppearance.tertiary
        }
    }
}

/// One person's merged pull requests: the latest few, the rest a click away.
private struct MergedBlock: View {
    var day: ShippedDay
    var person: ShippedDay.Person
    @State private var all = false
    var body: some View {
        let pulls = day.merged(by: person.login)
        let shown = all ? pulls : Array(pulls.prefix(6))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PersonAvatar(person: person, size: 26)
                Text(person.displayName).font(.system(size: 13, weight: .semibold))
                Text(ShippedDay.count(pulls.count, "pull request")).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                Spacer()
                let added = pulls.reduce(0) { $0 + $1.additions }, removed = pulls.reduce(0) { $0 + $1.deletions }
                HStack(spacing: 5) {
                    Text("+" + HomeFormat.tokens(Double(added))).foregroundStyle(AppAppearance.green.opacity(0.8))
                    Text("−" + HomeFormat.tokens(Double(removed))).foregroundStyle(Color(red: 0.92, green: 0.36, blue: 0.36).opacity(0.8))
                }
                .font(.system(size: 11.5)).monospacedDigit()
                .help("\(added.formatted()) lines added, \(removed.formatted()) removed")
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
            ForEach(shown) { pull in PullRow(day: day, pull: pull) }
            MoreButton(hidden: pulls.count - shown.count, all: $all, noun: "pull request")
        }
        .padding(.bottom, 8)
    }
}

private struct PullRow: View {
    var day: ShippedDay
    var pull: ShippedDay.PullRequest
    @State private var hovering = false
    var body: some View {
        let parts = ShippedDay.area(of: pull.title)
        Button { openOnGitHub(pull.url) } label: {
            HStack(spacing: 8) {
                if let area = parts.area { AreaTag(text: area) }
                Text(parts.text).font(.system(size: 13)).lineLimit(1).foregroundStyle(AppAppearance.text)
                if pull.base != day.defaultBranch {
                    Text("→ \(pull.base)").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
                }
                Spacer(minLength: 8)
                Text(verbatim: "#\(pull.number)").font(.system(size: 11.5)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                Text(pull.mergedAt, format: .dateTime.hour().minute()).font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(AppAppearance.tertiary).frame(width: 44, alignment: .trailing)
            }
            .padding(.leading, 52).padding(.trailing, 16).padding(.vertical, 6)
            .background(hovering ? AppAppearance.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .help("\(pull.title)\n+\(pull.additions) −\(pull.deletions) · \(pull.head) → \(pull.base)")
    }
}

/// One person's pushes: work still in flight first (open pull requests, branches without one,
/// straight pushes to staging), then branches whose pull request already merged, folded away.
private struct PushedBlock: View {
    var day: ShippedDay
    var person: ShippedDay.Person
    @State private var all = false
    @State private var showMerged = false
    var body: some View {
        let branches = day.branches(by: person.login)
        let landed = branches.filter { $0.pullRequest?.state == "MERGED" }
        let flying = branches.filter { $0.pullRequest?.state != "MERGED" }
        let shown = all ? flying : Array(flying.prefix(5))
        let pushes = branches.reduce(0) { $0 + $1.pushes }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PersonAvatar(person: person, size: 26)
                Text(person.displayName).font(.system(size: 13, weight: .semibold))
                Text("\(ShippedDay.count(pushes, "push")) to \(ShippedDay.count(branches.count, "branch"))")
                    .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
            ForEach(shown) { branch in BranchRow(day: day, branch: branch) }
            MoreButton(hidden: flying.count - shown.count, all: $all, noun: "branch")
            if !landed.isEmpty {
                Button { withAnimation(.easeOut(duration: 0.15)) { showMerged.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(showMerged ? 90 : 0))
                        Text("\(ShippedDay.count(landed.count, "branch")) merged, listed above · \(ShippedDay.count(landed.reduce(0) { $0 + $1.pushes }, "push"))")
                    }
                    .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                    .padding(.leading, 52).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showMerged { ForEach(landed) { branch in BranchRow(day: day, branch: branch) } }
            }
        }
        .padding(.bottom, 8)
    }
}

private struct BranchRow: View {
    var day: ShippedDay
    var branch: ShippedDay.Branch
    @State private var hovering = false
    var body: some View {
        let straight = branch.name == day.defaultBranch
        Button { openOnGitHub(link) } label: {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(AppAppearance.tertiary, lineWidth: branch.pullRequest == nil && !straight ? 1 : 0))
                if let pull = branch.pullRequest {
                    let parts = ShippedDay.area(of: pull.title)
                    if let area = parts.area { AreaTag(text: area) }
                    Text(parts.text).font(.system(size: 13)).lineLimit(1).foregroundStyle(AppAppearance.text)
                } else {
                    Text(branch.name).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(straight ? AppAppearance.amber : AppAppearance.text)
                }
                if straight { Tag(text: "straight to \(day.defaultBranch)", color: AppAppearance.amber) }
                if branch.forced > 0 { Tag(text: "force-pushed", color: AppAppearance.tertiary) }
                Spacer(minLength: 8)
                if let pull = branch.pullRequest {
                    Text(verbatim: "#\(pull.number)").font(.system(size: 11.5)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                }
                Text(ShippedDay.count(branch.pushes, "push")).font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.secondary)
                Text(branch.lastAt, format: .dateTime.hour().minute()).font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(AppAppearance.tertiary).frame(width: 44, alignment: .trailing)
            }
            .padding(.leading, 52).padding(.trailing, 16).padding(.vertical, 6)
            .background(hovering ? AppAppearance.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .help(help)
    }

    private var dot: Color {
        switch branch.pullRequest?.state {
        case "OPEN": AppAppearance.green
        case "MERGED": .purple
        default: branch.name == day.defaultBranch ? AppAppearance.amber : .clear
        }
    }
    private var link: URL? {
        if let url = branch.pullRequest?.url { return url }
        let path = branch.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch.name
        return URL(string: "https://github.com/\(day.repository)/commits/\(path)")
    }
    private var help: String {
        var lines = [branch.name]
        if let pull = branch.pullRequest { lines.insert("\(pull.title) (#\(pull.number), \(pull.state.lowercased()))", at: 0) }
        else if branch.name != day.defaultBranch { lines.append("No pull request yet") }
        if branch.created { lines.append("New branch today") }
        return lines.joined(separator: "\n")
    }
}

private struct MoreButton: View {
    var hidden: Int
    @Binding var all: Bool
    var noun: String
    var body: some View {
        if hidden > 0 || all {
            Button { withAnimation(.easeOut(duration: 0.15)) { all.toggle() } } label: {
                Text(all ? "Show fewer" : "Show \(hidden) more")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.blue)
                    .padding(.leading, 52).padding(.vertical, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

struct AreaTag: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize()
            .foregroundStyle(AppAppearance.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(AppAppearance.raised, in: Capsule())
    }
}

private struct Tag: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).fixedSize()
            .foregroundStyle(color).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// A GitHub avatar, or the person's initial while it loads (or without one).
struct PersonAvatar: View {
    var person: ShippedDay.Person
    var size: CGFloat
    var body: some View {
        let initial = Circle().fill(HomeStyle.tint(for: person.login).opacity(0.85))
            .overlay(Text(String(person.displayName.prefix(1)).uppercased())
                .font(.system(size: size * 0.45, weight: .bold, design: .rounded)).foregroundStyle(.white))
        Group {
            if let url = person.avatar {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { initial }
                }
            } else { initial }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .overlay(Circle().strokeBorder(AppAppearance.separator))
        .help(person.isYou ? "You (\(person.login))" : [person.name, person.login].compactMap { $0 }.joined(separator: " · "))
    }
}
