// The dashboard KPI strip: one row of equal cells joined by 1-point hairlines on a single surface.
// A cell is a small grey label (an optional dot before it, an optional word at its end), a large
// number with monospaced digits (an optional small word before it, "about"), and one quiet line
// under it that can lead with a small accessory (avatars, a sparkline) and carry toned runs, then an
// optional footer (a thin bar). Four cells fold into 2×2 when the strip is narrow; three stay in a
// row until very narrow, then stack, so no slot is ever empty. `bare` draws no surface at all (Home
// sets it straight on its aquarium): only the hairlines, and the strip reaches past the column by
// its cells' padding so the first number lines up with the text above it. Plain values in, so
// snapshot tests can draw it. Today and Home use it; Mac Health's vitals row too.
import SwiftUI
import BurroCore

struct StatCellData: Identifiable {
    var id: String
    var label: String
    /// The dot before the label (amber for "Waiting on you").
    var dot: Color? = nil
    /// A word at the end of the label row ("Recording").
    var badge: (text: String, color: Color)? = nil
    var value: String
    var valuePrefix: String? = nil
    /// The number isn't known ("—"): drawn grey.
    var muted = false
    /// The number in a colour of its own (Worktrees' uncommitted work in amber); nil draws it in text colour.
    var valueColor: Color? = nil
    var sub: [TextRun] = []
    var help: String? = nil
    /// Leads the sub-line: provider avatars, a sparkline.
    var accessory: AnyView? = nil
    /// Under the sub-line: a thin bar.
    var footer: AnyView? = nil
    /// Makes the number and its lines a link (not the whole cell, so a bare strip leaves its gaps to what is behind).
    var action: (() -> Void)? = nil
}

struct StatStrip: View {
    var cells: [StatCellData]
    /// Below this width four cells fold into 2×2.
    var narrowBelow: CGFloat = 640
    /// No surface: hairlines only, for a strip set straight on a backdrop.
    var bare = false
    static let inset: CGFloat = 18

    var body: some View {
        let grid = StatGridLayout(narrowBelow: narrowBelow + (bare ? Self.inset * 2 : 0)) {
            ForEach(cells) { StatCell(cell: $0, bare: bare) }
            JoinedHairlines(count: max(0, cells.count - 1))
        }
        if bare {
            grid.padding(.horizontal, -Self.inset)
        } else {
            grid
                .clipShape(RoundedRectangle(cornerRadius: AppAppearance.cardRadius, style: .continuous))
                .modifier(SoftSurface(radius: AppAppearance.cardRadius))
        }
    }
}

private struct StatCell: View {
    var cell: StatCellData
    /// On a backdrop: the label one tone stronger, so it holds over whatever passes behind it.
    var bare = false
    var body: some View {
        Group {
            if let action = cell.action {
                Button(action: action) { content }.buttonStyle(.plain)
            } else {
                content
            }
        }
        .padding(.horizontal, StatStrip.inset).padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .help(cell.help ?? "")
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let dot = cell.dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(cell.label).font(.system(size: 12, weight: .medium)).foregroundStyle(bare ? AppAppearance.secondary : AppAppearance.tertiary).lineLimit(1)
                if let badge = cell.badge {
                    Spacer(minLength: 6)
                    Text(badge.text).font(.system(size: 11, weight: .medium)).foregroundStyle(badge.color).lineLimit(1).fixedSize()
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let prefix = cell.valuePrefix {
                    Text(prefix).font(.system(size: 13)).foregroundStyle(AppAppearance.secondary)
                }
                Text(cell.value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(cell.muted ? AppAppearance.tertiary : cell.valueColor ?? AppAppearance.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            if cell.accessory != nil || !cell.sub.isEmpty {
                HStack(spacing: 6) {
                    if let accessory = cell.accessory { accessory }
                    TextRuns.text(cell.sub, base: bare ? AppAppearance.secondary : AppAppearance.tertiary).font(.system(size: 12)).monospacedDigit()
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            if let footer = cell.footer { footer.padding(.top, 2) }
        }
    }
}

/// Equal-width cells with 1-point gaps and a hairline in each (the strip's `JoinedHairlines` pool);
/// each row is as tall as its tallest cell.
struct StatGridLayout: SwiftUI.Layout {
    var narrowBelow: CGFloat
    static let gap: CGFloat = 1

    private func columns(_ count: Int, width: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        if width >= narrowBelow { return count }
        if count == 4 { return 2 }
        return width >= narrowBelow * 0.7 ? count : 1
    }

    private func frames(_ cells: [LayoutSubview], width: CGFloat) -> (cells: [CGRect], lines: [CGRect]) {
        let count = cells.count, cols = columns(count, width: width)
        let cellWidth = (width - CGFloat(cols - 1) * Self.gap) / CGFloat(cols)
        var frames: [CGRect] = [], lines: [CGRect] = [], y: CGFloat = 0
        for rowStart in stride(from: 0, to: count, by: cols) {
            let row = rowStart..<min(count, rowStart + cols)
            let height = row.map { cells[$0].sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height }.max() ?? 0
            if rowStart > 0 { lines.append(CGRect(x: 0, y: y - Self.gap, width: width, height: Self.gap)) }
            for column in 0..<row.count {
                let x = CGFloat(column) * (cellWidth + Self.gap)
                frames.append(CGRect(x: x, y: y, width: cellWidth, height: height))
                if column > 0 { lines.append(CGRect(x: x - Self.gap, y: y, width: Self.gap, height: height)) }
            }
            y += height + Self.gap
        }
        return (frames, lines)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        return CGSize(width: width, height: frames(joinedParts(subviews).cells, width: width).cells.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let parts = joinedParts(subviews)
        let layout = frames(parts.cells, width: bounds.width)
        for (cell, frame) in zip(parts.cells, layout.cells) {
            cell.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
        placeHairlines(parts.lines, frames: layout.lines, in: bounds)
    }
}
