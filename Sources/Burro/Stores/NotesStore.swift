// Notes and the scratchpad on Home. Stored on this Mac in Burro's Application Support folder
// (notes.json, scratchpad.txt); the scratchpad saves a moment after you stop typing.
import Foundation
import Observation

struct HomeNote: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var body: String
    var updatedAt: Date
}

@MainActor @Observable final class NotesStore {
    private(set) var notes: [HomeNote] = []
    var scratchpad: String = "" { didSet { if scratchpad != oldValue { scheduleScratchSave() } } }
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private var scratchSave: Task<Void, Never>?

    init(folder: URL = NotesStore.defaultFolder) {
        self.folder = folder
        if let data = try? Data(contentsOf: folder.appendingPathComponent("notes.json")),
           let decoded = try? JSONDecoder().decode([HomeNote].self, from: data) { notes = decoded }
        scratchpad = (try? String(contentsOf: folder.appendingPathComponent("scratchpad.txt"), encoding: .utf8)) ?? ""
    }
    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Burro")
    }

    var sorted: [HomeNote] { notes.sorted { $0.updatedAt > $1.updatedAt } }

    func save(_ note: HomeNote) {
        var note = note
        note.title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.title.isEmpty || !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { remove(note); return }
        if note.title.isEmpty { note.title = String(note.body.split(whereSeparator: \.isNewline).first ?? "Untitled").prefix(80).description }
        note.updatedAt = Date()
        if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index] = note } else { notes.append(note) }
        persist()
    }
    func remove(_ note: HomeNote) { notes.removeAll { $0.id == note.id }; persist() }

    private func persist() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(notes) { try? data.write(to: folder.appendingPathComponent("notes.json"), options: .atomic) }
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
