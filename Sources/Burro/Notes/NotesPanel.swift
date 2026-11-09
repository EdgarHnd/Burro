// Burro Notes: a floating notes window on ⌥P from anywhere, in the spirit of Raycast Notes. It
// floats over every app and Space without activating Burro (so the app you were in keeps its
// place), edits the same notes Home lists, and offers ⌘P to browse and ⌘K for actions.
import AppKit
import SwiftUI

/// Where the Notes window should open.
enum NotesTarget: Equatable { case last, note(UUID), new }

/// A key panel that never activates Burro, with its own shortcuts.
final class NotesPanel: NSPanel {
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

struct NoteAction: Identifiable {
    var id: String { title }
    var title: String
    var symbol: String
    var keys: [String] = []
    var run: () -> Void
}

@MainActor @Observable final class NotesPanelModel {
    enum Overlay: Equatable { case none, browse, actions, confirmDelete }

    let notes: NotesStore
    private(set) var currentID: UUID?
    var overlay: Overlay = .none { didSet { if overlay != oldValue { query = ""; selection = 0 } } }
    var query = "" { didSet { if query != oldValue { selection = 0 } } }
    var selection = 0
    private(set) var notice: String?

    @ObservationIgnored weak var textView: NoteTextView?
    @ObservationIgnored var hide: () -> Void = {}
    /// Shows or hides the window's traffic lights (on hover, like Raycast).
    @ObservationIgnored var showChrome: (Bool) -> Void = { _ in }
    @ObservationIgnored var sendToOrchestrator: (String) -> Void = { _ in }
    @ObservationIgnored var addTodos: ([String]) -> Void = { _ in }
    @ObservationIgnored private var back: [UUID] = []
    @ObservationIgnored private var forward: [UUID] = []
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults

    init(notes: NotesStore, defaults: UserDefaults = .standard) {
        self.notes = notes
        self.defaults = defaults
    }

    var current: HomeNote? { currentID.flatMap(notes.note) }
    var text: String { current?.content ?? "" }
    var title: String { current.map { $0.isEmpty ? "New Note" : NoteText.title($0.content) } ?? "Notes" }
    var characters: Int { NoteText.visibleCount(text) }

    // MARK: Navigation

    func open(_ target: NotesTarget) {
        switch target {
        case .new: newNote()
        case .note(let id): open(id)
        case .last:
            if current != nil { return }
            if let saved = defaults.string(forKey: "notes.panel.current").flatMap(UUID.init(uuidString:)), notes.note(saved) != nil {
                open(saved, record: false)
            } else if let recent = notes.browseOrder.first(where: { !$0.isEmpty }) {
                open(recent.id, record: false)
            } else {
                newNote()
            }
        }
    }

    func open(_ id: UUID, record: Bool = true) {
        overlay = .none
        guard id != currentID, notes.note(id) != nil else { focusEditor(); return }
        if let previous = currentID {
            if record { back.append(previous); forward.removeAll() }
            notes.removeIfEmpty(previous)
        }
        currentID = id
        notes.markOpened(id)
        defaults.set(id.uuidString, forKey: "notes.panel.current")
    }

    func newNote() {
        if let current, current.isEmpty { overlay = .none; focusEditor(); return }
        open(notes.create().id)
    }

    func goBack() {
        while let id = back.popLast() {
            guard notes.note(id) != nil else { continue }
            if let currentID { forward.append(currentID) }
            open(id, record: false)
            return
        }
    }
    func goForward() {
        while let id = forward.popLast() {
            guard notes.note(id) != nil else { continue }
            if let currentID { back.append(currentID) }
            open(id, record: false)
            return
        }
    }

    // MARK: Editing

    func setText(_ text: String) {
        guard let currentID else { return }
        notes.setText(currentID, text)
    }

