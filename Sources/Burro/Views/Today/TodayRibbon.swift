// The Today page's day ribbon: the whole day (00–24) left to right with an hour axis and a now
// marker, in three lanes. You: the blocks Burro tracked, tinted by category; stretches Burro wasn't
// recording hatched; away stretches (Burro recording, you not there: AgentAwayTime) of half an hour
// or more left empty between dashed edges and labelled with their length. Agents: one thin row per
// chat that worked that day (its active stretches from the day scan), brighter where it worked
// while you were away. The away marks, the lit stretches and the While you were away card all use
// the same away periods (the summary's, else worked out from the tracked day), computed once per
// render together with the agents' rows. Shipped: a tick per
// merged pull request and a diamond per production deploy. Hovering anything says what it was;
// clicking a You block zooms all three lanes to that hour and clicking again (or "Whole day") goes
// back; clicking an agent row opens its chat, a tick its pull request. DayRibbonLayout (BurroCore)
// does the geometry. The view takes plain values, so snapshots can draw it with invented data.
import AppKit
import SwiftUI
import BurroCore

/// One chat's row on the Agents lane.
struct TodayRibbonAgent: Identifiable {
    var id: String
    var title: String
    var intervals: [DateInterval]
    var open: (() -> Void)?
}

/// A tick or diamond on the Shipped lane.
struct TodayRibbonShip: Identifiable {
    enum Kind { case merged, deploy(ShippedDay.Release.Status?) }
    var id: String
    var kind: Kind
    var at: Date
    var title: String
    var url: URL?
}

struct TodayRibbonCard: View {
    /// The calendar day shown.
    var day: DateInterval
    /// Today only: where the now marker sits.
    var now: Date?
    /// Nil while tracking is off or not read yet.
    var tracked: ActivityDay?
    var trackingOn: Bool
    /// Nil while the agent scan hasn't answered.
    var agents: [TodayRibbonAgent]?
    /// The scan answered but gave no stretches (an older helper): the lane says so rather than claiming idle.
    var agentsUnknown = false
    var away: AgentAwayTime.Summary?
    /// Nil when Shipped isn't available (no main project, not read yet, failed).
    var shipped: [TodayRibbonShip]?

    @State private var zoom: DateInterval?
    @State private var laneWidth: CGFloat = 900
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let labelWidth: CGFloat = 96
    static let gap: CGFloat = 12
    private static let maxAgentRows = 8

    private var layout: DayRibbonLayout { DayRibbonLayout(window: zoom ?? day, width: Double(laneWidth)) }

    var body: some View {
        let layout = self.layout
        let nowX = layout.nowX(now).map { CGFloat($0) }
        let awayPeriods = self.awayPeriods
        let longAway = awayPeriods.filter { $0.duration >= 1800 }
        let placed = placedAgents(layout)
        VStack(alignment: .leading, spacing: 10) {
            lane(height: 20, label: nil, sub: nil) { axis(layout, nowX: nowX) }
            lane(height: 46, label: "You", sub: youSub) { youTrack(layout, nowX: nowX, longAway: longAway) }
            lane(height: agentsHeight(placed), label: "Agents", sub: agentsSub) {
                agentsTrack(layout, nowX: nowX, placed: placed, away: awayPeriods, longAway: longAway)
            }
            lane(height: 32, label: "Shipped", sub: shippedSub) { shippedTrack(layout, nowX: nowX) }
            legend
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(AppCardSurface(radius: HomeStyle.cardRadius))
        .onChange(of: day) { zoom = nil }
    }

    // MARK: Lanes

    private func lane<Content: View>(height: CGFloat, label: String?, sub: String?, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: Self.gap) {
            VStack(alignment: .leading, spacing: 1) {
                if let label { Text(label).font(.system(size: 12, weight: .semibold)) }
                if let sub { Text(sub).font(.system(size: 11)).monospacedDigit().foregroundStyle(AppAppearance.tertiary).lineLimit(1) }
            }
            .frame(width: Self.labelWidth, alignment: .leading)
            .accessibilityElement(children: .combine)
            content()
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        }
    }

