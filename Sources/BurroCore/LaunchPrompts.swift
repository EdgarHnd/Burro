// The New chat sheet's prompt memory, kept only in this Mac's preferences (`launch.prompts`).
// Recent prompts: the last prompts the owner started from the sheet, per project (the same project
// key as LaunchDefaults, so this Mac and another machine's folder are separate), newest first, at
// most 20 per project and 20 projects; starting the same prompt again moves it to the front. A row
// shows the prompt's first line; clicking it puts the whole prompt back. Templates: three built-in
// prompts plus up to 40 of the owner's own, saved from the current prompt ("Save as template",
// titled by its first line) and deleted from their row; built-ins can't be deleted. Prompts are
// kept whole: one longer than 20,000 characters is neither remembered nor saved as a template (a
// shortened prompt is never offered for reuse). The saved value is kept at or under 1 MB as
// encoded: past it the oldest recent prompts are forgotten whole (never a template, never the one
// just started unless it alone doesn't fit); a template that wouldn't fit even with every recent
// prompt gone isn't saved (and "Save as template" is off for it). A stored value over 2 MB is
// ignored on read. Nothing here starts a chat or leaves this Mac.
import Foundation

public struct LaunchTemplate: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var prompt: String
    /// The row's icon (an SF Symbol name).
    public var symbol: String
    public var builtIn: Bool
    public init(id: String, title: String, prompt: String, symbol: String = "bookmark", builtIn: Bool = false) {
        self.id = id; self.title = title; self.prompt = prompt; self.symbol = symbol; self.builtIn = builtIn
    }

    public static let builtIns: [LaunchTemplate] = [
        LaunchTemplate(id: "builtin.ci", title: "Fix the failing CI run",
                       prompt: "The latest CI run for this branch is failing. Find the failing job, work out why, fix the cause rather than the test, and run the relevant checks locally before you finish.",
                       symbol: "arrow.down.to.line", builtIn: true),
        LaunchTemplate(id: "builtin.review", title: "Review this pull request",
                       prompt: "Review the changes on this branch against its base. Look for correctness bugs first, then missing tests and risky edge cases. Don't change any code: list the findings by severity, each with its file and line.",
                       symbol: "arrow.triangle.pull", builtIn: true),
        LaunchTemplate(id: "builtin.release", title: "Write release notes",
                       prompt: "Write release notes for the changes since the last release tag: short, user-facing bullets grouped under New, Improved and Fixed. Leave out internal refactors and test-only changes.",
                       symbol: "doc.text", builtIn: true),
    ]
}

public struct LaunchPromptMemory: Equatable, Sendable, Codable {
    public static let preferencesKey = "launch.prompts"
    public static let recentLimit = 20
    public static let projectLimit = 20
    public static let templateLimit = 40
    /// Longer prompts aren't remembered at all (never kept shortened).
    public static let storedPromptLimit = 20_000
    /// The saved value's encoded size; past it the oldest recent prompts are forgotten, whole.
    public static let encodedLimit = 1_048_576
    /// A stored value larger than this is ignored on read.
    public static let decodeLimit = 2 * 1_048_576

    /// Project key (`LaunchDefaults.key(_:machine:)`) → prompts, newest first.
    public var recent: [String: [String]] = [:]
    /// Project keys, most recently used first (to forget the oldest project's prompts).
    public var recentProjects: [String] = []
    /// The owner's own templates, oldest first.
    public var saved: [LaunchTemplate] = []

    public init() {}

    /// The prompt as remembered, or "" when it is empty or too long to keep whole.
    static func stored(_ prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > storedPromptLimit ? "" : trimmed
    }

    /// The first non-empty line, shortened for a chip.
    public static func firstLine(_ prompt: String, limit: Int = 80) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > limit ? String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    /// Remembers a prompt the owner started in `folder` on `machine` (nil: this Mac).
    public mutating func recordStart(_ prompt: String, folder: String, machine: UUID? = nil) {
        let key = LaunchDefaults.key(folder, machine: machine)
        let text = Self.stored(prompt)
        guard !key.isEmpty, !text.isEmpty else { return }
        var list = recent[key] ?? []
        list.removeAll { $0 == text }
        list.insert(text, at: 0)
        if list.count > Self.recentLimit { list.removeLast(list.count - Self.recentLimit) }
        recent[key] = list
        recentProjects.removeAll { $0 == key }
        recentProjects.insert(key, at: 0)
        if recentProjects.count > Self.projectLimit { recentProjects.removeLast(recentProjects.count - Self.projectLimit) }
        let kept = Set(recentProjects)
        recent = recent.filter { kept.contains($0.key) }
        fit(keeping: (key, text))
    }

