// The Today page's day view while activity tracking is on: the controls, a timeline of the day's
// blocks (ActivityTimeline in BurroCore groups the spans; idle time stays empty) and three cards:
// Your day so far (a donut of categories and the apps and sites with the most time), Your focus
// (focused time and the longest focus stretch on a strip of the day's stretches) and Break so far.
// The cards sit beside the timeline on wide windows and below it on narrow ones. Right-click a
// block or an app/site row to change its category or treat a site as private. Everything shown
// came through ActivityPrivacy; this file stores nothing and sends nothing anywhere.
import SwiftUI
import BurroCore

struct TodayDaySection: View {
    var today: TodayStore
    /// Fixed only for snapshots; otherwise the time of this render.
    var now: Date? = nil
    private var tracker: ActivityTracker { today.tracker }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("ACTIVITY").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
                ActivityControls(today: today)
            }.padding(.horizontal, 2)
            if !tracker.accessibilityTrusted { ActivityAccessPrompt(tracker: tracker).padding(.horizontal, 2) }
            if let day = today.tracked, day.total > 0 {
                TodayDayContent(day: day, isToday: today.isToday, now: now ?? Date(), tracker: tracker)
            } else {
                HomeEmptyCard(symbol: "waveform.path.ecg",
                              title: today.tracked == nil ? "Reading…" : today.isToday ? "Nothing recorded yet today" : "Nothing recorded that day",
                              detail: today.isToday && tracker.recording ? "Your day fills in here as you work. Time away stays empty."
                                  : today.isToday ? "Resume to record the rest of today." : "Pick another day, or come back to today.") { EmptyView() }
            }
        }
    }
}

/// The timeline with the three cards beside it (wide) or under it (narrow).
struct TodayDayContent: View {
    var day: ActivityDay
    var isToday: Bool
    var now: Date
    var tracker: ActivityTracker
    @State private var width: CGFloat = 900
    @State private var sideHeight: CGFloat?
    static let sideBySide: CGFloat = 700

