// Pieces of the Today page: the date header, the summary row of stat tiles (one row that wraps,
// sized to its content), the hours strip, and chat groups. The tracked-activity pieces are in
// TodayActivity.swift and TodayDayView.swift.
import SwiftUI
import BurroCore

struct TodayHeader: View {
    var today: TodayStore
    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(today.isToday ? "TODAY" : today.day.formatted(.dateTime.weekday(.wide)).uppercased())
                    .font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(AppAppearance.secondary)
                Text(today.day, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                if today.isToday {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(context.date, format: .dateTime.hour().minute().second())
                            .font(.system(size: 15, weight: .medium)).monospacedDigit().foregroundStyle(AppAppearance.secondary)
                    }
                } else {
                    Button("Back to today") { today.show(Date()) }.buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(AppAppearance.blue)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                stepButton("chevron.left", "Previous day", enabled: true) { today.step(-1) }
                DayPill(today: today)
                stepButton("chevron.right", "Next day", enabled: today.canGoForward) { today.step(1) }
            }
        }
        .padding(28)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(AppAppearance.surface)
                .shadow(color: AppAppearance.shadow, radius: 14, y: 4)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [AppAppearance.blue.opacity(0.07), .clear, HomeStyle.heroWash],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(AppAppearance.separator))
    }
    private func stepButton(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 32, height: 32)
                .background(AppAppearance.raised, in: Circle())
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35).help(label).accessibilityLabel(label)
    }
}

/// The selected day as a pill; click for a calendar.
private struct DayPill: View {
    var today: TodayStore
    @State private var open = false
    @State private var hovering = false
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: "calendar").font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                Text(today.isToday ? "Today" : today.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 14).frame(height: 32)
            .background(hovering ? AppAppearance.raised : AppAppearance.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(AppAppearance.separator))
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.help("Pick a day")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            DatePicker("Day", selection: Binding(get: { today.day }, set: { today.show($0); open = false }), in: ...Date(), displayedComponents: .date)
                .labelsHidden().datePickerStyle(.graphical).padding(14)
        }
    }
}

struct TodayChatGroup: View {
    var title: String
    var color: Color
    var rows: [TodayRow]
    var open: (TodayRow) -> Void
    @State private var expanded = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(AppAppearance.tertiary)
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text("\(rows.count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().overlay(AppAppearance.separator).padding(.leading, 60) }
                        TodayChatRow(row: row) { open(row) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: HomeStyle.cardRadius, style: .continuous))
                .modifier(SoftSurface(radius: HomeStyle.cardRadius, shadowRadius: 8, y: 2))
            }
        }
    }
}

private struct TodayChatRow: View {
    var row: TodayRow
    var open: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 12) {
                Group {
                    if let session = row.session { AgentAvatar(session: session, active: hovering, size: 30) }
                    else { Image(systemName: row.provider == .codex ? "terminal" : "sparkle").frame(width: 30, height: 30)
                        .foregroundStyle(AppAppearance.tertiary) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(row.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).foregroundStyle(AppAppearance.text)
                        Text(row.breadcrumb).font(.system(size: 12)).lineLimit(1).foregroundStyle(AppAppearance.tertiary)
                    }
                    if let preview = row.preview {
                        Text(preview).font(.system(size: 12)).lineLimit(1).foregroundStyle(AppAppearance.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(row.lastAt, format: .dateTime.hour().minute()).font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(AppAppearance.tertiary)
                Circle().fill(row.status.color).frame(width: 7, height: 7).opacity(row.status == .idle ? 0.5 : 1)
            }
            .padding(.horizontal, 16).padding(.vertical, row.preview == nil ? 11 : 9)
            .background(hovering ? AppAppearance.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.disabled(row.session == nil)
        .help(row.session == nil ? "Not in the live feed any more" : (row.session?.chatURL == nil ? "Show details in Burro" : "Open the chat"))
    }
}

// MARK: Summary

/// A card titled by a coloured label; it sizes to its content.
struct TodayCard<Content: View>: View {
    var title: String
    var symbol: String
    var color: Color
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
            content()
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .topLeading)
        .modifier(AppCardSurface(radius: HomeStyle.cardRadius))
    }
}

