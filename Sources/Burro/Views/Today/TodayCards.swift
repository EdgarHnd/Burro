// The Today page's panel contents and its chats. While you were away (the queue's second tab):
// the agents' wall-clock time while Burro was recording and you weren't at the Mac ("about" when the
// scan was partial or some chats' stretches are unknown), with each chat's share and its outcome
// line (the Brief's headline for it, else its latest reply when previews are on); or one quiet line
// saying why there is nothing to say. Most time on: the apps and sites with the most tracked time,
// bars relative to the first (right-click to recategorise). Shipped: the day's merged pull requests
// and production deploys in time order (click opens one on GitHub), with Details to show the full
// Shipped section (summary, recap, pushes) underneath. Chats by project: each project's chats and
// their merged active time. Chats: today's chats in compact columns by status (or project), each row
// opening its chat, with how long a waiting chat has waited, how long a working chat's current
// stretch has run, or when a chat last moved.
import AppKit
import SwiftUI
import BurroCore

// MARK: While you were away

struct TodayAwayList: View {
    struct Row: Identifiable {
        var id: String
        var title: String
        var outcome: String?
        var seconds: TimeInterval
        var status: TodayRow.Status
        var open: (() -> Void)?
    }
    var summary: AgentAwayTime.Summary?
    var rows: [Row]
    /// Why there's no summary, shown instead.
    var reason: String
    var limit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let summary, summary.total >= 60 {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if summary.partial { Text("About").foregroundStyle(AppAppearance.secondary) }
                    Text(TodaySummary.duration(summary.total)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    Text("of agent work, \(summary.chats.count) chat\(summary.chats.count == 1 ? "" : "s")").foregroundStyle(AppAppearance.secondary)
                    Spacer(minLength: 4)
                    if let span = summary.span {
                        Text(ActivityStyle.range(span.start, span.end)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                    }
                }
                .font(.system(size: 12.5)).padding(.bottom, 4)
                .help("Wall-clock time any agent was active while Burro was recording and you weren't at the Mac (idle, away or the screen locked); time Burro wasn't recording isn't counted. Chats working at once count once, so their own times can add up to more."
                      + (summary.partial ? " Some chats couldn't be read, so this is approximate." : ""))
                VStack(spacing: 0) {
                    ForEach(Array(rows.prefix(limit).enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Rectangle().fill(AppAppearance.separator).frame(height: 1) }
                        TodayAwayRow(row: row)
                    }
                }
                if rows.count > limit {
                    Text("and \(rows.count - limit) more").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).padding(.top, 4)
                }
            } else {
                Text(summary == nil ? reason : "Agents weren't working while you were away.")
                    .font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
        }
    }
}

/// A chat that worked while you were away: its state dot, title, outcome line and its share.
struct TodayAwayRow: View {
    var row: TodayAwayList.Row
    @State private var hovering = false
    var body: some View {
        Button { row.open?() } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(row.status.color).frame(width: 8, height: 8).padding(.top, 5).opacity(row.status == .idle ? 0.6 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).font(.system(size: 13)).foregroundStyle(AppAppearance.text).lineLimit(1)
                    if let outcome = row.outcome {
                        Text(outcome).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Text(TodaySummary.duration(row.seconds)).font(.system(size: 13)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
            }
            .padding(.vertical, 8).contentShape(Rectangle())
            .background(hovering && row.open != nil ? AppAppearance.hover : .clear)
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.disabled(row.open == nil)
        .help(row.open == nil ? "Not in the live feed any more" : "Open the chat")
    }
}

// MARK: Most time

struct TodayMostTimeList: View {
    var day: ActivityDay
    var tracker: ActivityTracker

    var limit = 6
    private var items: [(item: ActivityDay.Item, site: Bool)] {
        Array((day.apps.map { ($0, false) } + day.sites.map { ($0, true) }).sorted { $0.0.seconds > $1.0.seconds }.prefix(limit))
    }

    var body: some View {
        let items = self.items, top = max(1, items.first?.item.seconds ?? 1)
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text("Only moments under a minute so far.").font(.system(size: 13)).foregroundStyle(AppAppearance.secondary).padding(.vertical, 4)
            }
            ForEach(items, id: \.item.id) { item, site in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3).fill(ActivityStyle.color(item.category)).frame(width: 9, height: 9)
                    Text(site && item.name.hasPrefix("www.") ? String(item.name.dropFirst(4)) : item.name)
                        .font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Capsule().fill(AppAppearance.raised).frame(width: 60, height: 5)
                        .overlay(alignment: .leading) {
                            Capsule().fill(ActivityStyle.color(item.category)).frame(width: max(3, 60 * item.seconds / top), height: 5)
                        }
                    Text(TodaySummary.duration(item.seconds)).font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                        .frame(width: 50, alignment: .trailing)
                }
                .padding(.vertical, 5).contentShape(Rectangle())
                .help("\(item.category.title)\(site ? " · a site" : "") · right-click to change")
                .contextMenu {
                    if item.category != .private, site || !DayflowImport.isGroup(bundleID: item.id) {
                        ActivityCategoryMenu(tracker: tracker, id: item.id, name: item.name, site: site)
                    }
                }
            }
        }
    }
}

