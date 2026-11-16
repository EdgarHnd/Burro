// The Today page's List view while activity tracking is on: the controls (unless the page draws them), a timeline of the day's
// blocks (ActivityTimeline in BurroCore groups the spans; ActivityTimelineLayout places them, from
// the first block's hour to the last block or now, with long idle gaps as thin dividers) and Your
// day so far beside it at a matching height (a donut of categories, the apps and sites with the
// most time, the day's focus stretches and what Break went to). On a short day, whose timeline
// would leave the side card mostly empty, the timeline sizes to its content and Your day is one
// row beneath it; on narrow windows both stack. The headline numbers (focused, tracked, Break,
// longest focus) are in the page's summary.
// Right-click a block or an app/site row to change its category or treat a site as private.
// Everything shown came through ActivityPrivacy; this file stores nothing and sends nothing anywhere.
import SwiftUI
import BurroCore

struct TodayDaySection: View {
    var today: TodayStore
    /// Fixed only for snapshots; otherwise the time of this render.
    var now: Date? = nil
    /// The Today page draws the Activity row (with the Ribbon | List switch) itself.
    var showsHeader = true
    private var tracker: ActivityTracker { today.tracker }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader {
                HStack(spacing: 12) {
                    Text("ACTIVITY").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
                    ActivityControls(today: today)
                }.padding(.horizontal, 2)
                if !tracker.accessibilityTrusted { ActivityAccessPrompt(tracker: tracker).padding(.horizontal, 2) }
            }
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

/// The timeline with Your day so far beside it (wide, matching heights), or under it: as one row
/// on a short day at a wide width, stacked on narrow windows.
struct TodayDayContent: View {
    var day: ActivityDay
    var isToday: Bool
    var now: Date
    var tracker: ActivityTracker
    @State private var width: CGFloat = 900
    @State private var sideHeight: CGFloat?
    static let sideBySide: CGFloat = 700
    /// Below this a short day's Your day row would be cramped, so it stacks instead.
    static let rowWidth: CGFloat = 900

