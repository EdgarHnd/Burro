// The cards under the Today page's day ribbon, and its chats. While you were away: the agents'
// wall-clock time while Burro was recording and you weren't at the Mac ("about" when the scan
// was partial or some chats' stretches are unknown), with each chat's share and its outcome line (the Brief's headline for it, else its latest reply when previews are on); or one
// quiet line saying why there is nothing to say. Most time: the apps and sites with the most
// tracked time, bars relative to the first (right-click to recategorise). Shipped: the day's merged
// pull requests and production deploys in time order (click opens one on GitHub), with Details to
// show the full Shipped section (summary, recap, pushes) underneath. Chats: today's chats in
// compact columns by status (or project), each row opening its chat, with how long a waiting chat
// has waited, how long a working chat's current stretch has run, or when a chat last moved.
import AppKit
import SwiftUI
import BurroCore

/// A card with an uppercase section label, a quiet note on the right, and its content.
struct TodayRibbonCardFrame<Accessory: View, Content: View>: View {
    var title: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
                Spacer(minLength: 8)
                accessory().font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
            }
            .padding(.bottom, 2)
            content()
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(AppCardSurface(radius: HomeStyle.cardRadius))
    }
}

// MARK: While you were away

struct TodayAwayCard: View {
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

    var body: some View {
        TodayRibbonCardFrame(title: "While you were away") {
            if let span = summary?.span, (summary?.total ?? 0) >= 60 {
                Text(ActivityStyle.range(span.start, span.end)).monospacedDigit()
            }
        } content: {
            if let summary, summary.total >= 60 {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if summary.partial { Text("About").foregroundStyle(AppAppearance.secondary) }
                    Text(TodaySummary.duration(summary.total)).font(.system(size: 26, weight: .bold)).monospacedDigit()
                    Text("of agent work, \(summary.chats.count) chat\(summary.chats.count == 1 ? "" : "s")").foregroundStyle(AppAppearance.secondary)
                }
                .padding(.vertical, 4)
                .help("Wall-clock time any agent was active while Burro was recording and you weren't at the Mac (idle, away or the screen locked); time Burro wasn't recording isn't counted. Chats working at once count once, so their own times can add up to more."
                      + (summary.partial ? " Some chats couldn't be read, so this is approximate." : ""))
                VStack(spacing: 0) {
                    ForEach(Array(rows.prefix(4).enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().overlay(AppAppearance.separator) }
                        AwayRow(row: row)
                    }
                }
                if rows.count > 4 {
                    Text("and \(rows.count - 4) more").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).padding(.top, 4)
                }
            } else {
                Text(summary == nil ? reason : "Agents weren't working while you were away.")
                    .font(.system(size: 13)).foregroundStyle(AppAppearance.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
        }
    }
}

private struct AwayRow: View {
    var row: TodayAwayCard.Row
    @State private var hovering = false
    var body: some View {
        Button { row.open?() } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(row.status.color).frame(width: 8, height: 8).padding(.top, 5).opacity(row.status == .idle ? 0.6 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppAppearance.text).lineLimit(1)
                    if let outcome = row.outcome {
                        Text(outcome).font(.system(size: 13)).foregroundStyle(AppAppearance.secondary).lineLimit(2)
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

struct TodayMostTimeCard: View {
    var day: ActivityDay
    var tracker: ActivityTracker

    private var items: [(item: ActivityDay.Item, site: Bool)] {
        Array((day.apps.map { ($0, false) } + day.sites.map { ($0, true) }).sorted { $0.0.seconds > $1.0.seconds }.prefix(7))
    }

    var body: some View {
        let items = self.items, top = max(1, items.first?.item.seconds ?? 1)
        TodayRibbonCardFrame(title: "Most time") { EmptyView() } content: {
            if items.isEmpty {
                Text("Only moments under a minute so far.").font(.system(size: 13)).foregroundStyle(AppAppearance.secondary).padding(.vertical, 4)
            }
            ForEach(items, id: \.item.id) { item, site in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3).fill(ActivityStyle.color(item.category)).frame(width: 9, height: 9)
                    Text(site && item.name.hasPrefix("www.") ? String(item.name.dropFirst(4)) : item.name)
                        .font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Capsule().fill(AppAppearance.raised).frame(width: 90, height: 6)
                        .overlay(alignment: .leading) {
                            Capsule().fill(ActivityStyle.color(item.category)).frame(width: max(3, 90 * item.seconds / top), height: 6)
                        }
                    Text(TodaySummary.duration(item.seconds)).font(.system(size: 12, design: .monospaced)).foregroundStyle(AppAppearance.tertiary)
                        .frame(width: 56, alignment: .trailing)
                }
                .padding(.vertical, 6).contentShape(Rectangle())
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

struct TodayShippedCard: View {
    enum State {
        case loading
        case noProject
        case failed(title: String, detail: String, retry: () -> Void)
        case loaded(ShippedDay)
    }
    var state: State
    var isToday: Bool
    @Binding var details: Bool

    var body: some View {
        TodayRibbonCardFrame(title: "Shipped") {
            if case .loaded(let day) = state { Text(day.repository.split(separator: "/").last.map(String.init) ?? "from GitHub").lineLimit(1) }
            else { Text("from GitHub") }
        } content: {
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
                    ForEach(Array(rows.prefix(6).enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().overlay(AppAppearance.separator) }
                        ShipRow(row: row)
                    }
                }
                HStack(spacing: 8) {
                    if rows.count > 6 { Text("\(rows.count - 6) more").foregroundStyle(AppAppearance.tertiary) }
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
    var row: TodayShippedCard.Row
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
                Text(TodayRibbonCard.clock(row.at)).font(.system(size: 12, design: .monospaced)).foregroundStyle(AppAppearance.tertiary)
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
        case .toRead, .idle: TodayRibbonCard.clock(row.lastAt)
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
