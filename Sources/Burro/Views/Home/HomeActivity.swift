// Home's "Today so far" card: the day Burro tracked on this Mac at a glance, shown only while
// tracking is on: Recording or Paused, time focused of time tracked, a thin strip of the day's
// categories, and, only when a value is passed in, "Agents worked 2h 40m while you were away"
// ("about 2h 40m", with a tooltip, when some chats couldn't be read; computed elsewhere from the Today scan;
// nil draws nothing). Click it to open the Today page. It draws the tracked day it is given
// (TodayStore reads it, every 2 minutes while Home is on screen) and starts no work of its own.
// Everything shown came through ActivityPrivacy.
import SwiftUI
import BurroCore

struct HomeActivityCard: View {
    var tracker: ActivityTracker
    /// Today's tracked day; nil while it hasn't been read.
    var day: ActivityDay?
    /// Fixed only for snapshots.
    var now: Date?
    /// Agent-active time while you were away (Burro recording, you not there), when the Today scan has it.
    var awayAgentTime: TimeInterval?
    /// `awayAgentTime` is approximate: worded "about".
    var awayPartial = false
    var open: () -> Void

    init(tracker: ActivityTracker, day: ActivityDay? = nil, now: Date? = nil, awayAgentTime: TimeInterval? = nil, awayPartial: Bool = false,
         open: @escaping () -> Void) {
        self.tracker = tracker
        self.day = day
        self.awayAgentTime = awayAgentTime
        self.awayPartial = awayPartial
        self.now = now
        self.open = open
    }

    var body: some View {
        Button(action: open) {
            content.padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(HomeCardButtonStyle(radius: AppAppearance.cardRadius))
        .help("Open Today")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionLabel(title: "Today so far") {
                Text(tracker.paused ? "Paused" : "Recording").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tracker.paused ? AppAppearance.tertiary : AppAppearance.green)
            }
            if let day, day.total > 0 {
                summary(day)
            } else {
                Text(day == nil ? "Reading…" : tracker.paused ? "Paused. Nothing recorded yet today." : "Nothing recorded yet today.")
                    .font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
            }
            if let away = awayAgentTime, away >= 60 {
                Text("Agents worked \(AgentAwayTime.phrase(away, partial: awayPartial)) while you were away")
                    .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).fixedSize(horizontal: false, vertical: true)
                    .help(awayPartial ? "Some chats couldn't be read, so this is approximate." : "Wall-clock time any agent was active while Burro was recording and you weren't at the Mac.")
            }
        }
        .foregroundStyle(AppAppearance.text)
    }

    @ViewBuilder private func summary(_ day: ActivityDay) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(TodaySummary.duration(day.focused)).font(.system(size: 26, weight: .bold)).monospacedDigit().lineLimit(1)
            Text("focused of \(TodaySummary.duration(day.total))").font(.system(size: 13)).monospacedDigit()
                .foregroundStyle(AppAppearance.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(day.categories) { item in
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(ActivityStyle.color(item.category))
                        .frame(width: max(2, (geometry.size.width - 2 * CGFloat(day.categories.count - 1)) * item.seconds / day.total))
                }
            }
        }
        .frame(height: 10)
        .help(day.categories.prefix(4).map { "\($0.category.title) \(TodaySummary.duration($0.seconds))" }.joined(separator: " · "))
        .accessibilityLabel(day.categories.prefix(4).map { "\($0.category.title) \(TodaySummary.duration($0.seconds))" }.joined(separator: ", "))
    }
}
