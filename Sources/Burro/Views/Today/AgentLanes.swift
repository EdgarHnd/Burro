// The Today page's lanes: what each chat did, on one time axis. Top to bottom: a legend; a "You"
// lane with the blocks Burro tracked (click one to zoom every lane to its hour), stretches Burro
// wasn't recording hatched and long away stretches marked; one lane per chat (TodayLanes builds
// them, BurroCore): a small provider avatar, the title and its place, a thin bar on the shared axis
// (solid while the agent worked, brighter while you were away, dotted between stretches while it
// sat idle), amber dots where it asked you and a grey diamond where the Brief found it stuck, and
// two outcome lines on the right; a Shipped lane (merged pull requests and deploys); the axis, ending
// in "Now" today. A chat whose stretches are unknown (another machine, an older helper) gets no bar
// and no dotted line, never "idle": its state is on the right only (and, until the day's scan has
// answered, no "not recorded" either). At most eight lanes, then "Show all N" expands in place;
// Home passes no You or Shipped lane, a cap of six and "Show all N in Chats". All chat bars are drawn in one Canvas and hit-tested with
// DayRibbonLayout: hover shows the stretch under the pointer, click opens the chat. The lane width
// is measured once (the axis row). Plain values in, so snapshots can draw it.
import AppKit
import SwiftUI
import BurroCore

struct AgentLanes: View {
    var lanes: [AgentLane]
    /// The axis window before any zoom (TodayLanes' window).
    var window: DateInterval
    /// The calendar day, which a zoom stays inside.
    var day: DateInterval
    /// Today only.
    var now: Date?
    /// Away periods (AgentAwayTime): agent stretches inside them are drawn brighter.
    var away: [DateInterval]
    var tracked: ActivityDay?
    var trackingOn: Bool
    /// Nil when Shipped isn't available (no main project, not read yet, failed).
    var shipped: [TodayRibbonShip]?
    /// Nil while the day hasn't been scanned.
    var scanned = true
    /// Drawn time the window leaves out before its start (DayRibbonLayout.LaneWindow.cut).
    var cut: TimeInterval = 0
    /// Switches to the List view, where the left-out time is shown.
    var showList: (() -> Void)? = nil
    /// Lanes shown before the rest: Today's eight, Home's six.
    var cap = TodayLanes.cap
    /// Set (Home): past the cap, "Show all N in Chats" opens Chats instead of expanding in place.
    var showAll: (() -> Void)? = nil
    var open: (String) -> Void

    @State private var expanded = false
    @State private var zoom: DateInterval?
    @State private var width: CGFloat = 300
    @State private var hover: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let labelWidth: CGFloat = 168
    static let outcomeWidth: CGFloat = 124
    static let gap: CGFloat = 12
    static let laneHeight: CGFloat = 40

