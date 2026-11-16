// The Chats list's pieces, layout only: the "Filter chats" field with its "/" key (pressing / while
// no text field has focus puts the cursor in it), a sticky section header ("● NEEDS YOU · 2",
// amber only for Needs you), the quiet full-width "Show all 50" button at the end of Earlier, and
// a chat row. Every row has the same two lines beside a fixed leading column holding the chat's
// agent: the Burro mark in Claude orange or Codex blue, centred on the two lines, dimmed for idle
// chats, with the state as a small dot on its corner (amber needs you, green working, blue ready
// to read; none when idle). The title runs across the remaining width (a pinned chat's pin at its
// right end); under it, aligned with the title, "place · time". The agent is also read out to
// VoiceOver after the title. Needs you and
// Ready to read rows add one line of what the chat last said when Burro already has it. Active
// titles are semibold; idle ones are regular and dimmer, so the bottom of the list recedes. The
// selected row is filled and carries its state's colour on its leading edge.
import AppKit
import SwiftUI
import BurroCore

struct ChatsFilterField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary)
            TextField("Filter chats", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                .focused(focused).accessibilityLabel("Filter chats")
                .onExitCommand { query = ""; focused.wrappedValue = false }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(AppAppearance.tertiary).help("Clear the filter").accessibilityLabel("Clear the filter")
            } else {
                ChatKey("/")
            }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AppAppearance.hairline))
        .background(ChatsSlashKey { focused.wrappedValue = true })
    }
}

/// Calls `action` when / is pressed in this view's window while no text field or text view is
/// being edited. Installed only while the view is in a window.
private struct ChatsSlashKey: NSViewRepresentable {
    var action: () -> Void
    func makeNSView(context: Context) -> KeyView { KeyView(action: action) }
    func updateNSView(_ view: KeyView, context: Context) { view.action = action }
    final class KeyView: NSView {
        var action: () -> Void
        nonisolated(unsafe) private var monitor: Any?
        init(action: @escaping () -> Void) { self.action = action; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.charactersIgnoringModifiers == "/", event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                let window = event.window
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let own = self.window, window === own, own.isKeyWindow,
                          !(own.firstResponder is NSText), !self.isHiddenOrHasHiddenAncestor else { return false }
                    self.action()
                    return true
                }
                return handled ? nil : event
            }
        }
    }
}

struct ChatsSectionHeader: View {
    var title: String
    var count: Int
    var color: Color
    var emphasised = false
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(0.6)
                .foregroundStyle(emphasised ? color : AppAppearance.secondary)
            Text("\(count)").font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(AppAppearance.tertiary)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 5)
        .background(AppAppearance.background)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(title), \(count)")
    }
}

/// The end of a shortened Earlier: a real button, full width and quiet.
struct ChatsShowAllRow: View {
    var total: Int
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text("Show all \(total)").font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, ChatListRowView.textInset).padding(.vertical, 8)
                .background(hovering ? AppAppearance.hover : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .help("Show every earlier chat")
        .accessibilityLabel("Show all \(total) earlier chats")
    }
}

struct ChatListRowView: View {
    var row: ChatListRow
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    /// The leading column (the provider's avatar) and the gap after it; with the row's padding,
    /// where titles and second lines start.
    static let column: CGFloat = 20
    static let gap: CGFloat = 10
    static let textInset: CGFloat = 10 + column + gap

    var body: some View {
        Button(action: action) {
            HStack(alignment: .twoLineCenter, spacing: Self.gap) {
                ChatRowAvatar(provider: row.provider, id: row.id, status: row.status, animated: selected || hovering,
                              ring: selected ? AppAppearance.raised : AppAppearance.background)
                    .alignmentGuide(.twoLineCenter) { $0[VerticalAlignment.center] }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(row.title).font(.system(size: 13, weight: row.isActive ? .semibold : .regular))
                            .foregroundStyle(row.isActive ? AppAppearance.text : AppAppearance.secondary)
                            .lineLimit(1).truncationMode(.tail)
                        if row.pinned {
                            Spacer(minLength: 4)
                            Image(systemName: "pin.fill").font(.system(size: 8.5)).foregroundStyle(AppAppearance.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    Text(row.meta).font(.system(size: 11)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .alignmentGuide(.twoLineCenter) { $0[.top] - 1.5 }
                    if let preview = row.preview {
                        Text(preview).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
                            .padding(.top, 1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 10).padding(.trailing, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AppAppearance.raised : (hovering ? AppAppearance.hover : .clear),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle().fill(ChatStatusColor.of(row.status)).frame(width: 2).padding(.vertical, 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
    }
}

/// A chat row's leading column: the provider's avatar (dimmed when the chat is idle) with its
/// state as a small dot on the lower right corner, ringed in the row's background so it reads
/// against the mark (amber needs you, green working, blue ready to read; none when idle).
struct ChatRowAvatar: View {
    var provider: AgentProvider
    var id: String
    var status: ChatPageStatus
    var animated = false
    var ring: Color = AppAppearance.background

    var body: some View {
        ProviderAvatar(provider: provider, id: id, active: animated, working: status == .working, size: ChatListRowView.column)
            .opacity(status == .idle ? 0.5 : 1)
            .overlay(alignment: .bottomTrailing) {
                if status != .idle {
                    Circle().fill(ChatStatusColor.of(status)).frame(width: 7, height: 7)
                        .padding(1.5).background(ring, in: Circle())
                        .offset(x: 3, y: 2)
                }
            }
            .frame(width: ChatListRowView.column, height: ChatListRowView.column)
            .accessibilityHidden(true)
    }
}

extension VerticalAlignment {
    /// The middle of a chat row's first two lines (title and "place · time").
    private enum TwoLineCenter: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }
    static let twoLineCenter = VerticalAlignment(TwoLineCenter.self)
}
