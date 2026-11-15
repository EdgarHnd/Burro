// What the New chat sheet fills in before you type. Each project remembers the provider, the model
// and effort used with each provider there, and the access of its last launch; a project without a
// memory falls back to the provider's last values, then to the built-in defaults (Codex, its
// default model, ask before acting; Claude on Opus 5.5). An effort the chosen model doesn't support
// is dropped, and a model no longer offered falls back to the provider's default. A project is a
// folder on one machine: the same path on this Mac and on another machine are two projects, each
// with its own memory, and each machine remembers its own recent projects; the machine of the last
// launch is remembered too. The sheet's form (`LaunchForm`) holds the prompt, the machine (nil =
// this Mac), the folder on it and those choices; switching machine brings back that machine's last
// project. Stored as one small JSON value in preferences; nothing here starts a chat.
import Foundation

/// Provider, model, effort and access for one launch. An empty model or effort means "the default".
public struct LaunchChoice: Equatable, Sendable {
    public var provider: LaunchProvider
    public var model: String
    public var effort: String
    public var access: LaunchAccess
    public init(provider: LaunchProvider, model: String = "", effort: String = "", access: LaunchAccess = .ask) {
        self.provider = provider; self.model = model; self.effort = effort; self.access = access
    }
    /// The built-in default for a provider.
    public static func builtIn(_ provider: LaunchProvider) -> LaunchChoice {
        LaunchChoice(provider: provider, model: provider == .claude ? "claude-opus-5-5" : "", effort: "", access: .ask)
    }
    public init(_ request: LaunchRequest) {
        self.init(provider: request.provider, model: request.model ?? "", effort: request.effort ?? "", access: request.access)
    }

    /// The model entry this choice points at: the named one, or the provider's default when the model is empty.
    public func selectedModel(in models: [LaunchModel]) -> LaunchModel? {
        model.isEmpty ? models.first(where: \.isDefault) : models.first { $0.id == model }
    }

    /// Drops a model the list no longer offers and an effort the model doesn't support. An empty
    /// list (Codex models not loaded yet) leaves the model alone.
    public func validated(models: [LaunchModel]) -> LaunchChoice {
        var choice = self
        if !models.isEmpty, !choice.model.isEmpty, !models.contains(where: { $0.id == choice.model }) {
            choice.model = provider == .claude ? (models.first(where: \.isDefault)?.id ?? "") : ""
        }
        if !choice.effort.isEmpty, let selected = choice.selectedModel(in: models), !selected.efforts.isEmpty,
           !selected.efforts.contains(choice.effort) {
            choice.effort = ""
        }
        return choice
    }
}

public struct LaunchDefaults: Equatable, Sendable, Codable {
    /// Model and effort last used with one provider ("" = default).
    public struct ModelChoice: Equatable, Sendable, Codable {
        public var model: String
        public var effort: String
        public init(model: String, effort: String) { self.model = model; self.effort = effort }
    }
    /// One project's memory.
    public struct Project: Equatable, Sendable, Codable {
        public var provider: String
        public var access: String
        /// Keyed by provider raw value, so switching provider in a project gets that provider's last model back.
        public var models: [String: ModelChoice]
        public init(provider: String, access: String, models: [String: ModelChoice]) {
            self.provider = provider; self.access = access; self.models = models
        }
    }
    /// A provider's last values, used where a project has none.
    public struct Provider: Equatable, Sendable, Codable {
        public var model: String
        public var effort: String
        public var access: String
        public init(model: String, effort: String, access: String) { self.model = model; self.effort = effort; self.access = access }
    }

    public static let preferencesKey = "launch.defaults"
    /// Most recently launched projects kept; older memories are forgotten.
    public static let projectLimit = 60

    public var projects: [String: Project] = [:]
    public var providers: [String: Provider] = [:]
    public var lastProvider: String?
    /// Project keys (`key(_:machine:)`), most recent launch first: plain paths for this Mac,
    /// "remote:<host id>:<path>" for another machine.
    public var recentProjects: [String] = []
    /// The machine of the last launch (a host id), nil for this Mac.
    public var lastMachine: String?

    public init() {}