    func duplicate() {
        guard let currentID, let copy = notes.duplicate(currentID) else { return }
        open(copy.id)
        flash("Duplicated")
    }
    func togglePin() {
        guard let currentID else { return }
        notes.togglePin(currentID)
        flash(current?.isPinned == true ? "Pinned" : "Unpinned")
    }
    func delete(_ id: UUID? = nil) {
        guard let id = id ?? currentID else { return }
        notes.remove(id)
        back.removeAll { $0 == id }; forward.removeAll { $0 == id }
        if id == currentID {
            currentID = nil
            if let next = notes.browseOrder.first(where: { !$0.isEmpty }) { open(next.id, record: false) } else { newNote() }
        }
        overlay = .none
        flash("Deleted")
    }
    func copy(plain: Bool) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plain ? NoteText.plain(text) : text, forType: .string)
        overlay = .none
        flash(plain ? "Copied as plain text" : "Copied as Markdown")
    }
    func sendToOrchestratorNow() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { flash("This note is empty"); return }
        overlay = .none
        sendToOrchestrator(body)
    }
    func addOpenItemsToTodos() {
        let items = NoteText.openItems(text)
        overlay = .none
        guard !items.isEmpty else { flash("No open checklist items"); return }
        addTodos(items)
        flash(items.count == 1 ? "Added 1 to-do" : "Added \(items.count) to-dos")
    }
    func toggleChecklist() { overlay = .none; textView?.toggleChecklist() }
    func find() { overlay = .none; textView?.showFind() }

    func escape() {
        if overlay != .none { overlay = .none; focusEditor() } else { hide() }
    }
    func focusEditor() {
        guard let textView else { return }
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
    }
    func flash(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Lists

    var browseResults: [HomeNote] {
        let visible = notes.browseOrder.filter { !$0.isEmpty || $0.id == currentID }
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return visible }
        return visible.filter { $0.content.localizedCaseInsensitiveContains(query) }
    }

    var actions: [NoteAction] {
        let all = [
            NoteAction(title: "New Note", symbol: "plus", keys: ["⌘", "N"]) { [unowned self] in newNote() },
            NoteAction(title: "Duplicate Note", symbol: "plus.square.on.square", keys: ["⌘", "D"]) { [unowned self] in duplicate() },
            NoteAction(title: "Send to Orchestrator", symbol: "sparkles", keys: ["⌘", "J"]) { [unowned self] in sendToOrchestratorNow() },
            NoteAction(title: current?.isPinned == true ? "Unpin Note" : "Pin Note", symbol: "pin", keys: ["⇧", "⌘", "P"]) { [unowned self] in togglePin(); overlay = .none },
            NoteAction(title: "Browse Notes", symbol: "square.on.square", keys: ["⌘", "P"]) { [unowned self] in overlay = .browse },
            NoteAction(title: "Go Back", symbol: "arrow.left.circle", keys: ["⌘", "["]) { [unowned self] in goBack(); overlay = .none },
            NoteAction(title: "Go Forward", symbol: "arrow.right.circle", keys: ["⌘", "]"]) { [unowned self] in goForward(); overlay = .none },
            NoteAction(title: "Toggle Checklist", symbol: "checklist", keys: ["⇧", "⌘", "L"]) { [unowned self] in toggleChecklist() },
            NoteAction(title: "Find in Note", symbol: "text.magnifyingglass", keys: ["⌘", "F"]) { [unowned self] in find() },
            NoteAction(title: "Copy as Markdown", symbol: "doc.on.clipboard", keys: ["⇧", "⌘", "C"]) { [unowned self] in copy(plain: false) },
            NoteAction(title: "Copy as Plain Text", symbol: "doc.plaintext") { [unowned self] in copy(plain: true) },
            NoteAction(title: "Add Open Items to To-dos", symbol: "checkmark.circle") { [unowned self] in addOpenItemsToTodos() },
            NoteAction(title: "Delete Note", symbol: "trash") { [unowned self] in overlay = .confirmDelete },
        ]
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    func moveSelection(_ delta: Int) {
        let count = overlay == .browse ? browseResults.count : actions.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }
    func runSelection() {
        switch overlay {
        case .browse:
            let results = browseResults
            if results.indices.contains(selection) { open(results[selection].id) }
        case .actions:
            let list = actions
            if list.indices.contains(selection) { list[selection].run() }
        case .confirmDelete: delete()
        case .none: break
        }
    }

    // MARK: Keys

    /// Panel shortcuts. Editing keys go to the focused text (the app may not be active, so the
    /// Edit menu can't be relied on), and ⌘Q only closes the window, never quits Burro.
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command {
            switch key {
            case "n": newNote()
            case "d": duplicate()
            case "j": sendToOrchestratorNow()
            case "p": overlay = overlay == .browse ? .none : .browse
            case "k": overlay = overlay == .actions ? .none : .actions
            case "[": goBack()
            case "]": goForward()
            case "f": find()
            case "w", "q": hide()
            case "a": NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            case "c": NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            case "v": NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            case "x": NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            case "z": NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
            default: return false
            }
            return true
        }
        if flags == [.command, .shift] {
            switch key {
            case "p": togglePin()
            case "c": copy(plain: false)
            case "l": toggleChecklist()
            case "z": NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
            default: return false
            }
            return true
        }
        return false
    }
}

