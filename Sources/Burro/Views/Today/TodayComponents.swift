// Pieces of the Today page: the date header (on the page background, the time to the minute; the
// arrow keys step a day) and the summary (one headline number and one quiet line of facts that
// wraps, led by the agents' time while you were away when there is any). The tracked-activity
// pieces are in TodayActivity.swift and TodayDayView.swift; the ribbon, cards and chat columns in
// TodayRibbon.swift and TodayCards.swift.
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
                    .font(.system(size: 28, weight: .bold, design: .rounded))
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
                stepButton("chevron.left", "Previous day", key: .leftArrow, enabled: true) { today.step(-1) }
                DayPill(today: today)
                stepButton("chevron.right", "Next day", key: .rightArrow, enabled: today.canGoForward) { today.step(1) }
            }
        }
        .padding(.horizontal, 2)
    }
    private func stepButton(_ symbol: String, _ label: String, key: KeyEquivalent, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 32, height: 32)
                .background(AppAppearance.raised, in: Circle())
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .keyboardShortcut(key, modifiers: [])
        .help("\(label) (\(key == .leftArrow ? "←" : "→"))").accessibilityLabel(label)
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
/// questions) leaves out anything with nothing to say and wraps on narrow windows; it starts with
/// "Agents worked 2h 40m while you were away" ("about 2h 40m" when partial) when tracking can tell. Questions waiting on you now
/// are the only amber.
struct TodaySummaryRow: View {
    struct Todos { var done: Int; var open: Int; var added: Int }
    var activity: DailyActivity?
    var tracked: ActivityDay?
    var tracking: Bool
    var isToday: Bool
    /// Today only.
    var todos: Todos?
    var waitingNow: Int
    /// Agent work while you were away, from AgentAwayTime.
    var away: AgentAwayTime.Summary? = nil

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
        if tracking, let away, away.total >= 60 {
            facts.append(Fact(text: "Agents worked \(away.totalText) while you were away",
                              help: "Wall-clock time any agent was active while Burro was recording and you weren't at the Mac"
                                  + (away.span.map { " (\(ActivityStyle.range($0.start, $0.end)))" } ?? "") + "; time Burro wasn't recording isn't counted."
                                  + (away.partial ? " Some chats couldn't be read, so this is approximate." : "")))
        }
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

enum TodayDayStart { static var millis: Double { BurroCore.TodoDay.startMillis() } }
