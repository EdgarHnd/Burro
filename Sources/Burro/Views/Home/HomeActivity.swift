// Home's "Today so far" card: the day Burro tracked on this Mac at a glance, shown only while
// tracking is on. Click it to open the Today page. It reads today through the tracker (the day's
// small file plus unsaved time) when Home comes on screen and then once a minute while Home stays
// on screen; it starts no other work. Everything shown came through ActivityPrivacy.
import SwiftUI
import BurroCore

struct HomeActivityCard: View {
    var tracker: ActivityTracker
    /// Home is on screen; reads stop when it isn't.
    var active: Bool
    /// Fixed only for snapshots; otherwise the time of the last read.
    var now: Date?
    var open: () -> Void
    @State private var day: ActivityDay?
    @State private var readAt = Date()

    init(tracker: ActivityTracker, active: Bool, day: ActivityDay? = nil, now: Date? = nil, open: @escaping () -> Void) {
        self.tracker = tracker
        self.active = active
        self.now = now
        self.open = open
        _day = State(initialValue: day)
    }

    var body: some View {
        Button(action: open) {
            content.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(HomeCardButtonStyle())
        .help("Open Today")
        .task(id: active) {
            while active && !Task.isCancelled {
                day = await tracker.day(Date())
                readAt = Date()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(Color.indigo, in: Circle())
                Text("Today so far").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.indigo)
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(tracker.paused ? AppAppearance.amber : AppAppearance.green).frame(width: 6, height: 6)
                    Text(tracker.paused ? "Paused" : "Recording")
                }.font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
            }
            if let day, day.total > 0 {
                summary(day)
            } else {
                Text(day == nil ? "Reading…" : tracker.paused ? "Paused. Nothing recorded yet today." : "Nothing recorded yet today.")
                    .font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
            }
        }
        .foregroundStyle(AppAppearance.text)
    }

    @ViewBuilder private func summary(_ day: ActivityDay) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(TodaySummary.duration(day.focused)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
                Text("focused").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(TodaySummary.duration(day.total)).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).foregroundStyle(AppAppearance.secondary)
                Text("tracked").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
            }
        }
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(day.categories) { item in
                    Rectangle().fill(ActivityStyle.color(item.category))
                        .frame(width: max(2, (geometry.size.width - 2 * CGFloat(day.categories.count - 1)) * item.seconds / day.total))
                }
            }
        }
        .frame(height: 6).clipShape(Capsule())
        .help(day.categories.prefix(4).map { "\($0.category.title) \(TodaySummary.duration($0.seconds))" }.joined(separator: " · "))
        if let entry = current(day) {
            HStack(spacing: 8) {
                ActivityAppIcon(bundleID: entry.bundleID, size: 16)
                Text(nowText(entry)).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text("now").font(.system(size: 11, weight: .medium)).foregroundStyle(AppAppearance.green)
            }
        }
        Divider().overlay(AppAppearance.separator)
        VStack(alignment: .leading, spacing: 7) {
            row("Break", color: ActivityStyle.color(.break),
                value: TodaySummary.duration(day.categories.first { $0.category == .break }?.seconds ?? 0), detail: nil)
            if let longest = day.focus.longest {
                row("Longest focus", color: AppAppearance.amber, value: TodaySummary.duration(longest.duration),
                    detail: ActivityStyle.range(longest.start, longest.end))
            }
        }
    }

    private func row(_ title: String, color: Color, value: String, detail: String?) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
            Spacer(minLength: 6)
            if let detail { Text(detail).font(.system(size: 11)).monospacedDigit().foregroundStyle(AppAppearance.tertiary).lineLimit(1) }
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit().lineLimit(1).fixedSize()
        }
    }

    /// The latest stretch, if it reaches the last read: what you're on right now.
    private func current(_ day: ActivityDay) -> ActivityDay.Entry? {
        guard tracker.recording, let last = day.entries.last, (now ?? readAt).timeIntervalSince(last.end) < 120 else { return nil }
        return last
    }

    private func nowText(_ entry: ActivityDay.Entry) -> String {
        if entry.category == .private { return "\(entry.app) · Private" }
        let place = entry.host ?? (entry.label == entry.app ? nil : entry.label)
        return place.map { "\(entry.app) · \($0)" } ?? entry.app
    }
}