    /// A folder path in the one form used as a key: standardised, without a trailing slash.
    public static func key(_ folder: String) -> String {
        guard !folder.isEmpty else { return "" }
        let path = URL(fileURLWithPath: folder).standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    static let remotePrefix = "remote:"
    /// A project's key: the folder's key on this Mac, or "remote:<host id>:<folder>" on another machine.
    public static func key(_ folder: String, machine: UUID?) -> String {
        guard let machine else { return key(folder) }
        let path = key(folder)
        return path.isEmpty ? "" : "\(remotePrefix)\(machine.uuidString):\(path)"
    }
    /// The folder of another machine's project key, or nil for this Mac's keys and other machines.
    static func remotePath(_ key: String, machine: UUID) -> String? {
        let prefix = "\(remotePrefix)\(machine.uuidString):"
        return key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
    }
    static func isLocal(_ key: String) -> Bool { !key.hasPrefix(remotePrefix) }

    /// The machine the last launch ran on (nil: this Mac).
    public var lastMachineID: UUID? { lastMachine.flatMap(UUID.init(uuidString:)) }

    /// What the sheet starts with in `folder`. `parent` is a second project to borrow from (a
    /// worktree's repository); `provider` forces a provider (the chip was switched).
    public func choice(for folder: String, machine: UUID? = nil, parent: String? = nil, provider forced: LaunchProvider? = nil,
                       models: (LaunchProvider) -> [LaunchModel]) -> LaunchChoice {
        // A worktree's repository is a this-Mac idea; another machine's folders stand alone.
        let memory = projects[Self.key(folder, machine: machine)] ?? (machine == nil ? parent.flatMap { projects[Self.key($0)] } : nil)
        let provider = forced ?? memory.flatMap { LaunchProvider(rawValue: $0.provider) }
            ?? lastProvider.flatMap(LaunchProvider.init(rawValue:)) ?? .codex
        let fallback = providers[provider.rawValue]
        let builtIn = LaunchChoice.builtIn(provider)
        let pair = memory?.models[provider.rawValue] ?? fallback.map { ModelChoice(model: $0.model, effort: $0.effort) }
            ?? ModelChoice(model: builtIn.model, effort: builtIn.effort)
        // A project's access belongs to its last launch; switching provider keeps it.
        let access = memory.flatMap { LaunchAccess(rawValue: $0.access) } ?? fallback.flatMap { LaunchAccess(rawValue: $0.access) } ?? builtIn.access
        return LaunchChoice(provider: provider, model: pair.model, effort: pair.effort, access: access).validated(models: models(provider))
    }

    /// Remembers a launch the owner started from the sheet, on this Mac (`machine` nil) or another machine.
    public mutating func record(_ request: LaunchRequest, machine: UUID? = nil) {
        let key = Self.key(request.folder, machine: machine)
        let choice = LaunchChoice(request)
        let pair = ModelChoice(model: choice.model, effort: choice.effort)
        var project = projects[key] ?? Project(provider: choice.provider.rawValue, access: choice.access.rawValue, models: [:])
        project.provider = choice.provider.rawValue
        project.access = choice.access.rawValue
        project.models[choice.provider.rawValue] = pair
        if !key.isEmpty { projects[key] = project }
        providers[choice.provider.rawValue] = Provider(model: choice.model, effort: choice.effort, access: choice.access.rawValue)
        lastProvider = choice.provider.rawValue
        lastMachine = machine?.uuidString
        if !key.isEmpty {
            recentProjects.removeAll { $0 == key }
            recentProjects.insert(key, at: 0)
        }
        if recentProjects.count > Self.projectLimit { recentProjects.removeLast(recentProjects.count - Self.projectLimit) }
        let kept = Set(recentProjects)
        projects = projects.filter { kept.contains($0.key) }
    }

    /// Projects for the sheet's project chip: recent launches first (those still on disk), then the
    /// rest of `known` in its own order. Recent folders Burro doesn't list (a worktree, a folder you
    /// chose) keep their folder name.
    public func orderedProjects(known: [(path: String, name: String)], exists: (String) -> Bool) -> [(path: String, name: String)] {
        let byKey = Dictionary(known.map { (Self.key($0.path), $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var result: [(path: String, name: String)] = []
        for path in recentProjects where Self.isLocal(path) && !seen.contains(path) {
            if let entry = byKey[path] { result.append(entry) } else if exists(path) {
                result.append((path: path, name: URL(fileURLWithPath: path).lastPathComponent))
            } else { continue }
            seen.insert(path)
        }
        for entry in known where seen.insert(Self.key(entry.path)).inserted { result.append(entry) }
        return result
    }

    /// The project to use when nothing else names one: the last launch still on disk.
    public func lastProject(exists: (String) -> Bool) -> String? { recentProjects.first { Self.isLocal($0) && exists($0) } }

    /// Another machine's last project (its folder path), if it has one.
    public func lastProject(machine: UUID) -> String? { recentProjects.lazy.compactMap { Self.remotePath($0, machine: machine) }.first }

    /// Another machine's folders for the project chip: the ones launched in recently first (most
    /// recent first), then the rest in the listing's order. Folders that no longer exist are left out.
    public func orderedFolders(machine: UUID, folders: [RemoteFolder]) -> [RemoteFolder] {
        let present = folders.filter(\.exists)
        let byKey = Dictionary(present.map { (Self.key($0.path), $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var result: [RemoteFolder] = []
        for path in recentProjects.compactMap({ Self.remotePath($0, machine: machine) }) {
            if let folder = byKey[path], seen.insert(path).inserted { result.append(folder) }
        }
        for folder in present where seen.insert(Self.key(folder.path)).inserted { result.append(folder) }
        return result
    }

    /// Seeds the memory from the launcher's older per-provider preferences (read once, when no
    /// `launch.defaults` value exists yet).
    public static func migrating(legacy value: (String) -> Any?) -> LaunchDefaults {
        var defaults = LaunchDefaults()
        let access = (value("launch.access") as? String).flatMap(LaunchAccess.init(rawValue:)) ?? .ask
        let codexModel = value("launch.model.codex") as? String, claudeModel = value("launch.model.claude") as? String
        if codexModel != nil || value("launch.effort.codex") != nil || value("launch.access") != nil {
            defaults.providers[LaunchProvider.codex.rawValue] = Provider(model: codexModel ?? "", effort: value("launch.effort.codex") as? String ?? "",
                                                                          access: access.rawValue)
        }
        if claudeModel != nil || value("launch.effort.claude") != nil || value("launch.access") != nil {
            defaults.providers[LaunchProvider.claude.rawValue] = Provider(model: claudeModel ?? LaunchChoice.builtIn(.claude).model,
                                                                           effort: value("launch.effort.claude") as? String ?? "", access: access.rawValue)
        }
        defaults.lastProvider = (value("launch.provider") as? String).flatMap(LaunchProvider.init(rawValue:))?.rawValue
        if let folder = value("launch.folder") as? String, !folder.isEmpty { defaults.recentProjects = [key(folder)] }
        return defaults
    }

    /// Tolerant read: a damaged or oversized value is ignored.
    public static func decode(_ data: Data?) -> LaunchDefaults? {
        guard let data, data.count <= 256 * 1024 else { return nil }
        return try? JSONDecoder().decode(LaunchDefaults.self, from: data)
    }
    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

/// What opens the sheet prefilled: a prompt, a folder, and for Retry the exact earlier choices.
public struct LaunchDraft: Equatable, Sendable {
    public var prompt: String
    public var folder: String?
    public var choice: LaunchChoice?
    /// The machine to start on: nil for this Mac (or, for a plain ⌘N, the last launch's machine).
    public var machine: UUID?
    public init(prompt: String = "", folder: String? = nil, choice: LaunchChoice? = nil, machine: UUID? = nil) {
        self.prompt = prompt; self.folder = folder; self.choice = choice; self.machine = machine
    }
    /// The same launch again, as it was asked for, on the same machine.
    public init(retrying request: LaunchRequest, machine: UUID? = nil) {
        self.init(prompt: request.prompt, folder: request.folder, choice: LaunchChoice(request), machine: machine)
    }

    /// The machine the sheet opens on. A draft that names a machine or a folder keeps its own (a
    /// folder without a machine is on this Mac); a plain draft (⌘N) opens on the last launch's
    /// machine while it can be used, else this Mac.
    public func machine(lastMachine: UUID?, usable: (UUID) -> Bool) -> UUID? {
        if let machine { return machine }
        guard folder == nil, choice == nil, let lastMachine, usable(lastMachine) else { return nil }
        return lastMachine
    }

    /// The longest prompt a to-do, note or palette text pre-fills.
    public static let promptLimit = 8_000
    public static func prompt(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > promptLimit ? String(trimmed.prefix(promptLimit)) : trimmed
    }

    /// A to-do's project as a launch folder: an absolute path that exists, else a known project with
    /// that name (case-insensitive), else nil.
    public static func folder(forProject project: String?, among known: [(path: String, name: String)],
                              exists: (String) -> Bool) -> String? {
        guard let project = project?.trimmingCharacters(in: .whitespacesAndNewlines), !project.isEmpty else { return nil }
        if project.hasPrefix("/") || project.hasPrefix("~") {
            let path = LaunchDefaults.key((project as NSString).expandingTildeInPath)
            return exists(path) ? path : nil
        }
        return known.first { $0.name.compare(project, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }?.path
    }
}

/// The New chat sheet's state: prompt, machine, folder on that machine and choices.
public struct LaunchForm: Equatable, Sendable {
    public var prompt: String
    public var folder: String
    public var choice: LaunchChoice
    /// The machine to start on: nil is this Mac, else a remote host's id.
    public var machine: UUID?

    public init(prompt: String = "", folder: String = "", choice: LaunchChoice = .builtIn(.codex), machine: UUID? = nil) {
        self.prompt = prompt; self.folder = folder; self.choice = choice; self.machine = machine
    }

    /// The form a draft opens: the draft's own choices when it has them (Retry), else the folder's
    /// memory. On another machine (`machine`, usually `draft.machine(…)`) without a folder, that
    /// machine's last project; `fallbackFolder` is for this Mac only.
    public init(draft: LaunchDraft, machine: UUID? = nil, fallbackFolder: String, defaults: LaunchDefaults,
                parent: (String) -> String? = { _ in nil }, models: (LaunchProvider) -> [LaunchModel]) {
        let folder = draft.folder.map(LaunchDefaults.key)
            ?? (machine.map { defaults.lastProject(machine: $0) ?? "" } ?? fallbackFolder)
        let choice = draft.choice.map { $0.validated(models: models($0.provider)) }
            ?? defaults.choice(for: folder, machine: machine, parent: machine == nil ? parent(folder) : nil, models: models)
        self.init(prompt: draft.prompt, folder: folder, choice: choice, machine: machine)
    }

    /// A prompt and a folder; on another machine the folder must be an absolute path there.
    public var canStart: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !folder.isEmpty && (machine == nil || folder.hasPrefix("/"))
    }

    public var request: LaunchRequest {
        LaunchRequest(provider: choice.provider, prompt: prompt, folder: folder,
                      model: choice.model.isEmpty ? nil : choice.model, effort: choice.effort.isEmpty ? nil : choice.effort,
                      access: choice.access)
    }

    /// Another project: its own memory replaces the choices; the prompt stays.
    public mutating func selectProject(_ path: String, defaults: LaunchDefaults, parent: String? = nil,
                                       models: (LaunchProvider) -> [LaunchModel]) {
        folder = LaunchDefaults.key(path)
        choice = defaults.choice(for: folder, machine: machine, parent: machine == nil ? parent : nil, models: models)
    }
    /// Another machine: that machine's last project (this Mac: `localFolder`, the sheet's usual
    /// fallback) with its memory; the prompt stays. A machine without a last project has no folder yet.
    public mutating func selectMachine(_ id: UUID?, defaults: LaunchDefaults, localFolder: String, parent: (String) -> String? = { _ in nil },
                                       models: (LaunchProvider) -> [LaunchModel]) {
        guard id != machine else { return }
        machine = id
        folder = id.map { defaults.lastProject(machine: $0) ?? "" } ?? LaunchDefaults.key(localFolder)
        choice = defaults.choice(for: folder, machine: id, parent: id == nil ? parent(folder) : nil, models: models)
    }
    /// Another provider: the model and effort last used with it in this project (or anywhere), same access.
    public mutating func selectProvider(_ provider: LaunchProvider, defaults: LaunchDefaults, parent: String? = nil,
                                        models: (LaunchProvider) -> [LaunchModel]) {
        guard provider != choice.provider else { return }
        let access = choice.access
        choice = defaults.choice(for: folder, machine: machine, parent: machine == nil ? parent : nil, provider: provider, models: models)
        choice.access = access
    }
    /// Another model keeps the effort when the new model supports it.
    public mutating func selectModel(_ id: String, models: [LaunchModel]) {
        choice.model = id
        choice = choice.validated(models: models)
    }
}