/// The day's numbers in one row of compact tiles that wraps on narrow windows. With tracking on,
/// tracked focus is the headline; the time from your first to your last message is a secondary fact
/// in the hours card. With tracking off, that span leads instead ("With agents").
struct TodaySummaryRow: View {
    struct Todos { var done: Int; var open: Int; var added: Int }
    var activity: DailyActivity?
    var tracked: ActivityDay?
    var tracking: Bool
    var isToday: Bool
    /// Today only.
    var todos: Todos?
    var waitingNow: Int

    var body: some View {
        TileGrid(minWidth: 120, spacing: 10) {
            if tracking { trackedTiles } else { chatSpanTile }
            TodayTile(title: "Messages", symbol: "bubble.left", color: AppAppearance.blue,
                      value: activity.map { "\($0.turns)" } ?? "—",
                      caption: activity.map { "sent · \($0.replies) replies" } ?? "sent · replies")
                .help("Messages you sent and agent replies, across Codex and Claude on this Mac.")
            if let todos {
                TodayTile(title: "To-dos", symbol: "checklist", color: AppAppearance.green, value: "\(todos.done)",
                          caption: "done · \(todos.open) open", valueColor: todos.done > 0 ? AppAppearance.green : nil)
                    .help("Done today, still open, and \(todos.added) added today.")
            }
            let decision = TodaySummary.decisions(asked: activity?.questions ?? 0, waitingNow: waitingNow)
            TodayTile(title: "Questions", symbol: "questionmark.bubble", color: AppAppearance.amber,
                      value: decision.asked > 0 ? "\(decision.answered)/\(decision.asked)" : "0",
                      caption: waitingNow > 0 ? "answered · \(waitingNow) waiting" : "answered")
                .help("Explicit questions agents asked (Codex request_user_input, Claude AskUserQuestion) and chats waiting on you now. Approval prompts aren't logged by the tools, so they aren't included.")
        }
    }

    @ViewBuilder private var trackedTiles: some View {
        let day = tracked.flatMap { $0.total > 0 ? $0 : nil }
        let breakTime = day?.categories.first { $0.category == .break }?.seconds ?? 0
        let longest = day?.focus.longest
        TodayTile(title: "Focused", symbol: "scope", color: AppAppearance.amber, value: day.map { TodaySummary.duration($0.focused) } ?? "—",
                  caption: "outside Break")
            .help("Tracked time outside Break on this Mac.")
        TodayTile(title: "Tracked", symbol: "waveform.path.ecg", color: AppAppearance.secondary,
                  value: day.map { TodaySummary.duration($0.total) } ?? "—", caption: "at this Mac")
            .help("Everything Burro recorded; idle time and the lock screen don't count.")
        TodayTile(title: "Break", symbol: "cup.and.saucer", color: ActivityStyle.color(.break),
                  value: day.map { _ in TodaySummary.duration(breakTime) } ?? "—",
                  caption: day.map { breakTime > 0 ? "\(Int((breakTime / $0.total * 100).rounded()))% of tracked" : "none\(isToday ? " yet" : "")" } ?? "of tracked")
        TodayTile(title: "Longest focus", symbol: "timer", color: AppAppearance.amber,
                  value: longest.map { TodaySummary.duration($0.duration) } ?? "—",
                  caption: longest.map { ActivityStyle.range($0.start, $0.end) } ?? "no stretch yet")
            .help("A focus stretch is time outside Break; idle time or a break under 2 minutes doesn't end it.")
    }

    @ViewBuilder private var chatSpanTile: some View {
        TodayTile(title: "With agents", symbol: "clock", color: AppAppearance.amber,
                  value: activity?.span.map(TodaySummary.duration) ?? "—",
                  caption: activity?.firstTurn.flatMap { first in activity?.lastTurn.map { ActivityStyle.range(first, $0) } }
                      ?? (activity == nil ? "reading your logs…" : "no messages yet"))
            .help("From your first to your last message to an agent.")
    }
}

