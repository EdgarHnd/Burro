// Start a Codex or Claude chat. Top to bottom: the title with "Burro remembers your last choices
// per project"; one large prompt field with the cursor in it; one line of labelled chips — Project ▾
// · Agent (provider · model · effort) ▾ · Access ▾ · machine ▾ — already filled from the last launch
// in that project (LaunchDefaults); Recent (the last prompts started from this sheet in the chosen
// project, first line shown, two as chips and the rest under "N more") and Templates (three
// built-ins plus the owner's own: "Save as template" keeps the current prompt, the × on hover or
// the context menu deletes one of his) — a click puts that prompt in the field, replacing what is
// there (LaunchPromptMemory, kept on this Mac only); then "Start in a new worktree" with the branch
// it will create (this Mac and git projects only: on Start, Burro makes the worktree first and
// starts the chat in it; a failure shows on the Starting row with Retry and nothing starts; the
// switch hides while a newly chosen folder is being checked, and Start checks the folder again) and,
// on the right, the chosen provider's quota from the usage reading ("Claude session: 38% left ·
// resets 23:00", hidden when unknown or on another machine); and the footer's key hints, Cancel
// and Start chat.
// The project chip lists recently used projects first and ⌘1–⌘9 pick them; switching project brings
// back that project's choices, switching provider brings back the model and effort last used with
// it. ⌘↩ starts the chat and follows it on the Chats page; ⇧⌘↩ starts it and stays on the current
// page; Escape cancels. Starting closes the sheet at once: the chat shows as "Starting…" in Chats
// while the provider spins it up (for Claude, the start check of up to 20 seconds runs then, not
// here). Opening the sheet from a to-do, a note, the palette, a worktree or Retry prefills it; only
// Start launches.
// The machine chip lists This Mac and every configured machine with its status line (paused or
// unreachable ones can't be picked, and say why). With another machine chosen, the project chip
// lists that machine's folders: the remembered list at once, refreshed over SSH off the main thread
// when the sheet opens or the machine changes (a spinner in the chip; a failure is shown and the
// remembered list kept), each with its repository and branch and, for Claude, a quiet "not trusted
// by Claude yet". "Type a path…" checks a folder on that machine and shows the exact reason when it
// isn't usable. Codex models come from that machine (remembered; "Default" while loading).
import AppKit
import SwiftUI
import BurroCore

struct NewChatSheet: View {
    @Bindable var store: AppStore
    /// Prompt memory to show instead of the saved one (snapshot tests).
    private let initialPrompts: LaunchPromptMemory?
    @Environment(\.dismiss) private var dismiss
    @State private var prompts = LaunchPromptMemory()
    /// Whether the chosen folder on this Mac is a git project (checked off the main thread).
    @State private var gitProject = false
    @State private var form = LaunchForm()
    @State private var defaults = LaunchDefaults()
    @State private var customFolders: [String] = []
    @State private var error: String?
    @FocusState private var promptFocused: Bool
    // Another machine's folders and models, for the machine in `remoteFor`.
    @State private var remoteFor: UUID?
    @State private var remoteFolders: [RemoteFolder] = []
    @State private var loadingFolders = false
    @State private var foldersProblem: String?
    @State private var remoteModels: [LaunchModel] = []
    @State private var loadingModels = false
    // "Type a path…" on another machine.
    @State private var typingPath = false
    @State private var typedPath = ""
    @State private var checkingPath = false
    @State private var pathProblem: String?
    @FocusState private var pathFocused: Bool

    init(store: AppStore, prompts: LaunchPromptMemory? = nil) {
        self.store = store
        initialPrompts = prompts
    }

