// The Notes window's content: the note's title, the editor, a character count, and the ⌘P
// browser and ⌘K actions drawn as floating cards over the note.
import SwiftUI

struct NotesPanelView: View {
    @Bindable var model: NotesPanelModel
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                header
                NoteEditor(noteID: model.currentID, text: model.text, onChange: model.setText, onEscape: model.escape,
                           register: { model.textView = $0 })
                    .padding(.horizontal, 26)
                footer
            }
            if model.overlay != .none {
                Color.black.opacity(0.08).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { model.overlay = .none; model.focusEditor() }
                overlayCard.padding(.top, 50).padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.overlay)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0; model.showChrome(hovering) }
        .ignoresSafeArea()
    }

    private var header: some View {
        ZStack {
            Text(model.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.tertiary).lineLimit(1)
                .padding(.horizontal, 110)
            HStack(spacing: 2) {
                // The window's own traffic lights sit on the left (shown on hover by the controller).
                if model.current?.isPinned == true {
                    Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.leading, 82)
                }
                Spacer()
                HStack(spacing: 0) {
                    toolbarButton("command", help: "Actions (⌘K)") { model.overlay = model.overlay == .actions ? .none : .actions }
                    toolbarButton("square.on.square", help: "Browse notes (⌘P)") { model.overlay = model.overlay == .browse ? .none : .browse }
                    toolbarButton("plus", help: "New note (⌘N)") { model.newNote() }
                }
                .padding(.horizontal, 4)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
                .opacity(hovering || model.overlay != .none ? 1 : 0)
            }
            .padding(.trailing, 8)
        }
        .frame(height: 40)
    }

    private func toolbarButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(.primary.opacity(0.85))
                .frame(width: 30, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    private var footer: some View {
        ZStack {
            Text(model.notice ?? "\(model.characters) characters").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                .contentTransition(.opacity)
            HStack {
                Spacer()
                Menu {
                    Button("Checklist  ⇧⌘L") { model.toggleChecklist() }
                    Button("Find  ⌘F") { model.find() }
                    Divider()
                    Button("Copy as Markdown") { model.copy(plain: false) }
                    Button("Copy as Plain Text") { model.copy(plain: true) }
                } label: {
                    Image(systemName: "textformat").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 26, height: 26).background(.quaternary.opacity(0.6), in: Circle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .opacity(hovering ? 1 : 0)
            }
            .padding(.trailing, 12)
        }
        .frame(height: 38)
        .animation(.easeOut(duration: 0.15), value: model.notice)
    }

    @ViewBuilder private var overlayCard: some View {
        switch model.overlay {
        case .browse: NotesBrowser(model: model)
        case .actions: NotesActions(model: model)
        case .confirmDelete: DeleteConfirm(model: model)
        case .none: EmptyView()
        }
    }
}

/// The shared look of the ⌘P and ⌘K cards: a search field over a list.
private struct OverlayCard<Rows: View>: View {
    @Bindable var model: NotesPanelModel
    var placeholder: String
    @ViewBuilder var rows: () -> Rows
    @FocusState private var focused: Bool
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            TextField(placeholder, text: $model.query)
                .textFieldStyle(.plain).font(.system(size: 15))
                .padding(.horizontal, 16).padding(.vertical, 13)
                .focused($focused)
                .onSubmit { model.runSelection() }
                .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                .onKeyPress(.escape) { model.escape(); return .handled }
            Divider().opacity(0.6)
            // As tall as the list, scrolling only past 380 points.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) { rows() }.padding(8)
                        .background(GeometryReader { geometry in Color.clear.preference(key: ListHeight.self, value: geometry.size.height) })
                }
                .frame(height: min(max(listHeight, 44), 380))
                .onPreferenceChange(ListHeight.self) { listHeight = $0 }
                .onChange(of: model.selection) { _, value in withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(value) } }
            }
        }
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

private struct ListHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct NotesBrowser: View {
    @Bindable var model: NotesPanelModel
    var body: some View {
        let results = model.browseResults
        OverlayCard(model: model, placeholder: "Search for notes…") {
            Text(model.query.isEmpty ? "Notes" : "\(results.count) found").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 4)
            if results.isEmpty {
                Text("No notes match.").font(.system(size: 13)).foregroundStyle(.tertiary).padding(10)
            }
            ForEach(Array(results.enumerated()), id: \.element.id) { index, note in
                NoteRow(note: note, current: note.id == model.currentID, selected: index == model.selection,
                        open: { model.open(note.id) },
                        pin: { model.notes.togglePin(note.id) },
                        delete: { model.delete(note.id) })
                    .id(index)
                    .onHover { if $0 { model.selection = index } }
            }
        }
    }
}

private struct NoteRow: View {
    var note: HomeNote
    var current: Bool
    var selected: Bool
    var open: () -> Void
    var pin: () -> Void
    var delete: () -> Void
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if note.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                    Text(note.isEmpty ? "New Note" : NoteText.title(note.content)).font(.system(size: 14, weight: .medium)).lineLimit(1)
                }
                HStack(spacing: 5) {
                    if current { Circle().fill(Color.accentColor).frame(width: 5, height: 5) }
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if selected {
                Button(action: pin) { Image(systemName: note.isPinned ? "pin.slash" : "pin") }
                    .buttonStyle(.plain).help(note.isPinned ? "Unpin" : "Pin")
                Button { if confirming { delete() } else { confirming = true } } label: {
                    if confirming { Text("Delete?").font(.system(size: 12, weight: .semibold)).foregroundStyle(.red) }
                    else { Image(systemName: "trash") }
                }
                .buttonStyle(.plain).help("Delete")
            }
        }
        .font(.system(size: 13)).foregroundStyle(.primary)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onChange(of: selected) { _, value in if !value { confirming = false } }
    }

    private var subtitle: String {
        let count = "\(NoteText.visibleCount(note.content)) characters"
        if current { return "Current · \(count)" }
        let opened = note.openedAt ?? note.updatedAt
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return "Opened \(formatter.localizedString(for: opened, relativeTo: Date())) · \(count)"
    }
}

private struct NotesActions: View {
    @Bindable var model: NotesPanelModel
    var body: some View {
        let actions = model.actions
        OverlayCard(model: model, placeholder: "Search for actions…") {
            if actions.isEmpty {
                Text("No actions match.").font(.system(size: 13)).foregroundStyle(.tertiary).padding(10)
            }
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                HStack(spacing: 11) {
                    Image(systemName: action.symbol).font(.system(size: 13, weight: .medium)).frame(width: 20)
                        .foregroundStyle(action.title == "Delete Note" ? Color.red : .secondary)
                    Text(action.title).font(.system(size: 14)).foregroundStyle(action.title == "Delete Note" ? Color.red : .primary)
                    Spacer(minLength: 8)
                    HStack(spacing: 3) {
                        ForEach(action.keys, id: \.self) { key in
                            Text(key).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                .frame(minWidth: 20, minHeight: 20)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.secondary.opacity(0.4)))
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(index == model.selection ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { model.selection = index; action.run() }
                .onHover { if $0 { model.selection = index } }
                .id(index)
            }
        }
    }
}

private struct DeleteConfirm: View {
    @Bindable var model: NotesPanelModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete “\(model.title)”?").font(.system(size: 15, weight: .semibold))
            Text("It's removed from this Mac. This can't be undone.").font(.system(size: 12.5)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.escape() }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) { model.delete() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(maxWidth: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
    }
}