    /// The encoded size of what would be saved.
    public var encodedSize: Int { encoded()?.count ?? Int.max }

    /// Drops the oldest recent prompts (least recently used projects first, oldest prompt first)
    /// until the encoded value is at or under `encodedLimit`; `keeping` (the prompt just started)
    /// goes last, only when it alone doesn't fit. Templates are never dropped.
    mutating func fit(keeping: (key: String, text: String)? = nil) {
        var size = encodedSize
        guard size > Self.encodedLimit else { return }
        // Each prompt's share of the JSON (escaped string and its comma), so the loop doesn't re-encode.
        func cost(_ text: String) -> Int { ((try? JSONEncoder().encode(text))?.count ?? text.utf8.count) + 1 }
        func dropOldest(sparing: Bool) -> Bool {
            for project in recentProjects.reversed() {
                guard var prompts = recent[project], let last = prompts.last else { continue }
                if sparing, let keeping, project == keeping.key, prompts.count == 1, last == keeping.text { continue }
                prompts.removeLast()
                size -= cost(last)
                recent[project] = prompts.isEmpty ? nil : prompts
                if prompts.isEmpty { recentProjects.removeAll { $0 == project } }
                return true
            }
            return false
        }
        while size > Self.encodedLimit {
            if dropOldest(sparing: true) || dropOldest(sparing: false) {
                if size <= Self.encodedLimit { size = encodedSize }  // confirm with the real encoding
            } else { break }
        }
        recentProjects.removeAll { recent[$0] == nil }
    }

    /// A project's recent prompts, newest first.
    public func recentPrompts(folder: String, machine: UUID? = nil) -> [String] {
        recent[LaunchDefaults.key(folder, machine: machine)] ?? []
    }

    /// Built-ins first, then the owner's own.
    public var templates: [LaunchTemplate] { LaunchTemplate.builtIns + saved }

    /// Whether "Save as template" makes sense for this prompt: not empty and not already a template.
    public func canSave(_ prompt: String) -> Bool {
        let text = Self.stored(prompt)
        guard !text.isEmpty, !templates.contains(where: { $0.prompt == text }) else { return false }
        // It must fit with the owner's templates even if every recent prompt were forgotten.
        var templatesOnly = LaunchPromptMemory()
        templatesOnly.saved = saved + [LaunchTemplate(id: UUID().uuidString, title: Self.firstLine(text, limit: 48), prompt: text)]
        if templatesOnly.saved.count > Self.templateLimit { templatesOnly.saved.removeFirst(templatesOnly.saved.count - Self.templateLimit) }
        return templatesOnly.encodedSize <= Self.encodedLimit
    }

    /// Saves the prompt as the owner's template, titled by its first line. Returns it, or nil when it can't be saved.
    @discardableResult
    public mutating func saveTemplate(_ prompt: String, id: String = UUID().uuidString) -> LaunchTemplate? {
        guard canSave(prompt) else { return nil }
        let text = Self.stored(prompt)
        let template = LaunchTemplate(id: id, title: Self.firstLine(text, limit: 48), prompt: text)
        saved.append(template)
        if saved.count > Self.templateLimit { saved.removeFirst(saved.count - Self.templateLimit) }
        fit()
        return template
    }

    /// Deletes one of the owner's templates; built-ins stay.
    public mutating func deleteTemplate(_ id: String) {
        saved.removeAll { $0.id == id }
    }

    /// Tolerant read: a damaged or oversized value is ignored.
    public static func decode(_ data: Data?) -> LaunchPromptMemory? {
        guard let data, data.count <= decodeLimit else { return nil }
        return try? JSONDecoder().decode(LaunchPromptMemory.self, from: data)
    }
    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}