/// Owns the panel and the ⌥P shortcut.
@MainActor final class NotesPanelController: NSObject, NSWindowDelegate {
    private var panel: NotesPanel?
    private var model: NotesPanelModel?
    private var hotKey: GlobalHotKey?
    private weak var store: AppStore?
    private var openDashboard: () -> Void = {}

    func start(store: AppStore, openDashboard: @escaping () -> Void) {
        guard self.store == nil else { return }
        self.store = store
        self.openDashboard = openDashboard
        store.showNotes = { [weak self] target in self?.show(target) }
        store.onNotesShortcutChange = { [weak self] in self?.updateHotKey() }
        updateHotKey()
    }

    func updateHotKey() {
        hotKey?.unregister()
        hotKey = nil
        guard let store, store.notesShortcut else { store?.notesShortcutProblem = nil; return }
        hotKey = GlobalHotKey(keyCode: GlobalHotKey.notesKeyCode, modifiers: GlobalHotKey.notesModifiers, id: 1) { [weak self] in self?.toggle() }
        store.notesShortcutProblem = hotKey == nil ? "macOS didn't give Burro ⌥P. Another app (Raycast Notes?) may be using it." : nil
    }

    /// ⌥P: shows the window, or hides it whenever it's on screen (focused or not).
    func toggle() {
        if let panel, panel.isVisible { hide() } else { show(.last) }
    }

    func show(_ target: NotesTarget) {
        guard let store else { return }
        let panel = self.panel ?? makePanel(store: store)
        model?.open(target)
        if !panel.isVisible && !panel.setFrameUsingName("BurroNotes") { place(panel) }
        panel.orderFrontRegardless()
        panel.makeKey()
        if let textView = model?.textView { panel.makeFirstResponder(textView) }
        model?.focusEditor()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        model?.overlay = .none
        store?.notes.flush()
        panel.saveFrame(usingName: "BurroNotes")
        panel.orderOut(nil)
    }

    private func makePanel(store: AppStore) -> NotesPanel {
        let model = NotesPanelModel(notes: store.notes)
        model.hide = { [weak self] in self?.hide() }
        model.sendToOrchestrator = { [weak self, weak store] text in
            guard let self, let store else { return }
            store.orchestrator.draft = text
            store.page = .orchestrator
            self.hide()
            self.openDashboard()
        }
        model.addTodos = { [weak store] items in items.forEach { store?.todos.add($0) } }

        let panel = NotesPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                               styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // A compact toolbar centres the traffic lights in a 38-point title area, like Raycast Notes.
        let toolbar = NSToolbar(identifier: "BurroNotes")
        toolbar.showsBaselineSeparator = false
        panel.toolbar = toolbar
        panel.toolbarStyle = .unifiedCompact
        panel.delegate = self
        // Close works (it hides the window); minimise and zoom show greyed out, as in Raycast.
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { panel.standardWindowButton($0) }
        panel.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        panel.standardWindowButton(.zoomButton)?.isEnabled = false
        buttons.forEach { $0.alphaValue = 0 }
        model.showChrome = { visible in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                buttons.forEach { $0.animator().alphaValue = visible ? 1 : 0 }
            }
        }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 380, height: 300)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.onKeyEquivalent = { [weak model] event in model?.handle(event) ?? false }
        panel.onEscape = { [weak model] in model?.escape() }

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        let host = NSHostingView(rootView: NotesPanelView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor), host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor), host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        self.panel = panel
        self.model = model
        return panel
    }

    /// The close button hides the window (it's reused, never destroyed).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    /// First time: centred a little above the middle of the screen with the pointer.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2 + area.height * 0.08))
    }
}
