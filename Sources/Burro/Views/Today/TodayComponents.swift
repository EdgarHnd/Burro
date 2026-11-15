// Pieces of the Today page: the date header (on the page background, the time to the minute), the
// summary (one headline number and one quiet line of facts that wraps), the hours strip, and chat groups. The tracked-activity pieces are in
// TodayActivity.swift and TodayDayView.swift.
import SwiftUI
import BurroCore

struct TodayHeader: View {
    var today: TodayStore
    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(today.isToday ? "TODAY" : today.day.formatted(.dateTime.weekday(.wide)).uppercased())
                    .font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(AppAppearance.secondary)
                Text(today.day, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                if today.isToday {
                    TimelineView(.everyMinute) { context in
                        Text(context.date, format: .dateTime.hour().minute())
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
        .padding(.horizontal, 2)
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

/// The day's numbers as one headline and one line of facts. With tracking on, tracked focus is the
/// headline ("4h 58m focused of 6h 10m tracked"); with tracking off, the time from your first to your
/// last message leads instead ("With agents"). The facts line (Break, longest focus, messages, to-dos,
/// questions) leaves out anything with nothing to say and wraps on narrow windows. Questions waiting
/// on you now are the only amber.
struct TodaySummaryRow: View {
    struct Todos { var done: Int; var open: Int; var added: Int }
    var activity: DailyActivity?
    var tracked: ActivityDay?
    var tracking: Bool
    var isToday: Bool
    /// Today only.
    var todos: Todos?
    var waitingNow: Int

    struct Fact: Identifiable {
        var text: String
        var help: String
        var needsYou = false
        var id: String { text }
    }

    var body: some View {
        let facts = self.facts
        VStack(alignment: .leading, spacing: 6) {
            if tracking { trackedHeadline } else { chatSpanHeadline }
            if !facts.isEmpty {
                FlowLayout(spacing: 0) {
                    ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                        HStack(spacing: 0) {
                            if index > 0 { Text("  ·  ").foregroundStyle(AppAppearance.tertiary) }
                            Text(fact.text).foregroundStyle(fact.needsYou ? AppAppearance.amber : AppAppearance.secondary)
                                .help(fact.help)
                        }
                        .font(.system(size: 13)).monospacedDigit().lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var day: ActivityDay? { tracked.flatMap { $0.total > 0 ? $0 : nil } }

    @ViewBuilder private var trackedHeadline: some View {
        headline(value: day.map { TodaySummary.duration($0.focused) },
                 caption: day.map { "focused of \(TodaySummary.duration($0.total)) tracked" } ?? "focused · nothing tracked\(isToday ? " yet" : "")")
            .help("Focused: tracked time outside Break on this Mac. Tracked: everything Burro recorded; idle time and the lock screen don't count.")
    }

    @ViewBuilder private var chatSpanHeadline: some View {
        headline(value: activity?.span.map(TodaySummary.duration),
                 caption: activity?.firstTurn.flatMap { first in activity?.lastTurn.map { "with agents, \(ActivityStyle.range(first, $0))" } }
                     ?? (activity == nil ? "with agents · reading your logs…" : "with agents · no messages yet"))
            .help("From your first to your last message to an agent.")
    }

    /// A large number with its caption on the same baseline; the caption wraps under itself if it must.
    private func headline(value: String?, caption: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(value ?? "—").font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(value == nil ? AppAppearance.tertiary : AppAppearance.text)
                .lineLimit(1).fixedSize()
            Text(caption).font(.system(size: 15)).foregroundStyle(AppAppearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    var facts: [Fact] {
        var facts: [Fact] = []
        if tracking, let note = tracked?.notRecordedNote {
            facts.append(Fact(text: note, help: "Burro was closed or tracking was paused then, so nothing was recorded. Time away from the Mac isn't counted here."))
        }
        if tracking, let day {
            let breakTime = day.categories.first { $0.category == .break }?.seconds ?? 0
            if breakTime >= 60 {
                facts.append(Fact(text: "Break \(TodaySummary.duration(breakTime))",
                                  help: "\(Int((breakTime / day.total * 100).rounded()))% of tracked time went to Break."))
            }
            if let longest = day.focus.longest {
                facts.append(Fact(text: "Longest focus \(TodaySummary.duration(longest.duration)) (\(ActivityStyle.range(longest.start, longest.end)))",
                                  help: "A focus stretch is time outside Break; idle time or a break under 2 minutes doesn't end it."))
            }
        }
        if let activity {
            let help = "Messages you sent and agent replies, across Codex and Claude on this Mac."
            if activity.turns > 0 { facts.append(Fact(text: "\(activity.turns) sent", help: help)) }
            if activity.replies > 0 { facts.append(Fact(text: "\(activity.replies) repl\(activity.replies == 1 ? "y" : "ies")", help: help)) }
        }
        if let todos, todos.done + todos.open > 0 {
            facts.append(Fact(text: "\(todos.done)/\(todos.done + todos.open) to-dos",
                              help: "\(todos.done) done today, \(todos.open) still open, and \(todos.added) added today."))
        }
        let decision = TodaySummary.decisions(asked: activity?.questions ?? 0, waitingNow: waitingNow)
        let questionsHelp = "Explicit questions agents asked (Codex request_user_input, Claude AskUserQuestion) and chats waiting on you now. Approval prompts aren't logged by the tools, so they aren't included."
        if decision.answered > 0 {
            facts.append(Fact(text: "\(decision.answered) question\(decision.answered == 1 ? "" : "s") answered", help: questionsHelp))
        }
        if waitingNow > 0 {
            facts.append(Fact(text: "\(waitingNow) question\(waitingNow == 1 ? "" : "s") waiting", help: questionsHelp, needsYou: true))
        }
        return facts
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
                            .fill(hour.turns > 0 ? AppAppearance.text.opacity(0.14 + 0.5 * Double(hour.turns) / Double(peak)) : AppAppearance.raised)
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