    private func track<Content: View>(_ layout: DayRibbonLayout, nowX: CGFloat?, @ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Self.trackFill)
            ForEach(layout.ticks(calendar: .current).dropFirst().dropLast(), id: \.date) { tick in
                Rectangle().fill(AppAppearance.separator).frame(width: 1).frame(maxHeight: .infinity).offset(x: CGFloat(tick.x))
            }
            content()
            if let nowX {
                RoundedRectangle(cornerRadius: 1).fill(AppAppearance.text).frame(width: 2)
                    .padding(.vertical, -4).offset(x: nowX - 1).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .clipShape(Rectangle().inset(by: -6))
    }

    static let trackFill = AppAppearance.adaptive(light: (0, 0, 0, 0.035), dark: (0, 0, 0, 0.22))

    private func axis(_ layout: DayRibbonLayout, nowX: CGFloat?) -> some View {
        Canvas { context, size in
            let font = Font.system(size: 11, design: .monospaced)
            for tick in layout.ticks(calendar: .current, nowX: nowX.map(Double.init), clearance: 52) {
                guard let label = tick.label else { continue }
                let x = CGFloat(tick.x)
                let anchor: UnitPoint = x < 12 ? .leading : x > size.width - 12 ? .trailing : .center
                context.draw(Text(label).font(font).foregroundStyle(AppAppearance.tertiary), at: CGPoint(x: x, y: size.height / 2), anchor: anchor)
            }
            if let nowX, let now {
                let text = "now " + Self.clock(now)
                let anchor: UnitPoint = nowX < 40 ? .leading : nowX > size.width - 40 ? .trailing : .center
                context.draw(Text(text).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(AppAppearance.text),
                             at: CGPoint(x: nowX, y: size.height / 2), anchor: anchor)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { laneWidth = max(1, $0) }
        .accessibilityLabel(zoom.map { "Hour axis, \(ActivityStyle.range($0.start, $0.end))" } ?? "Hour axis, the whole day")
    }

    // MARK: You

    private var youSub: String? {
        guard trackingOn, let tracked, tracked.total > 0 else { return nil }
        return TodaySummary.duration(tracked.total)
    }

    private func youTrack(_ layout: DayRibbonLayout, nowX: CGFloat?, longAway: [DateInterval]) -> some View {
        track(layout, nowX: nowX) {
            if !trackingOn {
                placeholder("Tracking is off")
            } else if let tracked {
                ForEach(tracked.notRecorded, id: \.start) { gap in
                    if let segment = layout.segment(gap) { NotRecordingMark(gap: gap, width: CGFloat(segment.width)).offset(x: CGFloat(segment.x)) }
                }
                ForEach(longAway, id: \.start) { gap in
                    if let segment = layout.segment(gap) { AwayMark(gap: gap, width: CGFloat(segment.width)).offset(x: CGFloat(segment.x)) }
                }
                ForEach(tracked.blocks) { block in
                    if let segment = layout.segment(DateInterval(start: block.start, end: block.end)) {
                        RibbonBlock(block: block, zoomed: zoom != nil) { toggleZoom(block.start) }
                            .frame(width: CGFloat(segment.width)).padding(.vertical, 6).offset(x: CGFloat(segment.x))
                    }
                }
                if tracked.blocks.isEmpty && tracked.notRecorded.isEmpty { placeholder("Nothing recorded yet") }
            } else {
                placeholder("Reading…")
            }
        }
    }

    /// The day's away periods: the summary's when there is one, else worked out from the tracked day
    /// the same way (time Burro wasn't recording, hatched instead, is never away). Empty with tracking off.
    private var awayPeriods: [DateInterval] {
        guard trackingOn, let tracked else { return [] }
        return away?.away ?? AgentAwayTime.away(tracked: tracked, within: DateInterval(start: day.start, end: min(day.end, max(day.start, now ?? day.end))))
    }

    private func toggleZoom(_ date: Date) {
        let next: DateInterval? = zoom == nil ? DayRibbonLayout.zoomWindow(around: date, day: day, calendar: .current) : nil
        if reduceMotion { zoom = next } else { withAnimation(.easeInOut(duration: 0.25)) { zoom = next } }
    }

    // MARK: Agents

    private func placedAgents(_ layout: DayRibbonLayout) -> [(agent: TodayRibbonAgent, row: Int)] {
        let agents = agents ?? []
        let rows = layout.rows(agents.map(\.intervals), maxRows: Self.maxAgentRows)
        return Array(zip(agents, rows))
    }

    private func agentsHeight(_ placed: [(agent: TodayRibbonAgent, row: Int)]) -> CGFloat {
        let rows = (placed.map(\.row).max() ?? -1) + 1
        return max(32, 8 + CGFloat(rows) * 10 + 4)
    }

    private var agentsSub: String? {
        guard let agents, !agents.isEmpty else { return nil }
        return "\(agents.count) chat\(agents.count == 1 ? "" : "s")"
    }

    private func agentsTrack(_ layout: DayRibbonLayout, nowX: CGFloat?, placed: [(agent: TodayRibbonAgent, row: Int)],
                             away: [DateInterval], longAway: [DateInterval]) -> some View {
        track(layout, nowX: nowX) {
            ForEach(longAway, id: \.start) { gap in
                if let segment = layout.segment(gap) { AwayMark(gap: gap, width: CGFloat(segment.width), label: false).offset(x: CGFloat(segment.x)) }
            }
            if agentsUnknown {
                placeholder("Needs the updated helper to show when agents worked")
            } else if let agents {
                if agents.isEmpty { placeholder("No agent work") }
                ForEach(placed, id: \.agent.id) { agent, row in
                    AgentRibbonRow(agent: agent, layout: layout, away: away)
                        .offset(y: 8 + CGFloat(row) * 10 - 3)
                }
            } else {
                placeholder("Reading your agent logs…")
            }
        }
    }

    // MARK: Shipped

    private var shippedSub: String? {
        guard let shipped, !shipped.isEmpty else { return nil }
        let merged = shipped.filter { if case .merged = $0.kind { true } else { false } }.count, deploys = shipped.count - merged
        return [merged > 0 ? "\(merged) PR\(merged == 1 ? "" : "s")" : nil, deploys > 0 ? "\(deploys) deploy\(deploys == 1 ? "" : "s")" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func shippedTrack(_ layout: DayRibbonLayout, nowX: CGFloat?) -> some View {
        track(layout, nowX: nowX) {
            if let shipped {
                if shipped.isEmpty { placeholder("Nothing shipped") }
                ForEach(shipped) { ship in
                    if layout.window.contains(ship.at) { ShipMark(ship: ship).offset(x: CGFloat(layout.x(ship.at)) - 7, y: 7) }
                }
            } else {
                placeholder("—")
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Legend

    private var legend: some View {
        HStack(alignment: .top, spacing: 12) {
            FlowLayout(spacing: 0) {
                ForEach(legendItems, id: \.title) { item in
                    HStack(spacing: 6) { item.swatch; Text(item.title) }.padding(.trailing, 16).padding(.vertical, 2)
                }
            }
            .font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let zoom {
                HStack(spacing: 8) {
                    Text(ActivityStyle.range(zoom.start, zoom.end)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                    Button { toggleZoom(zoom.start) } label: {
                        Label("Whole day", systemImage: "arrow.up.left.and.arrow.down.right").font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).frame(height: 24).background(AppAppearance.raised, in: Capsule())
                    }
                    .buttonStyle(.plain).help("Show the whole day again")
                }
                .font(.system(size: 12)).fixedSize()
            } else if trackingOn, tracked?.blocks.isEmpty == false {
                Text("Hover a block for its app and window · click to zoom to that hour")
                    .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).multilineTextAlignment(.trailing)
                    .frame(maxWidth: 260, alignment: .trailing).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, Self.labelWidth + Self.gap)
    }

    private struct LegendItem { var title: String; var swatch: AnyView }

    private var legendItems: [LegendItem] {
        var items: [LegendItem] = []
        if trackingOn, let tracked {
            for item in tracked.legend(limit: 6).shown {
                items.append(LegendItem(title: item.category.title, swatch: AnyView(
                    RoundedRectangle(cornerRadius: 3).fill(ActivityStyle.color(item.category)).frame(width: 9, height: 9))))
            }
        }
        if let away, away.total >= 60 {
            items.append(LegendItem(title: "Agent working while you were away", swatch: AnyView(
                RoundedRectangle(cornerRadius: 2).fill(AppAppearance.green).frame(width: 14, height: 4))))
        }
        if let shipped {
            if shipped.contains(where: { if case .merged = $0.kind { true } else { false } }) {
                items.append(LegendItem(title: "Merged PR", swatch: AnyView(Rectangle().fill(AppAppearance.secondary).frame(width: 2, height: 11))))
            }
            if shipped.contains(where: { if case .deploy = $0.kind { true } else { false } }) {
                items.append(LegendItem(title: "Deploy", swatch: AnyView(DeployDiamond(color: AppAppearance.green, size: 9))))
            }
        }
        return items
    }

    static func clock(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// A tracked block: a solid bar in its category's colour; hover for what it was, click to zoom.
private struct RibbonBlock: View {
    var block: ActivityBlock
    var zoomed: Bool
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(ActivityStyle.color(block.category))
                .opacity(hovering ? 1 : 0.88)
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(AppAppearance.text.opacity(hovering ? 0.5 : 0), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel("\(block.title), \(ActivityStyle.range(block.start, block.end))")
        .accessibilityHint(zoomed ? "Shows the whole day" : "Zooms to this hour")
    }
    private var help: String {
        var lines = [block.title, "\(ActivityStyle.range(block.start, block.end)) · \(block.category.title) · \(TodaySummary.duration(block.seconds))"]
        if let detail = block.detail { lines.append(detail) }
        lines.append(zoomed ? "Click for the whole day" : "Click to zoom to this hour")
        return lines.joined(separator: "\n")
    }
}

/// Burro wasn't recording: a hatched bar, labelled when there's room.
private struct NotRecordingMark: View {
    var gap: DateInterval
    var width: CGFloat
    var body: some View {
        ZStack {
            Canvas { context, size in
                var path = Path()
                var x: CGFloat = -size.height
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: size.height)); path.addLine(to: CGPoint(x: x + size.height, y: 0)); x += 6
                }
                context.stroke(path, with: .color(AppAppearance.hairline), lineWidth: 1.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(AppAppearance.hairline))
            if width >= 90 {
                Text("Not recording").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                    .padding(.horizontal, 5).background(AppAppearance.surface, in: Capsule())
            }
        }
        .frame(width: width).padding(.vertical, 6)
        .help("Burro was closed or tracking was paused · \(ActivityStyle.range(gap.start, gap.end))")
        .accessibilityLabel("Not recording, \(ActivityStyle.range(gap.start, gap.end))")
    }
}

/// A long stretch away: empty, between dashed edges, labelled with its length when there's room.
private struct AwayMark: View {
    var gap: DateInterval
    var width: CGFloat
    var label = true
    var body: some View {
        ZStack {
            Rectangle().fill(AppAppearance.surface.opacity(0.55))
            HStack {
                dash
                Spacer(minLength: 0)
                dash
            }
            if label && width >= 80 {
                Text("Away \(TodaySummary.duration(gap.duration))").font(.system(size: 11)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
            }
        }
        .frame(width: width).frame(maxHeight: .infinity)
        .help("Away \(ActivityStyle.range(gap.start, gap.end)) · \(TodaySummary.duration(gap.duration))")
        .accessibilityLabel("Away, \(ActivityStyle.range(gap.start, gap.end))")
        .accessibilityHidden(!label)
    }
    private var dash: some View {
        VerticalDash().stroke(AppAppearance.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(width: 1)
    }
    private struct VerticalDash: Shape {
        func path(in rect: CGRect) -> Path { Path { $0.move(to: CGPoint(x: rect.midX, y: 0)); $0.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)) } }
    }
}

/// One chat's stretches as thin bars, lit where you were away; hover names it, click opens it.
private struct AgentRibbonRow: View {
    var agent: TodayRibbonAgent
    var layout: DayRibbonLayout
    var away: [DateInterval]
    @State private var hovering = false
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(agent.intervals.enumerated()), id: \.offset) { _, interval in
                ForEach(Array(DayRibbonLayout.split(interval, by: away).enumerated()), id: \.offset) { _, piece in
                    if let segment = layout.segment(piece.interval) {
                        Button { agent.open?() } label: {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(piece.away ? AppAppearance.green : AppAppearance.green.opacity(hovering ? 0.6 : 0.38))
                                .frame(width: CGFloat(segment.width), height: 4)
                                .padding(.vertical, 3).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(agent.open == nil)
                        .offset(x: CGFloat(segment.x))
                        .help(help)
                    }
                }
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agent.title), active \(TodaySummary.duration(total))")
        .accessibilityAddTraits(agent.open == nil ? [] : .isButton)
        .accessibilityAction { agent.open?() }
    }
    private var total: TimeInterval { agent.intervals.reduce(0) { $0 + $1.duration } }
    private var help: String {
        let ranges = agent.intervals.prefix(6).map { ActivityStyle.range($0.start, $0.end) }.joined(separator: ", ")
        let more = agent.intervals.count > 6 ? " and \(agent.intervals.count - 6) more" : ""
        return "\(agent.title)\nActive \(TodaySummary.duration(total)): \(ranges)\(more)" + (agent.open == nil ? "" : "\nClick to open the chat")
    }
}

/// A merged pull request (a tick) or a production deploy (a diamond); click opens it on GitHub.
private struct ShipMark: View {
    var ship: TodayRibbonShip
    var body: some View {
        if ship.url == nil {
            mark.help("\(ship.title)\n\(TodayRibbonCard.clock(ship.at))").accessibilityLabel("\(ship.title), \(TodayRibbonCard.clock(ship.at))")
        } else {
            Button { if let url = ship.url { NSWorkspace.shared.open(url) } } label: { mark }
                .buttonStyle(.plain)
                .help("\(ship.title)\n\(TodayRibbonCard.clock(ship.at)) · click to open on GitHub")
                .accessibilityLabel("\(ship.title), \(TodayRibbonCard.clock(ship.at))")
        }
    }
    private var mark: some View {
            Group {
                switch ship.kind {
                case .merged: RoundedRectangle(cornerRadius: 1).fill(AppAppearance.secondary).frame(width: 2, height: 16)
                case .deploy(let status): DeployDiamond(color: TodayShipStyle.color(status), size: 11)
                }
            }
            .frame(width: 14, height: 16).contentShape(Rectangle())
    }
}

struct DeployDiamond: View {
    var color: Color
    var size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(TodayRibbonCard.trackFill)
            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(color, lineWidth: 2))
            .frame(width: size, height: size).rotationEffect(.degrees(45))
    }
}

enum TodayShipStyle {
    /// Green when it reached production, amber when it failed (it needs you), quiet while running or waiting.
    static func color(_ status: ShippedDay.Release.Status?) -> Color {
        switch status {
        case .failed: AppAppearance.amber
        case .running, .waiting, .cancelled: AppAppearance.tertiary
        case .live, .succeeded, nil: AppAppearance.green
        }
    }
}
