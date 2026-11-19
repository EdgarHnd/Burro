// The marks the Today page draws on its time lanes (AgentLanes.swift lays the lanes out): a
// tracked block (a bar in its category's colour; hover says what it was, click zooms the lanes to
// that hour), a stretch Burro wasn't recording (hatched, "Not recording" when there's room), a long
// away stretch (empty between dashed edges, labelled with its length), and on the Shipped lane a
// tick per merged pull request and a diamond per production deploy (click opens it on GitHub).
// Plain values in, so snapshots can draw them with invented data.
import AppKit
import SwiftUI
import BurroCore

/// A tick or diamond on the Shipped lane.
struct TodayRibbonShip: Identifiable {
    enum Kind { case merged, deploy(ShippedDay.Release.Status?) }
    var id: String
    var kind: Kind
    var at: Date
    var title: String
    var url: URL?
}

enum TodayRibbonStyle {
    static let trackFill = AppAppearance.adaptive(light: (0, 0, 0, 0.035), dark: (0, 0, 0, 0.22))

    static func clock(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// A tracked block: a solid bar in its category's colour; hover for what it was, click to zoom.
struct RibbonBlock: View {
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
struct NotRecordingMark: View {
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
struct AwayMark: View {
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

/// A merged pull request (a tick) or a production deploy (a diamond); click opens it on GitHub.
struct ShipMark: View {
    var ship: TodayRibbonShip
    var body: some View {
        if ship.url == nil {
            mark.help("\(ship.title)\n\(TodayRibbonStyle.clock(ship.at))").accessibilityLabel("\(ship.title), \(TodayRibbonStyle.clock(ship.at))")
        } else {
            Button { if let url = ship.url { NSWorkspace.shared.open(url) } } label: { mark }
                .buttonStyle(.plain)
                .help("\(ship.title)\n\(TodayRibbonStyle.clock(ship.at)) · click to open on GitHub")
                .accessibilityLabel("\(ship.title), \(TodayRibbonStyle.clock(ship.at))")
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
        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(TodayRibbonStyle.trackFill)
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