    var body: some View {
        let layout = DayRibbonLayout(window: zoom ?? window, width: Double(width))
        let shown = expanded ? lanes : Array(lanes.prefix(cap))
        let nowX = layout.nowX(now).map { CGFloat($0) }
        VStack(alignment: .leading, spacing: 6) {
            legend.padding(.bottom, 6)
            if trackingOn {
                row(height: cut >= 60 && zoom == nil ? 38 : 30) { youLabel } bar: { youTrack(layout) } outcome: { EmptyView() }
                Rectangle().fill(AppAppearance.separator).frame(height: 1)
            }
            if shown.isEmpty {
                // The panel's sentence already says there were no chats; only a pending scan is said here.
                if !scanned {
                    Text("Reading your agent logs…").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                        .frame(maxWidth: .infinity, minHeight: Self.laneHeight)
                }
            } else {
                HStack(alignment: .top, spacing: Self.gap) {
                    VStack(spacing: 0) { ForEach(shown) { laneLabel($0).frame(height: Self.laneHeight) } }
                        .frame(width: Self.labelWidth)
                    chatCanvas(shown, layout: layout, nowX: nowX)
                        .frame(maxWidth: .infinity).frame(height: Self.laneHeight * CGFloat(shown.count))
                    VStack(spacing: 0) { ForEach(shown) { laneOutcome($0).frame(height: Self.laneHeight) } }
                        .frame(width: Self.outcomeWidth)
                }
            }
            if let shipped {
                Rectangle().fill(AppAppearance.separator).frame(height: 1)
                row(height: 26) { shippedLabel(shipped) } bar: { shippedTrack(shipped, layout: layout) } outcome: { EmptyView() }
            }
            row(height: 18) { EmptyView() } bar: { axis(layout, nowX: nowX) } outcome: { EmptyView() }
            if lanes.count > cap {
                if let showAll {
                    Button("Show all \(lanes.count) in Chats", action: showAll)
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                        .padding(.top, 4).help("Open Chats")
                } else {
                    Button(expanded ? "Show fewer" : "Show all \(lanes.count)") { expanded.toggle() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                        .padding(.top, 4).help(expanded ? "Show the first \(cap) lanes" : "Show every chat of the day")
                }
            }
        }
        .onChange(of: day) { zoom = nil }
    }

    private func row<Label: View, Bar: View, Outcome: View>(height: CGFloat, @ViewBuilder label: () -> Label, @ViewBuilder bar: () -> Bar,
                                                            @ViewBuilder outcome: () -> Outcome) -> some View {
        HStack(alignment: .center, spacing: Self.gap) {
            // Color.clear keeps an empty column's width (a framed EmptyView takes none, which would
            // widen this row's bar and put its axis out of step with the lanes).
            ZStack(alignment: .leading) { Color.clear; label() }.frame(width: Self.labelWidth, height: height)
            bar().frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            ZStack(alignment: .trailing) { Color.clear; outcome() }.frame(width: Self.outcomeWidth, height: height)
        }
    }

    // MARK: Legend

    private var legend: some View {
        HStack(alignment: .center, spacing: 12) {
            FlowLayout(spacing: 0) {
                if !lanes.isEmpty { legendItem("Working") { bar(AppAppearance.tertiary) } }
                if hasAway { legendItem("While you were away") { bar(AppAppearance.text) } }
                if lanes.contains(where: { $0.marks.contains { $0.kind == .asked && window.contains($0.at) } }) {
                    legendItem("Waiting on you") { Circle().fill(AppAppearance.amber).frame(width: 7, height: 7) }
                }
                if lanes.contains(where: { $0.marks.contains { $0.kind == .askedEarlier && window.contains($0.at) } }) {
                    legendItem("Asked you earlier") { Circle().strokeBorder(AppAppearance.tertiary, lineWidth: 1.5).frame(width: 7, height: 7) }
                }
                if lanes.contains(where: { $0.marks.contains { $0.kind == .stuck && window.contains($0.at) } }) {
                    legendItem("Looked stuck") { StuckDiamond().stroke(AppAppearance.tertiary, lineWidth: 1.5).frame(width: 8, height: 8) }
                }
                if trackingOn, tracked?.notRecorded.contains(where: { $0.intersects(window) }) == true {
                    legendItem("Not recorded") { Hatch().stroke(AppAppearance.hairline, lineWidth: 1.2).frame(width: 14, height: 8).clipped() }
                }
                if trackingOn, let tracked {
                    ForEach(tracked.legend(limit: 4).shown, id: \.category) { item in
                        legendItem(item.category.title) { RoundedRectangle(cornerRadius: 2).fill(ActivityStyle.color(item.category)).frame(width: 8, height: 8) }
                    }
                }
            }
            .font(.system(size: 11.5)).foregroundStyle(AppAppearance.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let zoom {
                Button { toggleZoom(zoom.start) } label: {
                    Label("All hours", systemImage: "arrow.up.left.and.arrow.down.right").font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(AppAppearance.secondary).fixedSize()
                .help("Zoomed to \(ActivityStyle.range(zoom.start, zoom.end)). Show every hour again")
            }
        }
    }

    private var hasAway: Bool {
        !away.isEmpty && lanes.contains { lane in lane.intervals?.contains { interval in away.contains { $0.intersects(interval) } } ?? false }
    }

    private func legendItem<Swatch: View>(_ title: String, @ViewBuilder swatch: () -> Swatch) -> some View {
        HStack(spacing: 6) { swatch(); Text(title) }.padding(.trailing, 14).padding(.vertical, 2)
    }
    private func bar(_ color: Color) -> some View { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 14, height: 5) }

    // MARK: You

    private var youLabel: some View {
        VStack(alignment: .leading, spacing: 1) {
            youName
            // What the axis leaves out before its start, under the name so it never covers a block.
            cutNote.padding(.leading, 24)
        }
    }

    private var youName: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.fill").font(.system(size: 10)).foregroundStyle(AppAppearance.tertiary).frame(width: 16)
            Text("You").font(.system(size: 13, weight: .medium))
            if let tracked, tracked.total > 0 {
                Text(TodaySummary.duration(tracked.total)).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
            }
        }
        .help("What Burro tracked on this Mac. Click a block to zoom to its hour.")
    }