    /// The model lists for a machine, as a closure that doesn't read `form` (it is passed into `form`'s own mutations).
    private func modelLists(for machine: UUID?) -> (LaunchProvider) -> [LaunchModel] {
        let codex = machine == nil ? store.codexModels : remoteModels
        return { $0 == .codex ? codex : LaunchModel.claude }
    }
    private var models: [LaunchModel] { modelLists(for: form.machine)(form.choice.provider) }
    private var host: RemoteHost? { form.machine.flatMap { id in store.remoteHosts.first { $0.id == id } } }
    private var machines: [LaunchMachine] {
        LaunchMachines.options(hosts: store.remoteHosts, snapshot: { store.connection(for: $0) }, status: { store.remoteStatusLine(for: $0) })
    }
    private var selectedMachine: LaunchMachine { machines.first { $0.id == form.machine } ?? LaunchMachines.thisMac }
    private var localProjects: [(path: String, name: String)] {
        let ordered = defaults.orderedProjects(known: store.launchFolders, exists: FileManager.default.fileExists(atPath:))
        let extra = customFolders.filter { path in !ordered.contains { LaunchDefaults.key($0.path) == path } }
            .map { (path: $0, name: URL(fileURLWithPath: $0).lastPathComponent) }
        return extra + ordered
    }
    /// The project chip's entries for the chosen machine, in order (⌘1–⌘9 pick the first nine).
    private var projects: [(path: String, name: String)] {
        guard let machine = form.machine else { return localProjects }
        return defaults.orderedFolders(machine: machine, folders: remoteFolders)
            .map { (path: $0.path, name: LaunchMachines.folderTitle($0, provider: form.choice.provider)) }
    }
    private var projectName: String {
        if form.folder.isEmpty { return form.machine == nil ? "Choose project" : "Choose folder" }
        if form.machine != nil { return URL(fileURLWithPath: form.folder).lastPathComponent }
        return projects.first { LaunchDefaults.key($0.path) == form.folder }?.name ?? URL(fileURLWithPath: form.folder).lastPathComponent
    }
    private var agentName: String { form.choice.provider == .codex ? "Codex" : "Claude" }
    private var machineSuffix: String { form.machine == nil ? "" : " on \(selectedMachine.name)" }
    private var canStart: Bool { form.canStart && selectedMachine.available }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("New chat").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 8)
                Text("Burro remembers your last choices per project").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $form.prompt)
                    .font(.system(size: 15)).scrollContentBackground(.hidden)
                    .focused($promptFocused)
                    .padding(12)
                    .accessibilityLabel("Prompt")
                if form.prompt.isEmpty {
                    Text("What should \(agentName) do in \(projectName)\(machineSuffix)?")
                        .font(.system(size: 15)).foregroundStyle(AppAppearance.tertiary)
                        .padding(.horizontal, 17).padding(.vertical, 12).allowsHitTesting(false)
                }
            }
            .frame(minHeight: 132)
            .background(AppAppearance.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(promptFocused ? AppAppearance.tertiary.opacity(0.6) : AppAppearance.hairline))

            FlowLayout(spacing: 6) {
                projectChip
                modelChip
                accessChip
                machineChip
            }

            if typingPath, form.machine != nil { pathField }

            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(AppAppearance.amber)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let foldersProblem, form.machine != nil {
                Text(foldersProblem).font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            NewChatPromptShortcuts(recent: prompts.recentPrompts(folder: form.folder, machine: form.machine),
                                   templates: prompts.templates, canSave: prompts.canSave(form.prompt),
                                   use: usePrompt, save: saveTemplate, delete: deleteTemplate)

            let quota = quotaLine
            if showsWorktreeSwitch || quota != nil {
                Rectangle().fill(AppAppearance.separator).frame(height: 1)
                NewChatWorktreeRow(worktree: showsWorktreeSwitch ? $form.newWorktree : nil,
                                   branch: NewWorktree.branchName(prompt: form.prompt, provider: form.choice.provider), quota: quota)
            }

            NewChatFooter(canStart: canStart, cancel: { dismiss() }, start: { start(follow: true) })
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
        .frame(width: 700)
        .background { shortcuts }
        .background(AppAppearance.surface)
        .modifier(AppTheme())
        .onAppear(perform: prepare)
        .task(id: form.machine == nil ? form.folder : "") {
            // Unknown until this folder's own answer arrives: never the previous folder's.
            gitProject = false
            let folder = form.machine == nil ? form.folder : ""
            let found = await Task.detached(priority: .userInitiated) { NewWorktree.isGitProject(folder) }.value
            if !Task.isCancelled { gitProject = found }
        }
        .onChange(of: store.codexModels) { _, _ in
            if form.machine == nil, form.choice.provider == .codex { form.choice = form.choice.validated(models: store.codexModels) }
        }
        .onChange(of: remoteModels) { _, _ in
            if form.machine != nil, form.choice.provider == .codex { form.choice = form.choice.validated(models: remoteModels) }
        }
        .onChange(of: form) { _, _ in error = nil }
        .onChange(of: form.machine) { _, machine in
            typingPath = false; pathProblem = nil
            loadRemote(machine)
        }
    }

    /// The worktree switch: this Mac, a git project.
    private var showsWorktreeSwitch: Bool { form.machine == nil && gitProject }

    /// The chosen provider's quota on this Mac's account; another machine may be signed in differently.
    private var quotaLine: String? {
        guard form.machine == nil else { return nil }
        return LaunchQuota.line(provider: form.choice.provider, modelTitle: form.choice.selectedModel(in: models)?.title,
                                usage: store.providerUsage, now: Date(), calendar: .current)
    }

    private func usePrompt(_ text: String) {
        form.prompt = text
        promptFocused = true
    }
    private func saveTemplate() {
        guard prompts.saveTemplate(form.prompt) != nil else { return }
        persistPrompts()
    }
    private func deleteTemplate(_ id: String) {
        prompts.deleteTemplate(id)
        persistPrompts()
    }
    /// Saved only for the real sheet, never for a snapshot's sample memory.
    private func persistPrompts() {
        guard initialPrompts == nil else { return }
        var stored = store.launchPrompts
        stored.saved = prompts.saved
        store.launchPrompts = stored
    }

    /// The amber line: a start problem, else why the chosen machine can't be used now.
    private var notice: String? {
        if let error { return error }
        if let reason = selectedMachine.unavailable { return "\(selectedMachine.name) can't start chats right now: \(reason)." }
        return nil
    }

    // MARK: Chips

    private var projectChip: some View {
        NewChatChip(label: "Project", title: projectName, busy: form.machine != nil && loadingFolders) {
            let list = projects
            if form.machine != nil, list.isEmpty {
                Text(loadingFolders ? "Loading folders…" : "No folders remembered yet")
            }
            ForEach(Array(list.enumerated()), id: \.element.path) { index, project in
                Button { selectProject(project.path) } label: {
                    Text(index < 9 ? "\(project.name)    ⌘\(index + 1)" : project.name)
                }
                .help(project.path)
            }
            Divider()
            if form.machine == nil {
                Button("Choose folder…", action: chooseFolder)
            } else {
                Button("Type a path…") { typedPath = form.folder; pathProblem = nil; typingPath = true; pathFocused = true }
            }
        }
        .help(form.folder.isEmpty ? "Project" : (form.machine == nil ? (form.folder as NSString).abbreviatingWithTildeInPath : form.folder))
    }

    private var modelChip: some View {
        let choice = form.choice
        let modelTitle = choice.selectedModel(in: models)?.title ?? (choice.model.isEmpty ? "Default" : choice.model)
        let title = [agentName, modelTitle, choice.effort.isEmpty ? nil : Self.effortTitle(choice.effort).lowercased()].compactMap { $0 }.joined(separator: " · ")
        let efforts = choice.selectedModel(in: models)?.efforts ?? []
        let codexLoading = form.machine == nil ? store.codexModels.isEmpty : (remoteModels.isEmpty && loadingModels)
        return NewChatChip(label: "Agent", title: title) {
            Section("Agent") {
                ForEach(LaunchProvider.allCases) { provider in
                    Toggle(provider.title, isOn: Binding(get: { form.choice.provider == provider }, set: { if $0 { selectProvider(provider) } }))
                }
            }
            Section("Model") {
                if form.choice.provider == .codex {
                    Toggle(codexLoading ? "Default (loading models…)" : "Default",
                           isOn: Binding(get: { form.choice.model.isEmpty }, set: { if $0 { let list = models; form.selectModel("", models: list) } }))
                }
                ForEach(models) { model in
                    Toggle(model.title, isOn: Binding(get: { form.choice.model == model.id }, set: { if $0 { let list = models; form.selectModel(model.id, models: list) } }))
                }
            }
            if !efforts.isEmpty {
                Section("Effort") {
                    Toggle("Default effort", isOn: Binding(get: { form.choice.effort.isEmpty }, set: { if $0 { form.choice.effort = "" } }))
                    ForEach(efforts, id: \.self) { effort in
                        Toggle(Self.effortTitle(effort), isOn: Binding(get: { form.choice.effort == effort }, set: { if $0 { form.choice.effort = effort } }))
                    }
                }
            }
        }
    }

    private var accessChip: some View {
        NewChatChip(label: "Access", title: form.choice.access.title) {
            ForEach(LaunchAccess.allCases) { access in
                Toggle(access.title, isOn: Binding(get: { form.choice.access == access }, set: { if $0 { form.choice.access = access } }))
            }
        }
        .help(form.choice.access.detail)
    }

    private var machineChip: some View {
        let list = machines
        return NewChatChip(label: nil, dot: selectedMachine.available ? AppAppearance.green : AppAppearance.tertiary, title: selectedMachine.name) {
            ForEach(list) { machine in
                Toggle(LaunchMachines.rowTitle(machine), isOn: Binding(get: { form.machine == machine.id }, set: { if $0 { selectMachine(machine.id) } }))
                    .disabled(!machine.available && form.machine != machine.id)
            }
        }
        .help(form.machine == nil ? "Runs on this Mac" : "Runs on \(selectedMachine.name) · \(selectedMachine.detail)")
    }

    /// A folder path typed for another machine, checked there before it is used.
    private var pathField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("/Users/you/Dev/project on \(selectedMachine.name)", text: $typedPath)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .focused($pathFocused)
                    .onSubmit(checkTypedPath)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(AppAppearance.surface, in: Capsule()).overlay(Capsule().strokeBorder(AppAppearance.separator))
                if checkingPath { ProgressView().controlSize(.small) }
                Button("Use folder", action: checkTypedPath)
                    .disabled(checkingPath || typedPath.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { typingPath = false; pathProblem = nil }
            }
            if let pathProblem {
                Text(pathProblem).font(.system(size: 11)).foregroundStyle(AppAppearance.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// ⇧⌘↩ and ⌘1–⌘9, as invisible buttons so they work while the prompt has focus.
    private var shortcuts: some View {
        ZStack {
            Button("Start and stay here") { start(follow: false) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(!canStart)
            ForEach(0..<9, id: \.self) { index in
                Button("Project \(index + 1)") {
                    let list = projects
                    if list.indices.contains(index) { selectProject(list[index].path) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }

    static func effortTitle(_ value: String) -> String {
        switch value {
        case "xhigh": "Extra high"
        case "max": "Max"
        default: value.prefix(1).uppercased() + value.dropFirst()
        }
    }

    // MARK: Actions

    /// This Mac's project when nothing else names one: the last launch still on disk, else the first listed.
    private var localFallback: String {
        LaunchDefaults.key(defaults.lastProject(exists: FileManager.default.fileExists(atPath:)) ?? localProjects.first?.path ?? "")
    }

    private func prepare() {
        store.loadCodexModels()
        defaults = store.launchDefaults
        prompts = initialPrompts ?? store.launchPrompts
        let draft = store.newChatDraft ?? LaunchDraft()
        store.newChatDraft = nil
        let options = machines
        // A machine removed since (an old Retry) falls back to this Mac.
        let machine = draft.machine(lastMachine: defaults.lastMachineID) { id in options.contains { $0.id == id && $0.available } }
            .flatMap { id in store.remoteHosts.contains { $0.id == id } ? id : nil }
        if machine == nil, let folder = draft.folder.map(LaunchDefaults.key), !localProjects.contains(where: { LaunchDefaults.key($0.path) == folder }) {
            customFolders.append(folder)
        }
        if let machine, let host = store.remoteHosts.first(where: { $0.id == machine }) {
            // The remembered models first, so a Retry's model validates against that machine's list.
            remoteModels = RemoteLaunch.cachedCodexModels(host: host) ?? []
        }
        form = LaunchForm(draft: draft, machine: machine, fallbackFolder: localFallback, defaults: defaults,
                          parent: { store.launchParent(of: $0) }, models: modelLists(for: machine))
        promptFocused = true
        if machine != nil { loadRemote(machine) }
    }

    private func selectProject(_ path: String) {
        let lists = modelLists(for: form.machine), parent = form.machine == nil ? store.launchParent(of: path) : nil
        form.selectProject(path, defaults: defaults, parent: parent, models: lists)
    }
    private func selectProvider(_ provider: LaunchProvider) {
        let lists = modelLists(for: form.machine), parent = form.machine == nil ? store.launchParent(of: form.folder) : nil
        form.selectProvider(provider, defaults: defaults, parent: parent, models: lists)
    }
    private func selectMachine(_ id: UUID?) {
        if let id, id != remoteFor, let host = store.remoteHosts.first(where: { $0.id == id }) {
            remoteModels = RemoteLaunch.cachedCodexModels(host: host) ?? []
            remoteFolders = []
        }
        let lists = modelLists(for: id), local = localFallback
        form.selectMachine(id, defaults: defaults, localFolder: local, parent: { store.launchParent(of: $0) }, models: lists)
    }

    /// Another machine's folders and Codex models: the remembered ones at once, then fresh ones over
    /// SSH off the main thread (skipped while the machine is unreachable or paused).
    private func loadRemote(_ machine: UUID?) {
        guard let machine, let host = store.remoteHosts.first(where: { $0.id == machine }) else {
            remoteFor = nil; loadingFolders = false; loadingModels = false; foldersProblem = nil
            return
        }
        if remoteFor == machine, loadingFolders { return }
        remoteFor = machine
        foldersProblem = nil
        let reachable = selectedMachine.available
        loadingFolders = reachable
        loadingModels = reachable
        Task { @MainActor in
            let cached = await Task.detached(priority: .userInitiated) { RemoteLaunch.cachedFolders(host: host) }.value
            if remoteFor == machine, let cached { remoteFolders = cached.folders }
            guard reachable else { return }
            async let folders = Task.detached(priority: .userInitiated) { () -> Result<RemoteFolderList, Error> in
                Result { try RemoteLaunch.folders(host: host) }
            }.value
            async let codex = Task.detached(priority: .userInitiated) { () -> [LaunchModel]? in
                try? RemoteLaunch.codexModels(host: host)
            }.value
            let listed = await folders
            if remoteFor == machine {
                loadingFolders = false
                switch listed {
                case .success(let list): remoteFolders = list.folders
                case .failure(let problem):
                    let reason = (problem as? LocalizedError)?.errorDescription ?? "Couldn't list folders."
                    foldersProblem = "Couldn't refresh the folder list: \(reason)" + (remoteFolders.isEmpty ? "" : " Showing the remembered list.")
                }
            }
            let fresh = await codex
            if remoteFor == machine {
                loadingModels = false
                if let fresh, !fresh.isEmpty { remoteModels = fresh }
            }
        }
    }

    private func checkTypedPath() {
        let path = typedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !checkingPath, let machine = form.machine, let host else { return }
        checkingPath = true
        pathProblem = nil
        Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(RemoteFolderCheck, RemoteFolderList?), Error> in
                Result { (try RemoteLaunch.validate(host: host, path: path), RemoteLaunch.cachedFolders(host: host)) }
            }.value
            checkingPath = false
            guard form.machine == machine else { return }
            switch outcome {
            case .success(let (check, cached)):
                if let cached { remoteFolders = cached.folders }
                typingPath = false
                selectProject(check.path)
            case .failure(let problem):
                pathProblem = (problem as? LocalizedError)?.errorDescription ?? "That folder can't be used on \(host.name)."
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Use folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = LaunchDefaults.key(url.path)
        if !customFolders.contains(path) { customFolders.append(path) }
        selectProject(path)
    }

    /// Checks what can be checked instantly, hands the launch to the store, and closes. On another
    /// machine the folder, trust and install checks run there, as part of the start.
    private func start(follow: Bool) {
        guard canStart else { return }
        let request = form.request
        if let machine = form.machine {
            store.launch(request, follow: follow, machine: machine)
            dismiss()
            return
        }
        guard FileManager.default.fileExists(atPath: request.folder) else { error = LaunchError.missingFolder.errorDescription; return }
        let installed = request.provider == .codex ? CodexUsageReader.executable() != nil : ClaudeLaunch.executable() != nil
        guard installed else { error = LaunchError.notInstalled(request.provider).errorDescription; return }
        // The switch must be showing for this folder, and the folder is checked again now.
        let worktree = showsWorktreeSwitch && form.newWorktree && NewWorktree.isGitProject(request.folder)
        store.launch(request, follow: follow, newWorktree: worktree)
        dismiss()
    }
}
