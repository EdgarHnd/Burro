// The ⌘K command palette in the main window: a centred card with a search field over a results
// list, drawn like the Notes window's ⌘K card. ⌘K (View ▸ Command Palette…) opens it in the key
// main window and closes it again; Escape or a click outside closes it; ↑/↓ move and Return runs.
// When the Notes window is key it keeps its own ⌘K. Each opening snapshots what the palette can
// offer; typing filters that snapshot. VoiceOver hears the selected row; Reduce Motion drops the
// card's scale and scrolling animations.
import AppKit
import SwiftUI
import BurroCore

enum CommandPalette {
    static let toggleNotification = Notification.Name("BurroCommandPaletteToggle")
    /// Asks the key main window to open or close its palette. The Notes window's own ⌘K wins when it is key.
    @MainActor static func toggle() {
        guard !(NSApp.keyWindow is NotesPanel) else { return }
        NotificationCenter.default.post(name: toggleNotification, object: nil)
    }
}

/// The menu item that owns ⌘K.
struct CommandPaletteCommands: Commands {
    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button("Command Palette…") { CommandPalette.toggle() }.keyboardShortcut("k")
        }
    }
}

/// Attach to the main window's root view: presents the palette over it.
struct CommandPaletteHost: ViewModifier {
    var store: AppStore
    @State private var model: CommandPaletteModel?
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if let model {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.12).ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { close() }
                            .accessibilityHidden(true)
                        CommandPaletteCard(model: model, reduceMotion: reduceMotion, run: run, close: close)
                            .padding(.top, 96).padding(.horizontal, 24)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    }
                }
            }
            .animation(.easeOut(duration: 0.12), value: model == nil)
            .onReceive(NotificationCenter.default.publisher(for: CommandPalette.toggleNotification)) { _ in
                guard activeState == .key else { return }
                if model == nil { open() } else { close() }
            }
            .onChange(of: store.page) { _, _ in close() }
            .onChange(of: store.newChatPresented) { _, presented in if presented { close() } }
    }

    private func open() {
        let settings = openSettings
        model = CommandPaletteModel(store: store, openSettings: { settings() })
    }
    private func close() { if model != nil { model = nil } }
    /// Closes first, so sheets and page changes happen with the card gone.
    private func run(_ item: CommandPaletteItem?) {
        guard let action = model?.action(for: item) else { return }
        close()
        action()
    }
}

private struct CommandPaletteCard: View {
    @Bindable var model: CommandPaletteModel
    var reduceMotion: Bool
    var run: (CommandPaletteItem?) -> Void
    var close: () -> Void
    @FocusState private var focused: Bool
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                TextField("Search pages, chats, projects, machines and actions", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 15))
                    .focused($focused)
                    .accessibilityLabel("Command palette search")
                    .accessibilityHint("Type to filter. Up and down arrows choose a result, Return opens it, Escape closes.")
                    .onSubmit { run(nil) }
                    .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            Divider().opacity(0.6)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if model.results.isEmpty {
                            Text("Nothing matches “\(model.query)”.").font(.system(size: 13)).foregroundStyle(.tertiary).padding(10)
                        }
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                            CommandPaletteRow(item: item, row: model.row(item), selected: index == model.selection,
                                              label: model.spokenLabel(item))
                                .id(index)
                                .onHover { if $0 { model.selection = index } }
                                .onTapGesture { model.selection = index; run(item) }
                                .accessibilityAction { run(item) }
                        }
                    }
                    .padding(8)
                    .background(GeometryReader { geometry in Color.clear.preference(key: PaletteListHeight.self, value: geometry.size.height) })
                }
                // As tall as the list, scrolling only past 420 points.
                .frame(height: min(max(listHeight, 44), 420))
                .onPreferenceChange(PaletteListHeight.self) { listHeight = $0 }
                .onChange(of: model.selection) { _, value in
                    if reduceMotion { proxy.scrollTo(value) } else { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(value) } }
                    announceSelection()
                }
                .onChange(of: model.query) { _, _ in proxy.scrollTo(0, anchor: .top) }
            }
        }
        .frame(maxWidth: 580)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppAppearance.separator))
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
        .accessibilityAddTraits(.isModal)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    /// Focus stays in the field, so VoiceOver is told which row the arrows landed on.
    private func announceSelection() {
        guard NSWorkspace.shared.isVoiceOverEnabled, let item = model.selected else { return }
        let text = model.spokenLabel(item)
        NSAccessibility.post(element: NSApp.keyWindow as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

private struct PaletteListHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct CommandPaletteRow: View {
    var item: CommandPaletteItem
    var row: CommandPaletteModel.Row?
    var selected: Bool
    var label: String

    var body: some View {
        HStack(spacing: 11) {
            Group {
                if let session = row?.session {
                    AgentAvatar(session: session, active: selected, size: 22)
                } else {
                    Image(systemName: row?.symbol ?? "circle").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                if row?.needsYou == true { Circle().fill(AppAppearance.amber).frame(width: 6, height: 6) }
                Text(row?.kindLabel ?? "").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(row?.needsYou == true ? AppAppearance.amber : AppAppearance.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
