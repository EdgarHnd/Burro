// Check note text rules (checklists, titles, export), the notes store behind the Notes window,
// and the window's navigation and shortcuts.
import XCTest
import AppKit
@testable import Burro

@MainActor final class NotesPanelTests: XCTestCase {
    private func store() -> NotesStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-notes-test-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return NotesStore(folder: folder)
    }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "burro-notes-\(UUID().uuidString)")! }

    func testLineKinds() {
        XCTAssertEqual(NoteText.kind(of: "- [ ] milk").kind, .checklist(done: false))
        XCTAssertEqual(NoteText.kind(of: "- [x] milk").kind, .checklist(done: true))
        XCTAssertEqual(NoteText.kind(of: "- [X] milk").prefix, 6)
        XCTAssertEqual(NoteText.kind(of: "- milk").kind, .bullet)
        XCTAssertEqual(NoteText.kind(of: "## Plan").kind, .heading(2))
        XCTAssertEqual(NoteText.kind(of: "-milk").kind, .text)
        XCTAssertEqual(NoteText.kind(of: "#hashtag").kind, .text)
    }

    func testTitlesCountsAndExports() {
        let text = "\n- [ ] here i can write\n- [x] recover our gmail\nplain line"
        XCTAssertEqual(NoteText.title(text), "here i can write")
        XCTAssertEqual(NoteText.title("   \n"), "New Note")
        XCTAssertEqual(NoteText.visibleCount("- [ ] ab\ncd"), 5, "Marks don't count; letters and line breaks do")
        XCTAssertEqual(NoteText.plain(text), "\n☐ here i can write\n☑ recover our gmail\nplain line")
        XCTAssertEqual(NoteText.plain("# Title\n- bullet"), "Title\n• bullet")
        XCTAssertEqual(NoteText.openItems(text), ["here i can write"])
        XCTAssertEqual(NoteText.rest("first\nsecond\nthird"), "second\nthird")
    }

    func testToggleChecklistAddsRemovesAndConvertsBullets() {
        let (added, selection) = NoteText.toggleChecklist("one\ntwo", selection: NSRange(location: 0, length: 7))
        XCTAssertEqual(added, "- [ ] one\n- [ ] two")
        XCTAssertEqual(selection.location, 6)
        let (removed, _) = NoteText.toggleChecklist(added, selection: NSRange(location: 0, length: (added as NSString).length))
        XCTAssertEqual(removed, "one\ntwo")
        XCTAssertEqual(NoteText.toggleChecklist("- bullet", selection: NSRange(location: 4, length: 0)).0, "- [ ] bullet")
        XCTAssertEqual(NoteText.toggleChecklist("a\n- [x] done\nb", selection: NSRange(location: 0, length: 14)).0, "- [ ] a\n- [x] done\n- [ ] b",
                       "Mixed lines all become items; existing ones keep their state")
        XCTAssertEqual(NoteText.toggleChecklist("", selection: NSRange(location: 0, length: 0)).0, "- [ ] ")
    }

    func testStoreKeepsEmptyNotesOffDiskAndOrdersPinnedFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-notes-test-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let notes = NotesStore(folder: folder)
        let empty = notes.create()
        let first = notes.create(text: "Groceries\n- [ ] milk")
        let second = notes.create(text: "Ideas")
        notes.setText(empty.id, "")
        notes.togglePin(first.id)
        notes.markOpened(second.id)
        notes.flush()
        XCTAssertEqual(notes.browseOrder.first?.id, first.id, "Pinned first")
        let reloaded = NotesStore(folder: folder)
        XCTAssertEqual(Set(reloaded.notes.map(\.id)), [first.id, second.id], "Empty notes aren't written")
        XCTAssertEqual(reloaded.note(first.id)?.title, "Groceries")
        XCTAssertEqual(reloaded.note(first.id)?.body, "- [ ] milk")
        XCTAssertTrue(reloaded.note(first.id)?.isPinned == true)
        notes.removeIfEmpty(empty.id)
        XCTAssertNil(notes.note(empty.id))
        XCTAssertEqual(notes.duplicate(first.id)?.content, "Groceries\n- [ ] milk")
    }

    func testOlderNotesStillOpen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-notes-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let legacy = #"[{"id":"11111111-2222-4333-8444-555555555555","title":"Old","body":"line","updatedAt":700000000}]"#
        try legacy.write(to: folder.appendingPathComponent("notes.json"), atomically: true, encoding: .utf8)
        let notes = NotesStore(folder: folder)
        XCTAssertEqual(notes.notes.first?.content, "Old\nline")
    }

    func testOpeningNavigatingAndDeleting() {
        let notes = store()
        let model = NotesPanelModel(notes: notes, defaults: defaults())
        model.open(.last)
        let blank = model.currentID
        XCTAssertNotNil(blank, "With no notes, ⌥P opens a new one")
        model.newNote()
        XCTAssertEqual(model.currentID, blank, "No pile of empty notes")
        model.setText("First note")
        model.newNote()
        let second = model.currentID
        model.setText("Second note")
        model.goBack()
        XCTAssertEqual(model.currentID, blank)
        model.goForward()
        XCTAssertEqual(model.currentID, second)
        model.delete()
        XCTAssertEqual(model.currentID, blank, "Deleting opens the next note")
        XCTAssertEqual(model.browseResults.map(\.id), [blank!])
        model.query = "nothing"
        XCTAssertTrue(model.browseResults.isEmpty)
    }

    func testOpenLastRemembersTheNote() {
        let notes = store(), defaults = defaults()
        let a = notes.create(text: "A"), b = notes.create(text: "B")
        let first = NotesPanelModel(notes: notes, defaults: defaults)
        first.open(.note(a.id))
        first.open(.note(b.id))
        let again = NotesPanelModel(notes: notes, defaults: defaults)
        again.open(.last)
        XCTAssertEqual(again.currentID, b.id)
    }

    func testEditorListEditing() {
        let editor = NoteEditor(noteID: nil, text: "", onChange: { _ in }, onEscape: {}, register: { _ in })
        let coordinator = editor.makeCoordinator()
        let storage = NSTextStorage()
        let layout = ChecklistLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: 1000))
        layout.addTextContainer(container)
        let view = NoteTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        view.delegate = coordinator
        storage.delegate = coordinator
        let newline = #selector(NSResponder.insertNewline(_:)), backspace = #selector(NSResponder.deleteBackward(_:))

        view.string = "- [ ] milk"
        view.setSelectedRange(NSRange(location: 10, length: 0))
        XCTAssertTrue(coordinator.textView(view, doCommandBy: newline))
        XCTAssertEqual(view.string, "- [ ] milk\n- [ ] ", "Return continues the checklist")
        XCTAssertTrue(coordinator.textView(view, doCommandBy: newline))
        XCTAssertEqual(view.string, "- [ ] milk\n", "Return on an empty item ends it")
        view.string = "plain"
        view.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertFalse(coordinator.textView(view, doCommandBy: newline), "Plain lines get a normal line break")

        view.string = "- [ ] eggs"
        view.setSelectedRange(NSRange(location: 6, length: 0))
        XCTAssertTrue(coordinator.textView(view, doCommandBy: backspace))
        XCTAssertEqual(view.string, "eggs", "⌫ right after the box removes it")

        view.string = "a\n- [ ] eggs"
        XCTAssertEqual(coordinator.textView(view, willChangeSelectionFromCharacterRange: NSRange(location: 12, length: 0),
                                            toCharacterRange: NSRange(location: 3, length: 0)), NSRange(location: 8, length: 0),
                       "The caret never lands inside a hidden mark")
        XCTAssertEqual(coordinator.textView(view, willChangeSelectionFromCharacterRange: NSRange(location: 8, length: 0),
                                            toCharacterRange: NSRange(location: 7, length: 0)), NSRange(location: 1, length: 0),
                       "← from the item's start goes to the line above")

        view.toggleCheckbox(NoteText.paragraph(in: view.string as NSString, at: 5))
        XCTAssertEqual(view.string, "a\n- [x] eggs")
        XCTAssertEqual((storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)?.pointSize, 1, "The mark is drawn as a box, not text")
        XCTAssertNotNil(storage.attribute(.strikethroughStyle, at: 9, effectiveRange: nil), "Done items are struck through")

        view.setSelectedRange(NSRange(location: 0, length: 1))
        view.toggleChecklist()
        XCTAssertEqual(view.string, "- [ ] a\n- [x] eggs")
        view.undoManager?.undo()
    }

    func testShortcuts() {
        let notes = store()
        let model = NotesPanelModel(notes: notes, defaults: defaults())
        model.open(.last)
        model.setText("Plan\n- [ ] ship")
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
        }
        XCTAssertTrue(model.handle(key("p", .command)))
        XCTAssertEqual(model.overlay, .browse)
        XCTAssertTrue(model.handle(key("k", .command)))
        XCTAssertEqual(model.overlay, .actions)
        XCTAssertTrue(model.handle(key("P", [.command, .shift])))
        XCTAssertTrue(model.current?.isPinned == true)
        var hidden = false
        model.hide = { hidden = true }
        XCTAssertTrue(model.handle(key("q", .command)), "⌘Q closes the window instead of quitting Burro")
        XCTAssertTrue(hidden)
        XCTAssertFalse(model.handle(key("b", .command)))
        var added: [String] = []
        model.addTodos = { added = $0 }
        model.addOpenItemsToTodos()
        XCTAssertEqual(added, ["ship"])
        model.overlay = .actions
        model.query = "dupl"
        XCTAssertEqual(model.actions.map(\.title), ["Duplicate Note"])
    }
}