/// One stat: a coloured label, a number and one line of context.
struct TodayTile: View {
    var title: String
    var symbol: String
    var color: Color
    var value: String
    var caption: String
    var valueColor: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color).lineLimit(1)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(value == "—" ? AppAppearance.tertiary : valueColor ?? AppAppearance.text)
            Text(caption).font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(AppCardSurface(radius: HomeStyle.cardRadius))
        .accessibilityElement(children: .combine)
    }
}

/// Equal-width tiles in as few rows as fit, balanced (7 tiles that need two rows go 4 + 3); each
/// row is as tall as its tallest tile.
struct TileGrid: SwiftUI.Layout {
    var minWidth: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minWidth * CGFloat(subviews.count)
        let grid = arrange(width: width, subviews)
        return CGSize(width: width, height: grid.heights.reduce(0, +) + spacing * CGFloat(max(0, grid.heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = arrange(width: bounds.width, subviews)
        var y = bounds.minY
        for (row, height) in grid.heights.enumerated() {
            for column in 0..<grid.columns {
                let index = row * grid.columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (grid.width + spacing), y: y),
                                      proposal: ProposedViewSize(width: grid.width, height: height))
            }
            y += height + spacing
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (columns: Int, width: CGFloat, heights: [CGFloat]) {
        guard !subviews.isEmpty else { return (1, width, []) }
        let fit = max(1, Int((width + spacing) / (minWidth + spacing)))
        let rows = Int((Double(subviews.count) / Double(fit)).rounded(.up))
        let columns = Int((Double(subviews.count) / Double(rows)).rounded(.up))
        let tile = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let heights = (0..<rows).map { row in
            (row * columns..<min(subviews.count, (row + 1) * columns)).map {
                subviews[$0].sizeThatFits(ProposedViewSize(width: tile, height: nil)).height
            }.max() ?? 0
        }
        return (columns, tile, heights)
    }
}

/// One cell per hour: shade = messages you sent; a thin line under each hour in the colour of
/// that hour's main tracked category. The first-to-last-message span is named here as a fact.
struct TodayHoursCard: View {
    var activity: DailyActivity?
    var tracked: ActivityDay?
    var isToday: Bool
    /// Fixed only for snapshots.
    var now: Date? = nil

    var body: some View {
        let hours = TodaySummary.hours(activity: activity, tracked: tracked)
        let peak = max(1, hours.map(\.turns).max() ?? 1)
        let currentHour = isToday ? Calendar.current.component(.hour, from: now ?? Date()) : nil
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("Your hours", systemImage: "clock").font(.system(size: 13, weight: .semibold)).foregroundStyle(AppAppearance.secondary)
                Spacer(minLength: 8)
                Text(span).font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.tertiary).lineLimit(1)
            }
            HStack(spacing: 3) {
                ForEach(hours, id: \.hour) { hour in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(hour.turns > 0 ? AppAppearance.amber.opacity(0.25 + 0.75 * Double(hour.turns) / Double(peak)) : AppAppearance.raised)
                            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(hour.hour == currentHour ? AppAppearance.text.opacity(0.5) : .clear, lineWidth: 1.2))
                            .frame(height: 20)
                        RoundedRectangle(cornerRadius: 1.5).fill(hour.category.map(ActivityStyle.color) ?? .clear).frame(height: 3)
                    }
                    .help(help(hour))
                }
            }
            HStack {
                ForEach([0, 6, 12, 18, 24], id: \.self) { mark in
                    Text("\(mark)").font(.system(size: 10)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                    if mark < 24 { Spacer() }
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(AppCardSurface(radius: HomeStyle.cardRadius))
    }

    private var span: String {
        guard let activity else { return "Reading your agent logs…" }
        guard let first = activity.firstTurn, let last = activity.lastTurn else { return "No messages from you yet" }
        return "Chatting with agents \(ActivityStyle.range(first, last))"
    }

    private func help(_ hour: TodayHour) -> String {
        var text = "\(hour.hour):00 — \(hour.turns) message\(hour.turns == 1 ? "" : "s") from you, \(hour.replies) replies"
        if let category = hour.category { text += "\nMostly \(category.title)" }
        return text
    }
}

enum TodayDayStart { static var millis: Double { BurroCore.TodoDay.startMillis() } }