// MARK: Shipped

struct TodayShippedList: View {
    enum State {
        case loading
        case noProject
        case failed(title: String, detail: String, retry: () -> Void)
        case loaded(ShippedDay)
    }
    var state: State
    var isToday: Bool
    @Binding var details: Bool
    var limit = 5

    /// The panel's subtitle: the repository's short name.
    static func source(_ state: State) -> String {
        if case .loaded(let day) = state { return day.repository.split(separator: "/").last.map { "\($0) on GitHub" } ?? "from GitHub" }
        return "from GitHub"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch state {
            case .loading:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading GitHub…") }
                    .font(.system(size: 13)).foregroundStyle(AppAppearance.secondary).padding(.vertical, 4)
            case .noProject:
                note("Shipped reads the main project's GitHub repository. Pick one on Home.")
            case .failed(let title, let detail, let retry):
                note("\(title). \(detail)")
                Button("Try again", action: retry).buttonStyle(.plain).foregroundStyle(AppAppearance.blue).font(.system(size: 13))
            case .loaded(let day):
                let rows = Self.rows(day)
                if rows.isEmpty {
                    note(isToday ? "Nothing merged or deployed yet today." : "Nothing merged or deployed that day.")
                }
                VStack(spacing: 0) {
                    ForEach(Array(rows.prefix(limit).enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().overlay(AppAppearance.separator) }
                        ShipRow(row: row)
                    }
                }
                HStack(spacing: 8) {
                    if rows.count > limit { Text("\(rows.count - limit) more").foregroundStyle(AppAppearance.tertiary) }
                    Spacer()
                    if !day.isEmpty {
                        Button(details ? "Hide details" : "Details") { details.toggle() }.buttonStyle(.plain).foregroundStyle(AppAppearance.blue)
                            .help(details ? "Hide the full Shipped section" : "Show the summary, recap, pushes and every merge below")
                    }
                }
                .font(.system(size: 12)).padding(.top, 4)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(AppAppearance.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
    }

    struct Row: Identifiable {
        var id: String
        var at: Date
        var number: Int?
        var title: String
        var detail: String?
        var status: ShippedDay.Release.Status?
        var deploy: Bool
        var url: URL?
    }

    /// Merges and production deploys in time order.
    static func rows(_ day: ShippedDay) -> [Row] {
        let merged = day.merged.map { Row(id: "pr\($0.number)", at: $0.mergedAt, number: $0.number, title: $0.title,
                                          detail: $0.base == day.defaultBranch ? nil : $0.base, status: nil, deploy: false, url: $0.url) }
        let deploys = day.production.map { Row(id: "rel" + $0.id, at: $0.at, number: nil, title: $0.title, detail: $0.target,
                                               status: $0.status, deploy: true, url: $0.url) }
        return (merged + deploys).sorted { $0.at < $1.at }
    }

    /// The same events as ticks on the ribbon's Shipped lane.
    static func marks(_ day: ShippedDay) -> [TodayRibbonShip] {
        rows(day).map { row in
            TodayRibbonShip(id: row.id, kind: row.deploy ? .deploy(row.status) : .merged, at: row.at,
                            title: row.number.map { "#\($0) \(row.title)" } ?? row.title, url: row.url)
        }
    }
}

private struct ShipRow: View {
    var row: TodayShippedList.Row
    @State private var hovering = false
    var body: some View {
        if row.url == nil {
            content.help(row.title)
        } else {
            Button { if let url = row.url { NSWorkspace.shared.open(url) } } label: {
                content.background(hovering ? AppAppearance.hover : .clear)
            }
            .buttonStyle(.plain).onHover { hovering = $0 }
            .help("\(row.title) · open on GitHub")
        }
    }

    private var content: some View {
            HStack(spacing: 10) {
                Text(TodayRibbonStyle.clock(row.at)).font(.system(size: 12, design: .monospaced)).foregroundStyle(AppAppearance.tertiary)
                    .frame(width: 42, alignment: .leading)
                if row.deploy {
                    DeployDiamond(color: TodayShipStyle.color(row.status), size: 10).padding(.horizontal, 3)
                    (Text(row.title) + Text(row.detail.map { " · \($0)" } ?? "").foregroundColor(AppAppearance.secondary))
                        .font(.system(size: 13)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    if let status = row.status {
                        Text(status.rawValue.capitalized).font(.system(size: 12)).foregroundStyle(TodayShipStyle.color(status))
                    }
                } else {
                    if let number = row.number {
                        Text(verbatim: "#\(number)").font(.system(size: 12, design: .monospaced)).foregroundStyle(AppAppearance.secondary)
                    }
                    Text(row.title).font(.system(size: 13)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    if let detail = row.detail { AppTag(text: detail) }
                }
            }
            .foregroundStyle(AppAppearance.text)
            .padding(.vertical, 7).contentShape(Rectangle())
    }
}

// MARK: Chats by project

/// Each project's chats and merged active time, a bar relative to the busiest.
struct TodayProjectsList: View {
    var rows: [TodayProjectRow]
    var limit = 6
    var body: some View {
        let top = max(1, rows.compactMap(\.active).max() ?? 1)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.prefix(limit)) { row in
                HStack(spacing: 10) {
                    Text(row.name).font(.system(size: 13)).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(row.chats)").font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                        .help("\(row.chats) chat\(row.chats == 1 ? "" : "s")")
                    Capsule().fill(AppAppearance.raised).frame(width: 44, height: 5)
                        .overlay(alignment: .leading) {
                            if let active = row.active { Capsule().fill(AppAppearance.tertiary).frame(width: max(3, 44 * active / top), height: 5) }
                        }
                    Text(row.active.map { AgentAwayTime.phrase($0, partial: row.approximate) } ?? "—")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.tertiary).lineLimit(1).fixedSize()
                }
                .padding(.vertical, 5)
                .help(row.active == nil ? "When these chats worked isn't known (another machine, or Burro's helper didn't say)."
                      : "Active time of its chats on this Mac, chats working at once counted once" + (row.approximate ? "; some chats' times are unknown" : ""))
            }
            if rows.count > limit {
                Text("and \(rows.count - limit) more").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).padding(.top, 4)
            }
        }
    }
}

