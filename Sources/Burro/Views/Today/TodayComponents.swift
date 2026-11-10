// Pieces of the Today page: the date header, chat groups and the stat cards. The tracked-activity
// card is in TodayActivity.swift.
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

// MARK: Stat cards

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
        .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(AppCardSurface(radius: HomeStyle.cardRadius))
    }
}

struct BigPair: View {
    var left: String
    var leftLabel: String
    var right: String? = nil
    var rightLabel: String? = nil
    var leftColor: Color = AppAppearance.text
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(left).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(left == "—" ? AppAppearance.tertiary : leftColor)
                Text(leftLabel).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
            }
            Spacer()
            if let right, let rightLabel {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(right).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(right == "—" ? AppAppearance.tertiary : AppAppearance.secondary)
                    Text(rightLabel).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                }
            }
        }
    }
}

struct TodayWorkedCard: View {
    var today: TodayStore
    var body: some View {
        let activity = today.activity, tracked = today.tracked
        let hours = TodaySummary.hours(activity: activity, tracked: tracked)
        let peak = max(1, hours.map(\.turns).max() ?? 1)
        let currentHour = today.isToday ? Calendar.current.component(.hour, from: Date()) : nil
        TodayCard(title: "Worked so far", symbol: "clock", color: AppAppearance.amber) {
            VStack(alignment: .leading, spacing: 4) {
                let worked = activity?.span.map(TodaySummary.duration) ?? tracked.flatMap { $0.focused > 0 ? TodaySummary.duration($0.focused) : nil }
                Text(worked ?? "—")
                    .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(worked == nil ? AppAppearance.tertiary : AppAppearance.text)
                Text(subtitle(activity, tracked)).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
            }
            HStack(spacing: 3) {
                ForEach(hours, id: \.hour) { hour in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(hour.turns > 0 ? AppAppearance.amber.opacity(0.25 + 0.75 * Double(hour.turns) / Double(peak)) : AppAppearance.raised)
                            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(hour.hour == currentHour ? AppAppearance.text.opacity(0.5) : .clear, lineWidth: 1.2))
                            .frame(height: 26)
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
    }
    private func subtitle(_ activity: DailyActivity?, _ tracked: ActivityDay?) -> String {
        var parts: [String] = []
        if let first = activity?.firstTurn, let last = activity?.lastTurn {
            parts.append("First message \(first.formatted(date: .omitted, time: .shortened)) · last \(last.formatted(date: .omitted, time: .shortened))")
        } else if activity == nil { parts.append("Reading your agent logs…") }
        else { parts.append("No messages from you yet") }
        if let tracked, tracked.focused > 0 { parts.append("Tracked: \(TodaySummary.duration(tracked.focused)) focused") }
        return parts.joined(separator: "\n")
    }
    private func help(_ hour: TodayHour) -> String {
        var text = "\(hour.hour):00 — \(hour.turns) message\(hour.turns == 1 ? "" : "s") from you, \(hour.replies) replies"
        if let category = hour.category { text += "\nMostly \(category.title)" }
        return text
    }
}

struct TodayMessagesCard: View {
    var activity: DailyActivity?
    var body: some View {
        TodayCard(title: "Messages", symbol: "bubble.left", color: AppAppearance.blue) {
            BigPair(left: activity.map { "\($0.turns)" } ?? "—", leftLabel: "sent",
                    right: activity.map { "\($0.replies)" } ?? "—", rightLabel: "replies")
            GeometryReader { geometry in
                let total = Double((activity?.turns ?? 0) + (activity?.replies ?? 0))
                let share = total > 0 ? Double(activity?.turns ?? 0) / total : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(AppAppearance.blue.opacity(0.15))
                    Capsule().fill(AppAppearance.blue).frame(width: max(share > 0 ? 6 : 0, geometry.size.width * share))
                }
            }.frame(height: 6)
        }
    }
}

struct TodayTodosCard: View {
    var todos: TodoStore
    var body: some View {
        let start = TodayDayStart.millis
        let done = todos.items.filter { $0.done }.count
        let open = todos.items.filter { !$0.done }.count
        let added = todos.items.filter { $0.createdAt >= start }.count
        TodayCard(title: "To-dos", symbol: "checklist", color: AppAppearance.green) {
            BigPair(left: "\(done)", leftLabel: "done today", right: "\(open)", rightLabel: "open", leftColor: AppAppearance.green)
            Divider().overlay(AppAppearance.separator)
            HStack { Text("Added today").foregroundStyle(AppAppearance.secondary); Spacer(); Text("\(added)").monospacedDigit() }
                .font(.system(size: 13))
        }
    }
}

enum TodayDayStart { static var millis: Double { BurroCore.TodoDay.startMillis() } }

struct TodayQuestionsCard: View {
    var asked: Int
    var waitingNow: Int
    var body: some View {
        let decision = TodaySummary.decisions(asked: asked, waitingNow: waitingNow)
        TodayCard(title: "Questions for you", symbol: "questionmark.bubble", color: AppAppearance.amber) {
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(AppAppearance.amber.opacity(0.15), lineWidth: 7)
                    Circle().trim(from: 0, to: decision.share ?? 0).stroke(AppAppearance.amber, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(decision.share.map { "\(Int(($0 * 100).rounded()))%" } ?? "—").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }.frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(decision.answered)").font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(AppAppearance.amber)
                    Text("answered").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                    Text("\(decision.asked) asked · \(waitingNow) waiting now").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                }
            }
            .help("Counts explicit questions (Codex request_user_input, Claude AskUserQuestion) and chats waiting on you now. Approval prompts aren't logged by the tools, so they aren't included.")
        }
    }
}

struct TodayChatsCard: View {
    var rows: [TodayRow]
    var body: some View {
        TodayCard(title: "Chats", symbol: "person.2", color: .indigo) {
            BigPair(left: "\(rows.count)", leftLabel: "active", right: "\(Set(rows.map(\.project)).count)", rightLabel: "places",
                    leftColor: .indigo)
        }
    }
}
