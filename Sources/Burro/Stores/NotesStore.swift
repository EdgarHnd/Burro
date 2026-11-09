// Notes and the scratchpad. Notes are edited in the floating Notes window (⌥P) and listed on
// Home; both are stored on this Mac in Burro's Application Support folder (notes.json,
// scratchpad.txt). Typing saves a moment after you stop.
import Foundation
import Observation

struct HomeNote: Identifiable, Codable, Equatable {
    var id: UUID
    /// The first line, for lists (derived from `text` when there is one).
    var title: String
    /// The rest, for one-line previews.
    var body: String
    var updatedAt: Date
    /// The whole note as typed (checklists as `- [ ] `). Older notes only have title and body.
    var text: String? = nil
    var pinned: Bool? = nil
    var openedAt: Date? = nil
    var createdAt: Date? = nil

    var content: String { text ?? (body.isEmpty ? title : title + "\n" + body) }
    var isEmpty: Bool { content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isPinned: Bool { pinned == true }
}

@MainActor @Observable final class NotesStore {
    private(set) var notes: [HomeNote] = []
    var scratchpad: String = "" { didSet { if scratchpad != oldValue { scheduleScratchSave() } } }
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private var scratchSave: Task<Void, Never>?
    @ObservationIgnored private var notesSave: Task<Void, Never>?

    init(folder: URL = NotesStore.defaultFolder) {
        self.folder = folder
        if let data = try? Data(contentsOf: folder.appendingPathComponent("notes.json")),
           let decoded = try? JSONDecoder().decode([HomeNote].self, from: data) { notes = decoded }
        scratchpad = (try? String(contentsOf: folder.appendingPathComponent("scratchpad.txt"), encoding: .utf8)) ?? ""
    }
    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Burro")
    }

    /// Notes with something in them, newest edit first (Home).
    var sorted: [HomeNote] { notes.filter { !$0.isEmpty }.sorted { $0.updatedAt > $1.updatedAt } }
    /// Browse order: pinned first, then most recently opened.
    var browseOrder: [HomeNote] {
        notes.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return (a.openedAt ?? a.updatedAt) > (b.openedAt ?? b.updatedAt)
        }
    }

    func note(_ id: UUID) -> HomeNote? { notes.first { $0.id == id } }

    /// A new empty note; it is only written to disk once it has text.
    @discardableResult func create(text: String = "") -> HomeNote {
        let now = Date()
        let note = HomeNote(id: UUID(), title: NoteText.title(text), body: NoteText.rest(text), updatedAt: now,
                            text: text, openedAt: now, createdAt: now)
        notes.append(note)
        if !note.isEmpty { schedulePersist() }
        return note
    }
    /// Typing: updates the note now, writes it shortly after.
    func setText(_ id: UUID, _ text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].content != text else { return }
        notes[index].text = text
        notes[index].title = NoteText.title(text)
        notes[index].body = NoteText.rest(text)
        notes[index].updatedAt = Date()
        schedulePersist()
    }
    func markOpened(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].openedAt = Date()
        schedulePersist()
    }
    func togglePin(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].pinned = notes[index].isPinned ? nil : true
        schedulePersist()
    }
    @discardableResult func duplicate(_ id: UUID) -> HomeNote? {
        guard let note = note(id) else { return nil }
        return create(text: note.content)
    }
    func remove(_ id: UUID) { notes.removeAll { $0.id == id }; schedulePersist(now: true) }
    /// Drops a note you opened but never wrote in.
    func removeIfEmpty(_ id: UUID) {
        guard note(id)?.isEmpty == true else { return }
        notes.removeAll { $0.id == id }
    }

    /// Writes pending changes now (quitting, hiding the window).
    func flush() { schedulePersist(now: true) }

    private func schedulePersist(now: Bool = false) {
        notesSave?.cancel()
        let snapshot = notes.filter { !$0.isEmpty }, url = folder.appendingPathComponent("notes.json"), folder = folder
        let write = {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        if now { write(); return }
        notesSave = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            write()
        }
    }
    private func scheduleScratchSave() {
        scratchSave?.cancel()
        let text = scratchpad, url = folder.appendingPathComponent("scratchpad.txt"), folder = folder
        scratchSave = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