    var body: some View {
        let wide = width >= Self.sideBySide
        Group {
            if wide {
                HStack(alignment: .top, spacing: 14) {
                    // On wide windows the timeline grows to the side column's height before it scrolls.
                    ActivityTimelineCard(day: day, isToday: isToday, now: now, tracker: tracker, available: sideHeight)
                    VStack(spacing: 14) {
                        ActivitySoFarCard(day: day, isToday: isToday, tracker: tracker, compact: true)
                        ActivityFocusCard(day: day, isToday: isToday, now: now)
                        ActivityBreakCard(day: day, isToday: isToday, tracker: tracker)
                    }
                    .frame(width: 272)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { sideHeight = $0 }
                }
            } else {
                VStack(spacing: 14) {
                    ActivityTimelineCard(day: day, isToday: isToday, now: now, tracker: tracker, available: nil)
                    ActivitySoFarCard(day: day, isToday: isToday, tracker: tracker, compact: false)
                    if width >= 540 {
                        HStack(alignment: .top, spacing: 14) {
                            ActivityFocusCard(day: day, isToday: isToday, now: now).frame(maxHeight: .infinity, alignment: .top)
                            ActivityBreakCard(day: day, isToday: isToday, tracker: tracker).frame(maxHeight: .infinity, alignment: .top)
                        }.fixedSize(horizontal: false, vertical: true)
                    } else {
                        ActivityFocusCard(day: day, isToday: isToday, now: now)
                        ActivityBreakCard(day: day, isToday: isToday, tracker: tracker)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }
}

// MARK: Timeline

struct ActivityTimelineCard: View {
    var day: ActivityDay
    var isToday: Bool
    var now: Date
    var tracker: ActivityTracker
    /// The card's height to fill before scrolling (the side column's), or nil for the default cap.
    var available: CGFloat?
    @State private var chrome: CGFloat = 80
    static let hourHeight: CGFloat = 72
    static let minBlock: CGFloat = 28
    static let maxHeight: CGFloat = 560
    private static let gutter: CGFloat = 50

    var body: some View {
        let layout = TimelineLayout(blocks: day.blocks, now: isToday ? now : nil, hourHeight: Self.hourHeight, minHeight: Self.minBlock)
        let cap = available.map { max(320, $0 - chrome - 36 - 12) } ?? Self.maxHeight
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Timeline", systemImage: "calendar.day.timeline.left").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppAppearance.secondary)
                Spacer()
                Text("\(day.blocks.count) block\(day.blocks.count == 1 ? "" : "s")").font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(AppAppearance.tertiary)
            }
            FlowLayout(spacing: 6) {
                ForEach(day.categories) { item in
                    HStack(spacing: 5) {
                        Circle().fill(ActivityStyle.color(item.category)).frame(width: 7, height: 7)
                        Text(item.category.title).font(.system(size: 11, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                    }
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(AppAppearance.raised, in: Capsule())
                    .help("\(item.category.title): \(TodaySummary.duration(item.seconds))")
                }
            }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { chrome = $0 }
            // Today opens at the bottom, where "now" is; past days open at their first block.
            ScrollView(.vertical) {
                canvas(layout).padding(.vertical, 8)
            }
            .scrollIndicators(.automatic)
            .defaultScrollAnchor(isToday ? .bottom : .top)
            .id(day.day)
            .frame(height: min(layout.height + 16, cap))
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(AppCardSurface(radius: HomeStyle.cardRadius))
    }

    private func canvas(_ layout: TimelineLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.marks, id: \.date) { mark in
                HStack(spacing: 8) {
                    Text(mark.date, format: .dateTime.hour()).font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .foregroundStyle(AppAppearance.tertiary).lineLimit(1).frame(width: Self.gutter - 8, alignment: .trailing)
                    Rectangle().fill(AppAppearance.separator).frame(height: 1)
                }
                .frame(height: 12).padding(.top, max(0, mark.y - 6))
            }
            ForEach(layout.placed) { placed in
                ActivityBlockView(block: placed.block, height: placed.height - 3, tracker: tracker)
                    .frame(height: placed.height - 3)
                    .padding(.leading, Self.gutter).padding(.top, placed.y + 1.5)
            }
            if let y = layout.nowY {
                HStack(spacing: 0) {
                    Circle().fill(AppAppearance.amber).frame(width: 7, height: 7)
                    Rectangle().fill(AppAppearance.amber).frame(height: 1.5)
                }
                .padding(.leading, Self.gutter - 4).padding(.top, max(0, y - 3.5))
                .allowsHitTesting(false)
                .accessibilityLabel("Now")
            }
        }
        .frame(maxWidth: .infinity, minHeight: layout.height, alignment: .topLeading)
    }
}

/// Where each block and hour line goes. Blocks get at least `minHeight`, so the axis stretches
/// a little around short blocks instead of letting them overlap; hour lines follow the same
/// stretched scale, so a label always sits at its true time relative to the blocks.
struct TimelineLayout {
    struct Placed: Identifiable {
        var block: ActivityBlock
        var y: CGFloat
        var height: CGFloat
        var id: TimeInterval { block.id }
    }
    struct Mark { var date: Date; var y: CGFloat }
    private(set) var placed: [Placed] = []
    private(set) var marks: [Mark] = []
    private(set) var height: CGFloat = 0
    private(set) var nowY: CGFloat?
    private var anchors: [(date: Date, y: CGFloat)] = []

    init(blocks: [ActivityBlock], now: Date?, hourHeight: CGFloat, minHeight: CGFloat, calendar: Calendar = .current) {
        guard let first = blocks.first, let last = blocks.map(\.end).max() else { return }
        let perSecond = hourHeight / 3600
        let from = calendar.dateInterval(of: .hour, for: first.start)?.start ?? first.start
        let latest = max(last, now ?? last)
        let lastHour = calendar.dateInterval(of: .hour, for: latest)?.start ?? latest
        let to = lastHour == latest ? latest : (calendar.date(byAdding: .hour, value: 1, to: lastHour) ?? latest)
        var time = from, y: CGFloat = 0
        anchors.append((from, 0))
        for block in blocks {
            y += max(0, block.start.timeIntervalSince(time)) * perSecond
            let height = max(minHeight, block.duration * perSecond)
            anchors.append((max(time, block.start), y))
            placed.append(Placed(block: block, y: y, height: height))
            y += height
            time = max(time, block.end)
            anchors.append((time, y))
        }
        y += max(0, to.timeIntervalSince(time)) * perSecond
        anchors.append((to, y))
        height = y
        var hour = from
        while hour <= to {
            marks.append(Mark(date: hour, y: map(hour)))
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hour) else { break }
            hour = next
        }
        if let now, now >= from, now <= to { nowY = map(now) }
    }

    /// Time to height along the stretched scale.
    func map(_ date: Date) -> CGFloat {
        guard let after = anchors.firstIndex(where: { $0.date >= date }) else { return anchors.last?.y ?? 0 }
        guard after > 0 else { return anchors[0].y }
        let a = anchors[after - 1], b = anchors[after]
        let span = b.date.timeIntervalSince(a.date)
        return span > 0 ? a.y + (b.y - a.y) * date.timeIntervalSince(a.date) / span : b.y
    }
}

/// One block: tinted by category with a coloured left edge, the app's icon, a one-line title and its time range.
struct ActivityBlockView: View {
    var block: ActivityBlock
    var height: CGFloat
    var tracker: ActivityTracker
    @State private var hovering = false

    var body: some View {
        let color = ActivityStyle.color(block.category)
        let tall = height >= 44
        HStack(alignment: tall ? .top : .center, spacing: 8) {
            ActivityAppIcon(bundleID: block.main?.bundleID ?? (block.category == .private ? block.apps.first?.bundleID : nil), size: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(block.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppAppearance.text)
                    .lineLimit(1).truncationMode(.tail)
                if tall {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(AppAppearance.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            Text(ActivityStyle.range(block.start, block.end)).font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(AppAppearance.secondary).lineLimit(1).fixedSize()
        }
        .padding(.leading, 11).padding(.trailing, 10).padding(.vertical, tall ? 7 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: tall ? .topLeading : .leading)
        .background(color.opacity(hovering ? 0.22 : 0.14))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .help(help)
        .contextMenu {
            if block.category != .private {
                if let main = block.main {
                    if !DayflowImport.isGroup(bundleID: main.bundleID) {
                        ActivityCategoryMenu(tracker: tracker, id: main.bundleID, name: main.name, site: false)
                    }
                    if let host = block.host { ActivityCategoryMenu(tracker: tracker, id: host, name: host, site: true) }
                } else {
                    ForEach(block.apps, id: \.bundleID) { app in
                        ActivityCategoryMenu(tracker: tracker, id: app.bundleID, name: app.name, site: false)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        ([block.category.title, TodaySummary.duration(block.seconds)] + [block.detail].compactMap { $0 }).joined(separator: " · ")
    }

    private var help: String {
        var lines = [block.title, "\(ActivityStyle.range(block.start, block.end)) · \(block.category.title) · \(TodaySummary.duration(block.seconds))"]
        if let detail = block.detail { lines.append(detail) }
        if block.main == nil && block.category != .private {
            lines.append(block.apps.map { "\($0.name) \(TodaySummary.duration($0.seconds))" }.joined(separator: ", "))
        }
        if block.category != .private { lines.append("Right-click to change its category") }
        return lines.joined(separator: "\n")
    }
}

/// Lays chips left to right, wrapping onto new rows.
struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, point) in zip(subviews, arrange(width: bounds.width, subviews).points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }
    private func arrange(width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + row))
    }
}

// MARK: Cards

/// The categories as a donut with the total in the middle, then the apps and sites with the most time.
struct ActivitySoFarCard: View {
    var day: ActivityDay
    var isToday: Bool
    var tracker: ActivityTracker
    var compact: Bool

    var body: some View {
        TodayCard(title: isToday ? "Your day so far" : "Your day", symbol: "chart.pie", color: AppAppearance.blue) {
            if compact {
                VStack(spacing: 14) { donut.frame(maxWidth: .infinity); legend }
            } else {
                HStack(alignment: .center, spacing: 22) { donut; legend.frame(maxWidth: 280) }
            }
            Divider().overlay(AppAppearance.separator)
            VStack(alignment: .leading, spacing: 7) {
                Text("MOST TIME").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(AppAppearance.tertiary)
                ForEach(day.apps.prefix(4)) { item in ActivityItemRow(tracker: tracker, item: item, site: false) }
                ForEach(day.sites.prefix(3)) { item in ActivityItemRow(tracker: tracker, item: item, site: true) }
            }
        }
    }

    private var donut: some View {
        ZStack {
            ActivityDonut(categories: day.categories, total: day.total)
            VStack(spacing: 1) {
                Text(TodaySummary.duration(day.total)).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text("tracked").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
            }.padding(.horizontal, 20)
        }
        .frame(width: 128, height: 128)
        .accessibilityElement(children: .combine)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(day.categories.prefix(6)) { item in
                HStack(spacing: 8) {
                    Circle().fill(ActivityStyle.color(item.category)).frame(width: 7, height: 7)
                    Text(item.category.title).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(TodaySummary.duration(item.seconds)).font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.secondary)
                }
                .help("\(Int((item.seconds / max(day.total, 1) * 100).rounded()))% of tracked time")
            }
            if day.categories.count > 6 {
                let rest = day.categories.dropFirst(6).reduce(0) { $0 + $1.seconds }
                HStack(spacing: 8) {
                    Circle().strokeBorder(AppAppearance.tertiary).frame(width: 7, height: 7)
                    Text("\(day.categories.count - 6) more").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                    Spacer(minLength: 6)
                    Text(TodaySummary.duration(rest)).font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.secondary)
                }
            }
        }.frame(maxWidth: .infinity)
    }
}

struct ActivityDonut: View {
    var categories: [ActivityDay.CategoryTime]
    var total: TimeInterval
    var lineWidth: CGFloat = 13

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2 - lineWidth / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            guard total > 0 else { return }
            let gap = categories.count > 1 ? 1.2 : 0
            var angle = -90.0
            for item in categories {
                let sweep = 360 * item.seconds / total
                defer { angle += sweep }
                guard sweep > gap else { continue }
                var path = Path()
                path.addArc(center: center, radius: radius, startAngle: .degrees(angle + gap / 2), endAngle: .degrees(angle + sweep - gap / 2), clockwise: false)
                context.stroke(path, with: .color(ActivityStyle.color(item.category)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
        }
        .background(Circle().stroke(AppAppearance.raised, lineWidth: lineWidth).padding(lineWidth / 2))
    }
}

/// Focused time (everything except Break) and the longest stretch, on a strip of the day's stretches.
struct ActivityFocusCard: View {
    var day: ActivityDay
    var isToday: Bool
    var now: Date

    var body: some View {
        let longest = day.focus.longest
        TodayCard(title: "Your focus", symbol: "scope", color: AppAppearance.amber) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(TodaySummary.duration(day.focused)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1)
                    Text("focused").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(longest.map { TodaySummary.duration($0.duration) } ?? "—").font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit().lineLimit(1).foregroundStyle(longest == nil ? AppAppearance.tertiary : AppAppearance.amber)
                    Text("longest stretch").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                }
            }
            if let first = day.blocks.first?.start, let last = day.blocks.map(\.end).max(), !day.focus.stretches.isEmpty {
                FocusStrip(stretches: day.focus.stretches, longest: longest, from: first, to: isToday ? max(last, now) : last)
                Text("\(day.focus.stretches.count) focus stretch\(day.focus.stretches.count == 1 ? "" : "es")")
                    .font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                    .help("A stretch is time outside Break; idle time or a break under 2 minutes doesn't end it.")
            }
        }
    }
}