    @ViewBuilder private func youTrack(_ layout: DayRibbonLayout) -> some View {
        if let tracked {
            ZStack(alignment: .topLeading) {
                // Fills the bar column, so the marks' offsets aren't clipped to the first block's size.
                Color.clear
                ForEach(tracked.notRecorded, id: \.start) { gap in
                    if let segment = layout.segment(gap) { NotRecordingMark(gap: gap, width: CGFloat(segment.width)).offset(x: CGFloat(segment.x)) }
                }
                ForEach(away.filter { $0.duration >= 1800 }, id: \.start) { gap in
                    if let segment = layout.segment(gap) { AwayMark(gap: gap, width: CGFloat(segment.width)).offset(x: CGFloat(segment.x)) }
                }
                ForEach(tracked.blocks) { block in
                    if let segment = layout.segment(DateInterval(start: block.start, end: block.end)) {
                        RibbonBlock(block: block, zoomed: zoom != nil) { toggleZoom(block.start) }
                            .frame(width: CGFloat(segment.width)).padding(.vertical, 7).offset(x: CGFloat(segment.x))
                    }
                }
                if tracked.blocks.isEmpty && tracked.notRecorded.isEmpty { placeholder("Nothing recorded yet") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipShape(Rectangle().inset(by: -4))
        } else {
            placeholder("Reading…")
        }
    }

    /// "+ 28m before 10:00": what the window leaves out, at the left end of the You lane.
    @ViewBuilder private var cutNote: some View {
        if cut >= 60, zoom == nil {
            let text = Text("+ \(TodaySummary.duration(cut)) before \(TodayRibbonStyle.clock(window.start))")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
            if let showList {
                Button(action: showList) { text }.buttonStyle(.plain).help("Earlier activity left out of the axis. Click for the List view.")
            } else {
                text.help("Earlier activity left out of the axis")
            }
        }
    }

    private func toggleZoom(_ date: Date) {
        let next: DateInterval? = zoom == nil ? DayRibbonLayout.zoomWindow(around: date, day: day, calendar: .current) : nil
        if reduceMotion { zoom = next } else { withAnimation(.easeInOut(duration: 0.25)) { zoom = next } }
    }

    // MARK: Chats

    private func laneLabel(_ lane: AgentLane) -> some View {
        Button { open(lane.id) } label: {
            HStack(spacing: 8) {
                ProviderAvatar(provider: lane.provider, id: lane.id, active: false, working: false, size: 16).frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(lane.title).font(.system(size: 13, weight: lane.state == .needsYou ? .medium : .regular))
                        .foregroundStyle(AppAppearance.text).lineLimit(1).truncationMode(.tail)
                    Text(lane.subtitle).font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!lane.canOpen)
        .help(laneHelp(lane))
        .accessibilityLabel("\(lane.title), \(lane.outcome)" + (lane.activeSeconds.map { ", active \(TodaySummary.duration($0))" } ?? ""))
    }

    private func laneOutcome(_ lane: AgentLane) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(lane.outcome).font(.system(size: 12, weight: lane.state == .needsYou && now != nil ? .medium : .regular)).monospacedDigit()
                .foregroundStyle(lane.state == .needsYou && now != nil ? AppAppearance.amber : lane.stuck ? AppAppearance.tertiary : AppAppearance.secondary)
                .lineLimit(1).minimumScaleFactor(0.85)
            if let detail = lane.detail {
                Text(detail).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(AppAppearance.tertiary).lineLimit(1).minimumScaleFactor(0.85)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .help(lane.detail ?? lane.outcome)
    }

    private func laneHelp(_ lane: AgentLane) -> String {
        var lines = [lane.title, lane.subtitle]
        if let intervals = lane.intervals {
            if let active = lane.activeSeconds, !intervals.isEmpty {
                let ranges = intervals.prefix(6).map { ActivityStyle.range($0.start, $0.end) }.joined(separator: ", ")
                lines.append("Active \(TodaySummary.duration(active)): \(ranges)" + (intervals.count > 6 ? " and \(intervals.count - 6) more" : ""))
            }
        } else {
            lines.append(lane.remote ? "Burro records when agents work on this Mac only." : "When this chat worked isn't known (Burro's helper didn't say).")
        }
        for mark in lane.marks { lines.append("\(TodayRibbonStyle.clock(mark.at)) · \(mark.text)") }
        if lane.canOpen { lines.append("Click to open the chat") }
        return lines.joined(separator: "\n")
    }

    private func chatCanvas(_ shown: [AgentLane], layout: DayRibbonLayout, nowX: CGFloat?) -> some View {
        let height = Double(Self.laneHeight)
        let hovered = hover.flatMap { DayRibbonLayout.lane(atY: Double($0.y), height: height, count: shown.count) }
        let away = self.away, now = self.now, barWidth = width, scanned = self.scanned
        return Canvas { context, size in
            for tick in layout.ticks(calendar: .current).dropFirst().dropLast() {
                context.fill(Path(CGRect(x: tick.x, y: 0, width: 1, height: size.height)), with: .color(AppAppearance.separator))
            }
            for (index, lane) in shown.enumerated() {
                let top = Double(index) * height, mid = top + height / 2
                if index == hovered {
                    context.fill(Path(roundedRect: CGRect(x: -4, y: top + 4, width: size.width + 8, height: height - 8), cornerRadius: 6),
                                 with: .color(AppAppearance.hover))
                }
                if let intervals = lane.intervals, let last = intervals.last {
                    // Drawn pieces: near stretches joined, each at least 3 pt (DayRibbonLayout.drawn).
                    let pieces = layout.drawn(intervals)
                    // Idle between pieces (and after the last, up to now today): dotted.
                    var dots = Path()
                    for (a, b) in zip(pieces, pieces.dropFirst()) where b.x > a.maxX {
                        dots.move(to: CGPoint(x: a.maxX, y: mid)); dots.addLine(to: CGPoint(x: b.x, y: mid))
                    }
                    if let end = now.map({ min($0, layout.window.end) }), end > last.end, let tail = pieces.last {
                        let endX = layout.x(end)
                        if endX > tail.maxX { dots.move(to: CGPoint(x: tail.maxX, y: mid)); dots.addLine(to: CGPoint(x: endX, y: mid)) }
                    }
                    context.stroke(dots, with: .color(AppAppearance.tertiary), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [0.5, 3.5]))
                    for piece in pieces {
                        let rect = CGRect(x: piece.x, y: mid - 3, width: piece.width, height: 6)
                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(AppAppearance.tertiary))
                        // Where it worked while you were away, brighter (inside the drawn piece).
                        for gap in away where gap.intersects(piece.interval) {
                            let from = max(rect.minX, layout.x(max(gap.start, piece.interval.start)))
                            let to = min(rect.maxX, max(from + 3, layout.x(min(gap.end, piece.interval.end))))
                            context.fill(Path(roundedRect: CGRect(x: from, y: mid - 3, width: max(0, to - from), height: 6), cornerRadius: 2),
                                         with: .color(AppAppearance.text))
                        }
                    }
                } else if lane.intervals == nil, scanned || lane.remote,
                          // The words give way to a mark that would sit on them (their run is about 110 points).
                          !lane.marks.contains(where: { layout.window.contains($0.at) && layout.x($0.at) < 112 }) {
                    // Before the first scan answers a local lane shows no bar and no words: unknown, not idle.
                    context.draw(Text(lane.remote ? "on another machine" : "not recorded").font(.system(size: 10.5)).foregroundStyle(AppAppearance.tertiary),
                                 at: CGPoint(x: 0, y: mid), anchor: .leading)
                }
                for mark in lane.marks where layout.window.contains(mark.at) {
                    let x = layout.x(mark.at)
                    switch mark.kind {
                    case .asked:
                        let dot = CGRect(x: x - 4.5, y: mid - 4.5, width: 9, height: 9)
                        context.fill(Path(ellipseIn: dot.insetBy(dx: -1.5, dy: -1.5)), with: .color(AppAppearance.surface))
                        context.fill(Path(ellipseIn: dot), with: .color(AppAppearance.amber))
                    case .askedEarlier:
                        let ring = CGRect(x: x - 3.5, y: mid - 3.5, width: 7, height: 7)
                        context.fill(Path(ellipseIn: ring), with: .color(AppAppearance.surface))
                        context.stroke(Path(ellipseIn: ring), with: .color(AppAppearance.tertiary), lineWidth: 1.5)
                    case .stuck:
                        let diamond = StuckDiamond().path(in: CGRect(x: x - 5, y: mid - 5, width: 10, height: 10))
                        context.fill(diamond, with: .color(AppAppearance.surface))
                        context.stroke(diamond, with: .color(AppAppearance.tertiary), lineWidth: 1.5)
                    }
                }
            }
            if let nowX {
                context.fill(Path(CGRect(x: nowX - 0.5, y: 0, width: 1, height: size.height)), with: .color(AppAppearance.hairline))
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hover = point
            case .ended: hover = nil
            }
        }
        .onTapGesture { location in
            if let index = DayRibbonLayout.lane(atY: Double(location.y), height: height, count: shown.count), shown[index].canOpen {
                open(shown[index].id)
            }
        }
        .overlay(alignment: .topLeading) {
            if let hover, let index = hovered {
                let lane = shown[index]
                Text(tooltip(lane, x: Double(hover.x), layout: layout))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(AppAppearance.text).lineLimit(1).fixedSize()
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(AppAppearance.raised, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(AppAppearance.separator))
                    .alignmentGuide(.leading) { $0.width / 2 - min(max(hover.x, $0.width / 2), barWidth - $0.width / 2) }
                    .offset(y: CGFloat(Double(index) * height) - 14)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityHidden(true)
    }

    /// What is under the pointer: the stretch (and whether you were away), a mark, or the lane.
    private func tooltip(_ lane: AgentLane, x: Double, layout: DayRibbonLayout) -> String {
        if let mark = lane.marks.first(where: { abs(layout.x($0.at) - x) <= 5 }) { return "\(TodayRibbonStyle.clock(mark.at)) · \(mark.text)" }
        guard let intervals = lane.intervals else { return lane.remote ? "\(lane.title) · on another machine" : "\(lane.title) · not recorded" }
        if let piece = layout.piece(atX: x, in: intervals) {
            let wasAway = away.contains { $0.intersects(piece.interval) }
            return "\(ActivityStyle.range(piece.interval.start, piece.interval.end)) · active \(TodaySummary.duration(piece.active))"
                + (wasAway ? " · partly while you were away" : "")
        }
        return "\(TodayRibbonStyle.clock(layout.date(atX: x))) · idle"
    }

    // MARK: Shipped

    private func shippedLabel(_ shipped: [TodayRibbonShip]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox").font(.system(size: 10)).foregroundStyle(AppAppearance.tertiary).frame(width: 16)
            Text("Shipped").font(.system(size: 13, weight: .medium))
            if !shipped.isEmpty { Text("\(shipped.count)").font(.system(size: 11.5)).monospacedDigit().foregroundStyle(AppAppearance.tertiary) }
        }
    }

    private func shippedTrack(_ shipped: [TodayRibbonShip], layout: DayRibbonLayout) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if shipped.isEmpty { placeholder("Nothing shipped") }
            ForEach(shipped) { ship in
                if layout.window.contains(ship.at) { ShipMark(ship: ship).offset(x: CGFloat(layout.x(ship.at)) - 7, y: 5) }
            }
        }
    }

