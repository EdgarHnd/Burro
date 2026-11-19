// Pieces of the Today page: the header's day stepper (← the day pill →; the arrow keys step a day),
// the titled card the List view's side card uses, and the tracked day's smaller facts. The lanes are
// in AgentLanes.swift, the panel contents in TodayCards.swift, the tracked-activity pieces in
// TodayActivity.swift and TodayDayView.swift.
import SwiftUI
import BurroCore

/// The header's trailing control: ← the day pill (a calendar) →, the arrow keys step a day; a past
/// day adds "Back to today".
struct TodayDayStepper: View {
    var today: TodayStore
    var body: some View {
        HStack(spacing: 8) {
            if !today.isToday {
                Button("Back to today") { today.show(Date()) }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary).padding(.trailing, 4)
            }
            stepButton("chevron.left", "Previous day", key: .leftArrow, enabled: true) { today.step(-1) }
            DayPill(today: today)
            stepButton("chevron.right", "Next day", key: .rightArrow, enabled: today.canGoForward) { today.step(1) }
        }
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

/// The tracked day's smaller facts, which the Most time panel's subtitle carries: the not-recorded
/// note, the longest focus stretch and Break.
enum TodayFacts {
    static func tracked(_ day: ActivityDay?) -> [TextRun] {
        guard let day else { return [] }
        var parts: [String] = []
        if let note = day.notRecordedNote { parts.append(note) }
        if day.total > 0, let longest = day.focus.longest {
            parts.append("Longest focus \(TodaySummary.duration(longest.duration)) (\(ActivityStyle.range(longest.start, longest.end)))")
        }
        let breakTime = day.categories.first { $0.category == .break }?.seconds ?? 0
        if breakTime >= 60 { parts.append("Break \(TodaySummary.duration(breakTime))") }
        return parts.isEmpty ? [] : [TextRun(parts.joined(separator: " · "))]
    }
}

enum TodayDayStart { static var millis: Double { BurroCore.TodoDay.startMillis() } }
