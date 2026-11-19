// The dashboard's joined panels: one outer surface holding rows of cells separated by 1-point
// hairlines, never floating cards with gaps. A row splits its width by weights (2:1 for the main
// row, 1:1:1 for the bottom row) and every cell in it is as tall as the tallest; below the row's
// `stackBelow` width its cells stack full width with horizontal hairlines instead. `Panel` is the
// usual cell: a 13-point semibold title, one grey subtitle line, its content and an optional footer.
// The surface is one fill under everything (`opacity` 1 by default; Home lays it over its aquarium at
// about 0.9, no blur, no material, no shadow), cells draw no fill of their own inside it
// (`panelFill` is clear there), and the hairlines are 1-point separator strokes the layouts place in
// the 1-point gaps between cells and rows, so they read the same over an opaque or a see-through fill.
import SwiftUI
import BurroCore

/// What a panel cell fills itself with: the surface on its own, nothing inside `JoinedPanels` (whose
/// one fill shows through). Read by `Panel` and `PanelCell`.
private struct PanelFillKey: EnvironmentKey { static let defaultValue: Color = AppAppearance.surface }

extension EnvironmentValues {
    var panelFill: Color {
        get { self[PanelFillKey.self] }
        set { self[PanelFillKey.self] = newValue }
    }
}

struct JoinedPanels<Content: View>: View {
    /// The surface's opacity: 1 on a plain page, about 0.9 over Home's aquarium.
    var opacity: Double = 1
    @ViewBuilder var content: () -> Content
    var body: some View {
        JoinedStackLayout {
            content()
            JoinedHairlines(count: JoinedHairlines.pool)
        }
        .environment(\.panelFill, .clear)
        .clipShape(RoundedRectangle(cornerRadius: AppAppearance.cardRadius, style: .continuous))
        .modifier(SoftSurface(radius: AppAppearance.cardRadius, fill: AppAppearance.surface.opacity(opacity),
                              shadowRadius: opacity < 1 ? 0 : 10, y: opacity < 1 ? 0 : 3))
    }
}

/// One row of a `JoinedPanels`; each child is a cell.
struct JoinedRow<Content: View>: View {
    var weights: [CGFloat]
    var stackBelow: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View {
        JoinedRowLayout(weights: weights, stackBelow: stackBelow) {
            content()
            JoinedHairlines(count: JoinedHairlines.pool)
        }
    }
}

/// A pool of 1-point separator strokes a joined layout places between its cells; the ones it
/// doesn't need get no size. Marked with `JoinedHairlineKey` so the layouts can tell them from cells.
struct JoinedHairlines: View {
    static let pool = 4
    var count: Int
    var body: some View {
        ForEach(0..<count, id: \.self) { _ in
            Rectangle().fill(AppAppearance.separator).allowsHitTesting(false).accessibilityHidden(true)
                .layoutValue(key: JoinedHairlineKey.self, value: true)
        }
    }
}

struct JoinedHairlineKey: LayoutValueKey { static let defaultValue = false }

extension SwiftUI.Layout {
    /// Splits a joined layout's subviews into cells and its hairline pool.
    func joinedParts(_ subviews: Subviews) -> (cells: [LayoutSubview], lines: [LayoutSubview]) {
        var cells: [LayoutSubview] = [], lines: [LayoutSubview] = []
        for subview in subviews { if subview[JoinedHairlineKey.self] { lines.append(subview) } else { cells.append(subview) } }
        return (cells, lines)
    }