    // MARK: Axis

    private func axis(_ layout: DayRibbonLayout, nowX: CGFloat?) -> some View {
        Canvas { context, size in
            let font = Font.system(size: 10.5, design: .monospaced)
            let end = nowX != nil && zoom == nil
            // Labels at least 30 points apart: on a narrow bar every second or third hour is named.
            let ticks = layout.ticks(calendar: .current, nowX: end ? Double(size.width) : nil, clearance: 40)
            let spacing = ticks.count > 2 ? ticks[2].x - ticks[1].x : Double(size.width)
            let every = max(1, Int((30 / max(1, spacing)).rounded(.up)))
            var last = -Double.infinity
            for (index, tick) in ticks.enumerated() {
                guard let label = tick.label, index % every == 0, tick.x - last >= 28 else { continue }
                last = tick.x
                let x = CGFloat(tick.x)
                let anchor: UnitPoint = x < 12 ? .leading : x > size.width - 12 ? .trailing : .center
                context.draw(Text(label).font(font).foregroundStyle(AppAppearance.tertiary), at: CGPoint(x: x, y: size.height / 2), anchor: anchor)
            }
            if end {
                context.draw(Text("Now").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(AppAppearance.secondary),
                             at: CGPoint(x: size.width, y: size.height / 2), anchor: .trailing)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = max(1, $0) }
        .accessibilityLabel(zoom.map { "Time axis, \(ActivityStyle.range($0.start, $0.end))" } ?? "Time axis, \(ActivityStyle.range(window.start, window.end))")
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// The Brief found a chat stuck here.
struct StuckDiamond: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)); path.addLine(to: CGPoint(x: rect.minX, y: rect.midY)); path.closeSubpath()
        }
    }
}

/// The "Not recorded" legend swatch's diagonal lines.
private struct Hatch: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            var x = rect.minX - rect.height
            while x < rect.maxX { path.move(to: CGPoint(x: x, y: rect.maxY)); path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY)); x += 4 }
        }
    }
}
