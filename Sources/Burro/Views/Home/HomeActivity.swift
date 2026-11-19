// The thin strip of today's tracked categories under Home's "Focused today" figure (the KPI strip's
// fourth cell while activity tracking is on; HomeComposition's `HomeStats` has its words). It used
// to sit in the "Today so far" card, which the strip replaced. It draws the tracked day it is given
// (TodayStore reads it, every 2 minutes while Home is on screen) and starts no work of its own.
// Everything shown came through ActivityPrivacy.
import SwiftUI
import BurroCore

struct ActivityCategoryBar: View {
    var day: ActivityDay
    var height: CGFloat = 6

    var body: some View {
        let text = day.categories.prefix(4).map { "\($0.category.title) \(TodaySummary.duration($0.seconds))" }
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(day.categories) { item in
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(ActivityStyle.color(item.category))
                        .frame(width: max(2, (geometry.size.width - 2 * CGFloat(day.categories.count - 1)) * item.seconds / max(1, day.total)))
                }
            }
        }
        .frame(height: height)
        .help(text.joined(separator: " · "))
        .accessibilityLabel(text.joined(separator: ", "))
    }
}
