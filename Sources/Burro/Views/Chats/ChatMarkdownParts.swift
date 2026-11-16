// Two pieces of a chat reply's Markdown, layout only (the parsing is `ChatMarkdown` in BurroCore).
// A table is a quiet grid: the header row semibold in the secondary colour, hairlines between
// rows, numbers in monospaced digits, every cell selectable and holding its inline Markdown, each
// column as wide as its content up to 360 pt (longer cells wrap). A table wider than the
// conversation column scrolls sideways instead of squashing. A note is one line made from a Codex
// directive: a small glyph (an inbox tray for an inbox item, a speech bubble for a code comment),
// its title, then its summary in secondary text; the whole text is in its tooltip.
import SwiftUI
import BurroCore

struct ChatTableView: View {
    var table: ChatTable
    var size: CGFloat
    /// The widest a column grows before its cells wrap.
    static let cellCap: CGFloat = 360

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal) { grid.padding(.bottom, 8) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var grid: some View {
        let columns = Array(0..<table.columns)
        return Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 0) {
            GridRow {
                ForEach(columns, id: \.self) { column in
                    cell(table.header[column], column: column, header: true)
                        .gridColumnAlignment(Self.alignment(table.alignments[column]))
                }
            }
            hairline(strong: true)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(columns, id: \.self) { column in cell(row[column], column: column, header: false) }
                }
                if index < table.rows.count - 1 { hairline(strong: false) }
            }
        }
        .textSelection(.enabled)
        .fixedSize()
    }

    private func cell(_ text: String, column: Int, header: Bool) -> some View {
        let alignment = table.alignments[column]
        return CappedWidth(cap: Self.cellCap) {
            Text(MarkdownBlock.inline(text))
                .font(.system(size: size - 1, weight: header ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(header ? AppAppearance.secondary : AppAppearance.text)
                .multilineTextAlignment(alignment == .trailing ? .trailing : (alignment == .center ? .center : .leading))
                .lineSpacing(2)
        }
        .padding(.vertical, header ? 5 : 6)
    }

    private func hairline(strong: Bool) -> some View {
        Rectangle().fill(strong ? AppAppearance.separator : AppAppearance.separator.opacity(0.6)).frame(height: 1)
            .gridCellUnsizedAxes(.horizontal)
    }

    static func alignment(_ value: ChatTable.Alignment) -> HorizontalAlignment {
        switch value {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// Lays its content out at its natural width, but never wider than `cap` (it wraps there).
private struct CappedWidth: SwiftUI.Layout {
    var cap: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let width = min(view.sizeThatFits(.unspecified).width, cap, proposal.width ?? .infinity)
        return CGSize(width: width, height: view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

struct ChatNoteLine: View {
    var note: ChatNote
    var size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: note.kind == .inbox ? "tray" : "text.bubble")
                .font(.system(size: size - 3, weight: .medium)).foregroundStyle(AppAppearance.tertiary)
                .accessibilityHidden(true)
            Text(line).font(.system(size: size - 1)).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppAppearance.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(AppAppearance.hairline))
        .help([note.title, note.detail].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel([note.kind == .inbox ? "Inbox item" : "Code comment", note.title, note.detail].compactMap { $0 }.joined(separator: ", "))
    }

    /// The title, then the detail in secondary text.
    private var line: AttributedString {
        var title = AttributedString(note.title)
        title.font = .system(size: size - 1, weight: .medium)
        title.foregroundColor = AppAppearance.text
        guard let detail = note.detail else { return title }
        var rest = AttributedString("   " + detail)
        rest.foregroundColor = AppAppearance.secondary
        return title + rest
    }
}