struct FocusStrip: View {
    var stretches: [DateInterval]
    var longest: DateInterval?
    var from: Date
    var to: Date

    var body: some View {
        let span = max(1, to.timeIntervalSince(from))
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(AppAppearance.raised).frame(height: 4)
                    ForEach(stretches, id: \.start) { stretch in
                        let isLongest = stretch == longest
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(isLongest ? AppAppearance.amber : AppAppearance.amber.opacity(0.35))
                            .frame(width: max(2, width * stretch.duration / span), height: isLongest ? 22 : 14)
                            .padding(.leading, width * stretch.start.timeIntervalSince(from) / span)
                            .help("\(ActivityStyle.range(stretch.start, stretch.end)) · \(TodaySummary.duration(stretch.duration))")
                    }
                }.frame(height: 22)
            }.frame(height: 22)
            if let longest {
                GeometryReader { geometry in labels(longest, width: geometry.size.width, span: span) }.frame(height: 13)
            }
        }
    }

    /// The longest stretch's start under its left edge and end under its right edge, kept inside the strip.
    private func labels(_ longest: DateInterval, width: CGFloat, span: TimeInterval) -> some View {
        let start = longest.start.formatted(date: .omitted, time: .shortened), end = longest.end.formatted(date: .omitted, time: .shortened)
        let startWidth = CGFloat(start.count) * 6.4, endWidth = CGFloat(end.count) * 6.4
        let startX = width * longest.start.timeIntervalSince(from) / span, endX = width * longest.end.timeIntervalSince(from) / span
        let left = max(0, min(startX, width - startWidth - endWidth - 8))
        let right = min(width - endWidth, max(endX - endWidth, left + startWidth + 8))
        return HStack(spacing: 0) {
            Color.clear.frame(width: left)
            Text(start).frame(width: startWidth, alignment: .leading)
            Color.clear.frame(width: max(0, right - left - startWidth))
            Text(end).frame(width: endWidth, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(AppAppearance.amber).lineLimit(1).fixedSize(horizontal: false, vertical: true)
    }
}

/// Time on Break against everything tracked, and what it went to.
struct ActivityBreakCard: View {
    var day: ActivityDay
    var isToday: Bool
    var tracker: ActivityTracker

    var body: some View {
        let breakTime = day.categories.first { $0.category == .break }?.seconds ?? 0
        let share = day.total > 0 ? breakTime / day.total : 0
        let items = (day.apps.map { ($0, false) } + day.sites.map { ($0, true) }).filter { $0.0.category == .break }
            .sorted { $0.0.seconds > $1.0.seconds }.prefix(3)
        TodayCard(title: isToday ? "Break so far" : "Break", symbol: "cup.and.saucer", color: ActivityStyle.color(.break)) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(TodaySummary.duration(breakTime)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
                    Text("on Break").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(TodaySummary.duration(day.total)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).foregroundStyle(AppAppearance.secondary)
                    Text("tracked").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppAppearance.raised)
                    Capsule().fill(ActivityStyle.color(.break)).frame(width: share > 0 ? max(6, geometry.size.width * share) : 0)
                }
            }.frame(height: 6)
            Text(breakTime > 0 ? "\(Int((share * 100).rounded()))% of tracked time" : "No Break time\(isToday ? " yet" : "")")
                .font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(items), id: \.0.id) { item, site in ActivityItemRow(tracker: tracker, item: item, site: site) }
                }
            }
        }
    }
}