    var body: some View {
        let wide = width >= Self.sideBySide
        let short = wide && isShort
        Group {
            if wide && !short {
                HStack(alignment: .top, spacing: 14) {
                    // The timeline fills the side card's height, then scrolls.
                    ActivityTimelineCard(day: day, isToday: isToday, now: now, tracker: tracker, available: sideHeight)
                    sideCard
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { sideHeight = $0 }
                }
            } else {
                VStack(spacing: 14) {
                    ActivityTimelineCard(day: day, isToday: isToday, now: now, tracker: tracker, available: nil)
                    ActivityDayCard(day: day, isToday: isToday, now: now, tracker: tracker,
                                    style: short && width >= Self.rowWidth ? .row : .under)
                }
                // While a short day is shown stacked, the side card is still measured (unseen) so the
                // page goes back to side by side once the timeline would fill it.
                .background(alignment: .topLeading) {
                    if short {
                        sideCard.fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { sideHeight = $0 }
                            .hidden().accessibilityHidden(true).allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }

    private var sideCard: some View {
        ActivityDayCard(day: day, isToday: isToday, now: now, tracker: tracker, style: .side).frame(width: 300)
    }

    /// Whether the timeline, even stretched as far as it goes, would fill less than about 60% of the side card.
    private var isShort: Bool {
        guard let sideHeight, sideHeight > 0 else { return false }
        let base = ActivityTimelineCard.layout(day: day, isToday: isToday, now: now, hourHeight: ActivityTimelineCard.hourHeight)
        return CGFloat(base.height) * ActivityTimelineCard.maxStretch + 16 < 0.6 * sideHeight
    }
}

// MARK: Timeline

struct ActivityTimelineCard: View {
    var day: ActivityDay
    var isToday: Bool
    var now: Date
    var tracker: ActivityTracker
    /// The card's height to match (the side card's), or nil for the default cap.
    var available: CGFloat?
    @State private var chrome: CGFloat = 18
    static let hourHeight: CGFloat = 72
    static let minBlock: CGFloat = 28
    static let idleHeight: CGFloat = 30
    static let maxHeight: CGFloat = 560
    /// How far hours stretch beside a taller side card.
    static let maxStretch: CGFloat = 2.5
    private static let gutter: CGFloat = 50

    var body: some View {
        let cap = available.map { max(240, $0 - chrome - 36 - 12) } ?? Self.maxHeight
        let layout = layout(cap: cap)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Timeline", systemImage: "calendar.day.timeline.left").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppAppearance.secondary)
                Spacer()
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { chrome = $0 }
            if layout.placed.isEmpty {
                Text("Only moments under a minute so far.").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
            } else {
                // Today opens at the bottom, where "now" is; past days open at their first block.
                ScrollView(.vertical) {
                    canvas(layout).padding(.vertical, 8)
                }
                .scrollIndicators(.automatic)
                .defaultScrollAnchor(isToday ? .bottom : .top)
                .id(day.day)
                .frame(height: min(CGFloat(layout.height) + 16, cap))
            }
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: available, alignment: .topLeading)
        .modifier(AppCardSurface(radius: HomeStyle.cardRadius))
    }

    /// Beside a taller side card, hours stretch (up to 2.5×) so the timeline fills the card instead of leaving it empty.
    private func layout(cap: CGFloat) -> ActivityTimelineLayout {
        let make = { (hour: CGFloat) in Self.layout(day: day, isToday: isToday, now: now, hourHeight: hour) }
        let base = make(Self.hourHeight)
        guard available != nil, base.height > 0, base.height + 16 < cap else { return base }
        let scale = min(Self.maxStretch, (cap - 16) / base.height)
        return scale > 1.05 ? make(Self.hourHeight * scale) : base
    }

    static func layout(day: ActivityDay, isToday: Bool, now: Date, hourHeight: CGFloat) -> ActivityTimelineLayout {
        ActivityTimelineLayout(blocks: day.blocks, notRecorded: day.notRecorded, now: isToday ? now : nil, hourHeight: hourHeight, minHeight: minBlock, idleHeight: idleHeight)
    }

    private func canvas(_ layout: ActivityTimelineLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.marks, id: \.date) { mark in
                HStack(spacing: 8) {
                    Text(mark.date, format: .dateTime.hour()).font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .foregroundStyle(AppAppearance.tertiary).lineLimit(1).frame(width: Self.gutter - 8, alignment: .trailing)
                    Rectangle().fill(AppAppearance.separator).frame(height: 1)
                }
                .frame(height: 12).padding(.top, max(0, CGFloat(mark.y) - 6))
            }
            ForEach(layout.idle) { gap in
                IdleDivider(gap: gap)
                    .frame(height: CGFloat(gap.height))
                    .padding(.leading, Self.gutter).padding(.top, CGFloat(gap.y))
            }
            ForEach(layout.placed) { placed in
                ActivityBlockView(block: placed.block, height: CGFloat(placed.height) - 3, tracker: tracker)
                    .frame(height: CGFloat(placed.height) - 3)
                    .padding(.leading, Self.gutter).padding(.top, CGFloat(placed.y) + 1.5)
            }
            if let y = layout.nowY {
                HStack(spacing: 0) {
                    Circle().fill(AppAppearance.text).frame(width: 7, height: 7)
                    Rectangle().fill(AppAppearance.text).frame(height: 1.5)
                }
                .padding(.leading, Self.gutter - 4).padding(.top, max(0, CGFloat(y) - 3.5))
                .allowsHitTesting(false)
                .accessibilityLabel("Now")
            }
        }
        .frame(maxWidth: .infinity, minHeight: CGFloat(layout.height), alignment: .topLeading)
    }
}

/// A collapsed gap: a dashed line with "Idle · 2h 10m" (away), or a dimmer, sparser one with
/// "Not recording · 2h 10m" (Burro closed or paused), and its range on hover.
private struct IdleDivider: View {
    var gap: ActivityTimelineLayout.Idle
    private var off: Bool { gap.kind == .notRecording }
    var body: some View {
        HStack(spacing: 8) {
            dash
            Text("\(off ? "Not recording" : "Idle") · \(TodaySummary.duration(gap.duration))").font(.system(size: 10, weight: off ? .regular : .medium))
                .monospacedDigit().italic(off).foregroundStyle(AppAppearance.tertiary).opacity(off ? 0.75 : 1).fixedSize()
            dash
        }
        .frame(maxHeight: .infinity)
        .help(off ? "Burro was closed or tracking was paused · \(ActivityStyle.range(gap.start, gap.end))" : "Away \(ActivityStyle.range(gap.start, gap.end))")
        .accessibilityElement(children: .combine)
    }
    private var dash: some View {
        Line().stroke(AppAppearance.separator.opacity(off ? 0.6 : 1), style: StrokeStyle(lineWidth: 1, dash: off ? [1, 4] : [3, 3])).frame(height: 1)
    }
    private struct Line: Shape {
        func path(in rect: CGRect) -> Path { Path { $0.move(to: CGPoint(x: 0, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) } }
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

// MARK: Your day so far

/// The categories as a donut with the total in the middle, the apps and sites with the most time,
/// the day's focus stretches on a strip, and what Break went to. Beside the timeline it is one
/// column; under it, the donut and Most time sit side by side; as a row (a short day), everything
/// sits in three columns.
struct ActivityDayCard: View {
    enum Style { case side, under, row }
    var day: ActivityDay
    var isToday: Bool
    var now: Date
    var tracker: ActivityTracker
    var style: Style

    var body: some View {
        TodayCard(title: isToday ? "Your day so far" : "Your day", symbol: "chart.pie", color: AppAppearance.blue) {
            switch style {
            case .side:
                VStack(spacing: 14) { donut.frame(maxWidth: .infinity); legend }
                if hasItems {
                    Divider().overlay(AppAppearance.separator)
                    mostTime
                }
                focusAndBreak(dividers: true)
            case .under:
                // Under the timeline: the donut and its legend beside Most time, instead of a long single column.
                HStack(alignment: .top, spacing: 24) {
                    HStack(alignment: .center, spacing: 18) { donut; legend }.frame(maxWidth: .infinity)
                    if hasItems { mostTime.frame(maxWidth: .infinity) }
                }
                focusAndBreak(dividers: true)
            case .row:
                HStack(alignment: .top, spacing: 28) {
                    HStack(alignment: .center, spacing: 18) { donut; legend }.frame(maxWidth: .infinity, alignment: .leading)
                    if hasItems { mostTime.frame(maxWidth: .infinity, alignment: .topLeading) }
                    if hasFocusOrBreak {
                        VStack(alignment: .leading, spacing: 14) { focusAndBreak(dividers: false) }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
    }

    private var breaks: [(ActivityDay.Item, Bool)] {
        Array((day.apps.map { ($0, false) } + day.sites.map { ($0, true) }).filter { $0.0.category == .break }
            .sorted { $0.0.seconds > $1.0.seconds }.prefix(3))
    }

    private var hasFocusOrBreak: Bool { !day.focus.stretches.isEmpty || !breaks.isEmpty }

    /// The focus strip and what Break went to, each after a divider when stacked in a column.
    @ViewBuilder private func focusAndBreak(dividers: Bool) -> some View {
        if let first = day.blocks.first?.start, let last = day.blocks.map(\.end).max(), !day.focus.stretches.isEmpty {
            if dividers { Divider().overlay(AppAppearance.separator) }
            section("FOCUS") {
                FocusStrip(stretches: day.focus.stretches, longest: day.focus.longest, from: first, to: isToday ? max(last, now) : last)
                Text("\(day.focus.stretches.count) stretch\(day.focus.stretches.count == 1 ? "" : "es"); the longest is highlighted")
                    .font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                    .help("A stretch is time outside Break; idle time or a break under 2 minutes doesn't end it.")
            }
        }
        let breaks = self.breaks
        if !breaks.isEmpty {
            if dividers { Divider().overlay(AppAppearance.separator) }
            section("BREAK WENT TO") {
                ForEach(breaks, id: \.0.id) { item, site in ActivityItemRow(tracker: tracker, item: item, site: site) }
            }
        }
    }

    private var hasItems: Bool { !day.apps.isEmpty || !day.sites.isEmpty }

    private var mostTime: some View {
        section("MOST TIME") {
            ForEach(day.apps.prefix(4)) { item in ActivityItemRow(tracker: tracker, item: item, site: false) }
            ForEach(day.sites.prefix(3)) { item in ActivityItemRow(tracker: tracker, item: item, site: true) }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(AppAppearance.tertiary)
            content()
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
        .frame(width: 120, height: 120)
        .accessibilityElement(children: .combine)
    }

    private var legend: some View {
        let legend = day.legend(limit: 6)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(legend.shown) { item in
                HStack(spacing: 8) {
                    Circle().fill(ActivityStyle.color(item.category)).frame(width: 7, height: 7)
                    Text(item.category.title).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(TodaySummary.duration(item.seconds)).font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.secondary)
                }
                .help("\(Int((item.seconds / max(day.total, 1) * 100).rounded()))% of tracked time")
            }
            if let more = legend.more {
                HStack(spacing: 8) {
                    Circle().strokeBorder(AppAppearance.tertiary).frame(width: 7, height: 7)
                    Text("\(more.count) more").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                    Spacer(minLength: 6)
                    Text(TodaySummary.duration(more.seconds)).font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.secondary)
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
                            .fill(isLongest ? AppAppearance.text : AppAppearance.text.opacity(0.3))
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
        .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(AppAppearance.secondary).lineLimit(1).fixedSize(horizontal: false, vertical: true)
    }
}