    /// Places `frames` on the pool's hairlines and gives the rest no size.
    func placeHairlines(_ lines: [LayoutSubview], frames: [CGRect], in bounds: CGRect) {
        for (index, line) in lines.enumerated() {
            let frame = index < frames.count ? frames[index] : .zero
            line.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

/// The rows of a `JoinedPanels`, full width, 1 point apart, with a hairline in each gap.
struct JoinedStackLayout: SwiftUI.Layout {
    private func frames(_ cells: [LayoutSubview], width: CGFloat) -> [CGRect] {
        var y: CGFloat = 0
        return cells.map { cell in
            let height = cell.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            defer { y += height + JoinedRowLayout.gap }
            return CGRect(x: 0, y: y, width: width, height: height)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        return CGSize(width: width, height: frames(joinedParts(subviews).cells, width: width).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let parts = joinedParts(subviews)
        let frames = frames(parts.cells, width: bounds.width)
        for (cell, frame) in zip(parts.cells, frames) {
            cell.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
        placeHairlines(parts.lines, frames: frames.dropLast().map { CGRect(x: 0, y: $0.maxY, width: bounds.width, height: JoinedRowLayout.gap) },
                       in: bounds)
    }
}

struct JoinedRowLayout: SwiftUI.Layout {
    var weights: [CGFloat]
    var stackBelow: CGFloat
    static let gap: CGFloat = 1

    func stacked(_ width: CGFloat) -> Bool { width < stackBelow }

    private func frames(_ cells: [LayoutSubview], width: CGFloat) -> [CGRect] {
        let count = cells.count
        guard count > 0 else { return [] }
        if stacked(width) {
            var y: CGFloat = 0
            return cells.map { cell in
                let height = cell.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                defer { y += height + Self.gap }
                return CGRect(x: 0, y: y, width: width, height: height)
            }
        }
        let weights = (0..<count).map { $0 < self.weights.count ? max(0.01, self.weights[$0]) : 1 }
        let total = weights.reduce(0, +), available = width - CGFloat(count - 1) * Self.gap
        var x: CGFloat = 0
        var columns: [(x: CGFloat, width: CGFloat)] = []
        for (index, weight) in weights.enumerated() {
            // The last cell takes what rounding left, so the row ends exactly at the edge.
            let cellWidth = index == count - 1 ? width - x : (available * weight / total).rounded()
            columns.append((x, cellWidth))
            x += cellWidth + Self.gap
        }
        let height = zip(cells, columns).map { $0.sizeThatFits(ProposedViewSize(width: $1.width, height: nil)).height }.max() ?? 0
        return columns.map { CGRect(x: $0.x, y: 0, width: $0.width, height: height) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        return CGSize(width: width, height: frames(joinedParts(subviews).cells, width: width).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let parts = joinedParts(subviews)
        let frames = frames(parts.cells, width: bounds.width)
        for (cell, frame) in zip(parts.cells, frames) {
            cell.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
        let lines = frames.dropLast().map { frame in
            stacked(bounds.width) ? CGRect(x: 0, y: frame.maxY, width: bounds.width, height: Self.gap)
                : CGRect(x: frame.maxX, y: 0, width: Self.gap, height: frame.height)
        }
        placeHairlines(parts.lines, frames: lines, in: bounds)
    }
}

/// An untitled cell (the queues): padded, top-leading, filled like a `Panel`.
struct PanelCell<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: () -> Content
    @Environment(\.panelFill) private var fill
    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(fill)
    }
}

/// A titled cell: title, a grey subtitle (toned runs allowed), the content, an optional footer.
struct Panel<Trailing: View, Content: View, Footer: View>: View {
    var title: String
    var subtitle: [TextRun] = []
    var padding: CGFloat = 20
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer
    @Environment(\.panelFill) private var fill

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppAppearance.text).lineLimit(1)
                Spacer(minLength: 8)
                trailing()
            }
            if !subtitle.isEmpty {
                TextRuns.text(subtitle).font(.system(size: 12)).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            content().padding(.top, 14)
            Spacer(minLength: 0)
            footer()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(fill)
    }
}

extension Panel where Footer == EmptyView {
    init(title: String, subtitle: [TextRun] = [], padding: CGFloat = 20, @ViewBuilder trailing: @escaping () -> Trailing,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, padding: padding, trailing: trailing, content: content, footer: { EmptyView() })
    }
}

extension Panel where Trailing == EmptyView, Footer == EmptyView {
    init(title: String, subtitle: [TextRun] = [], padding: CGFloat = 20, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, padding: padding, trailing: { EmptyView() }, content: content, footer: { EmptyView() })
    }
}