// MARK: Chats

/// One compact column of chats: a coloured status (or project) label with its count, then rows.
struct TodayChatColumn: View {
    var title: String
    var color: Color
    var rows: [TodayRow]
    var now: Date
    var needsYou = false
    var open: (TodayRow) -> Void
    @State private var expanded = false
    private static let shown = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text("\(title.uppercased()) · \(rows.count)").font(.system(size: 11, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(needsYou ? AppAppearance.amber : AppAppearance.tertiary)
            }
            .padding(.top, 2).padding(.bottom, 6)
            ForEach(expanded ? rows : Array(rows.prefix(Self.shown))) { row in
                TodayCompactChatRow(row: row, now: now) { open(row) }
            }
            if rows.count > Self.shown {
                Button(expanded ? "Show fewer" : "\(rows.count - Self.shown) more") { expanded.toggle() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(AppAppearance.blue).padding(.top, 4)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(AppCardSurface(radius: HomeStyle.cardRadius))
        .overlay {
            if needsYou {
                RoundedRectangle(cornerRadius: HomeStyle.cardRadius, style: .continuous).strokeBorder(AppAppearance.amber.opacity(0.4))
            }
        }
    }
}

private struct TodayCompactChatRow: View {
    var row: TodayRow
    var now: Date
    var open: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text(row.title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(row.status == .idle ? AppAppearance.secondary : AppAppearance.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(trailing).font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.tertiary).lineLimit(1).fixedSize()
            }
            .padding(.vertical, 6).padding(.horizontal, 4).contentShape(Rectangle())
            .background(hovering && row.session != nil ? AppAppearance.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, -4)
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.disabled(row.session == nil)
        .help(help)
    }

    /// Waiting: how long it has waited; working: how long its current stretch has run; otherwise when it last moved.
    private var trailing: String {
        switch row.status {
        case .needsYou: TodayChatTime.elapsed(row.lastAt, now: now)
        case .working: TodayChatTime.elapsed(row.activeSince ?? row.lastAt, now: now)
        case .toRead, .idle: TodayRibbonStyle.clock(row.lastAt)
        }
    }

    private var help: String {
        var lines = [row.title, row.breadcrumb]
        if let preview = row.preview { lines.append(preview) }
        lines.append(row.session == nil ? "Not in the live feed any more" : "Click to open the chat")
        return lines.joined(separator: "\n")
    }
}

enum TodayChatTime {
    /// "now", "4 min", "1h 05m".
    static func elapsed(_ since: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(since)) / 60)
        if minutes < 1 { return "now" }
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }
}
