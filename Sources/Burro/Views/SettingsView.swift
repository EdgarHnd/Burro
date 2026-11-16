// The Settings window: a sidebar of eight areas (General, Chats, Orchestrator, Activity, Machines,
// Notifications, Privacy and data, Advanced) and the chosen area's pane — a title, a sentence on
// what it covers, and cards of controls. Every control writes the same preference or store call it
// always did; only where it sits changed. General, Chats and Advanced are here; the other panes
// have their own files (OrchestratorBriefSettings, AppSettingsSections, RemoteHostsSection,
// KeepAwakeView, SettingsPrivacyPane). Explicit repositories and comparison branches persist only
// in Burro's defaults. It is still the app's Settings scene, opened with ⌘, as before.
import SwiftUI
import BurroCore

struct SettingsView: View {
    @Bindable var store: AppStore
    @State private var pane: SettingsPane
    /// Snapshot tests pass a count so nothing reads the Orchestrator's memory file.
    private let fixedMemoryCount: Int?
    @State private var memoryCount: Int?
    @State private var paneWidth: CGFloat = 0

    init(store: AppStore, pane: SettingsPane = .general, memoryCount: Int? = nil) {
        self.store = store
        _pane = State(initialValue: pane)
        fixedMemoryCount = memoryCount
        _memoryCount = State(initialValue: memoryCount)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(AppAppearance.separator).frame(width: 1)
            ScrollView {
                content
                    .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 36)
                    .frame(maxWidth: pane == .orchestrator ? 1240 : 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(pane)
            .background(GeometryReader { proxy in
                Color.clear.onAppear { paneWidth = proxy.size.width }.onChange(of: proxy.size.width) { paneWidth = proxy.size.width }
            })
        }
        .frame(minWidth: 760, idealWidth: 980, maxWidth: .infinity, minHeight: 560, idealHeight: 720, maxHeight: .infinity)
        .background(AppAppearance.background)
        .task(id: pane) {
            guard pane == .orchestrator, fixedMemoryCount == nil else { return }
            let memory = store.orchestrator.memoryStore
            memoryCount = await Task.detached(priority: .utility) { memory.load().count }.value
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SETTINGS").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
                .padding(.horizontal, 10).padding(.bottom, 8)
            ForEach(SettingsPane.allCases) { item in
                SettingsSidebarButton(pane: item, selected: pane == item) { pane = item }
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 24)
        .frame(width: 210)
        .accessibilityElement(children: .contain).accessibilityLabel("Settings areas")
    }

    @ViewBuilder private var content: some View {
        switch pane {
        case .general: SettingsGeneralPane(store: store)
        case .chats: SettingsChatsPane()
        case .orchestrator:
            OrchestratorSettingsPane(store: store, brief: store.brief, orchestrator: store.orchestrator, memoryCount: memoryCount,
                                     wide: paneWidth >= 940) { pane = .privacy }
        case .activity: SettingsActivityPane(tracker: store.activityTracker)
        case .machines: SettingsMachinesPane(store: store)
        case .notifications: SettingsNotificationsPane(notifier: store.chatNotifier)
        case .privacy: SettingsPrivacyPane(store: store)
        case .advanced: SettingsAdvancedPane(store: store)
        }
    }
}

// MARK: General

/// Appearance, open at login, the agent notch, Notes, usage limits and to-do sync.
struct SettingsGeneralPane: View {
    @Bindable var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsPaneHeader(title: "General", summary: "How Burro looks, whether it opens with your Mac, and the notch, Notes and usage it shows.")
            SettingsGroup(title: "Appearance", note: "Applies to the Burro window and Settings. The agent notch stays dark so it blends with the camera housing.") {
                SettingsRow(title: "Theme") {
                    Picker("Theme", selection: $store.appearance) {
                        ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            LoginItemSettingsGroup(loginItem: store.loginItem)
            SettingsGroup(title: "Agent notch", note: "Hover to expand and move away to collapse. Use the pin button to keep it open. Agent status refreshes about every 3 seconds.",
                          isOn: $store.notchEnabled) {
                SettingsRow(title: "Prefer the main display", note: "Otherwise automatic placement prefers a display with a camera notch.") {
                    SettingsSwitch(label: "Prefer the main display", isOn: $store.notchPreferMainDisplay).disabled(!store.notchEnabled)
                }
            }
            SettingsGroup(title: "Open Notes with ⌥P from any app",
                          note: "A floating notes window over every app and Space. ⌘P browses notes, ⌘K shows actions, ⇧⌘L turns lines into a checklist. Notes are stored on this Mac and listed on Home.",
                          isOn: $store.notesShortcut) {
                if let problem = store.notesShortcutProblem { SettingsNote(problem, color: AppAppearance.amber) }
                HStack { Button("Open Notes") { store.showNotes?(.last) }; Spacer() }
            }
            SettingsGroup(title: "Show usage limits",
                          note: "Connects directly to Codex, Claude, and Grok. Open Usage from Home or the toolbar for accounts, refresh settings, history and display controls.",
                          isOn: $store.usageEnabled) {
                HStack {
                    Button("Connect Claude", action: store.connectClaudeUsage).disabled(store.checkingUsage || !store.usageEnabled)
                    Spacer()
                }
            }
            SettingsTodoSyncGroup(todos: store.todos)
        }
    }
}

/// Open at login: the switch follows macOS's status, with a note and an approval button when needed.
struct LoginItemSettingsGroup: View {
    var loginItem: LoginItemStore
    var body: some View {
        let shown = loginItem.presentation
        SettingsGroup(title: "Open at login",
                      note: "Activity tracking and the agent notch start with your Mac. Tracking only records while Burro is open. Also in System Settings › General › Login Items.",
                      isOn: Binding(get: { shown.isOn }, set: { _ = loginItem.setEnabled($0) })) {
            if shown.note != nil || shown.needsApproval {
                if let note = shown.note {
                    SettingsNote(note, color: shown.isProblem ? AppAppearance.amber : AppAppearance.tertiary)
                }
                if shown.needsApproval {
                    HStack { Button("Open Login Items…") { loginItem.openSystemSettings() }; Spacer() }
                }
            }
        }
        .onAppear { loginItem.refresh() }
    }
}

/// To-dos: connect Burro to Maurice's Convex backend (the same calls as before).
struct SettingsTodoSyncGroup: View {
    @Bindable var todos: TodoStore
    @State private var url = ""
    @State private var token = ""
    @State private var working = false
    @State private var manual = false
    var body: some View {
        SettingsGroup(title: "To-dos", note: "To-dos live in Maurice's Convex backend (the todos table) so the Maurice app can show them. Without sync they stay on this Mac and upload once you connect.") {
            if let config = todos.config {
                SettingsRow(title: "Synced with", detail: config.url.host ?? "Convex") {
                    Button("Sync Now") { todos.sync() }
                    Button("Disconnect", role: .destructive) { todos.disconnect() }
                }
            } else {
                SettingsRow(title: "Not synced") {
                    Button(working ? "Connecting…" : "Import from Maurice") {
                        working = true
                        Task { _ = await todos.importFromMaurice(); working = false }
                    }.disabled(working)
                }
                SettingsNote("Reads CONVEX_URL and EDGAR_API_TOKEN from ~/Dev/maurice-app/Config/Secrets.xcconfig once, checks them, and stores them in your Keychain.")
                DisclosureGroup("Enter manually", isExpanded: $manual) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Deployment URL", text: $url, prompt: Text("https://example.convex.cloud"))
                        SecureField("Owner token", text: $token)
                        Button("Connect") {
                            guard let valid = ConvexConfig.validURL(url) else { todos.message = "Use your https://….convex.cloud URL."; return }
                            working = true
                            Task { if await todos.connect(ConvexConfig(url: valid, token: token)) { token = "" }; working = false }
                        }.disabled(working || url.isEmpty || token.count < 16)
                    }
                    .textFieldStyle(.roundedBorder).padding(.top, 6)
                }
            }
            if let message = todos.message { SettingsNote(message, color: AppAppearance.amber) }
        }
    }
}

// MARK: Chats

/// Where a chat opens when you click it in the notch or the menu bar.
struct SettingsChatsPane: View {
    @AppStorage(AppStore.openChatsInBurroKey) private var openInBurro = true
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsPaneHeader(title: "Chats", summary: openInBurro
                ? "Chats you click in the notch or the menu bar open on Burro's Chats page."
                : "Chats you click in the notch or the menu bar open in Codex or Claude.")
            SettingsGroup(title: "Open chats in Burro",
                          note: "Clicking a chat in the notch or the menu bar opens it on Burro's Chats page. Hold ⌥ to open it in Codex or Claude instead. Off, it opens in Codex or Claude, and ⌥ opens it in Burro.",
                          isOn: $openInBurro) {
                SettingsNote("Chats without a Codex or Claude link always open in Burro. Banners when a chat needs you are under Notifications.")
            }
        }
    }
}

// MARK: Advanced

/// Repository discovery, added repositories, comparison branches and a rescan.
struct SettingsAdvancedPane: View {
    @Bindable var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsPaneHeader(title: "Advanced", summary: "Which repositories Burro scans for worktrees and what each one is compared against.")
            SettingsGroup(title: "Discover repositories automatically",
                          note: "Reads Codex projects, Claude Code sessions, ~/Dev (two levels), and Codex worktree folders. Add repositories stored elsewhere below.",
                          isOn: $store.discover)
            SettingsGroup(title: "Added repositories", note: "Tracked even when discovery doesn't find them.") {
                ForEach(store.repositories, id: \.self) { path in
                    HStack {
                        Text(path).font(.system(size: 12, design: .monospaced)).foregroundStyle(AppAppearance.secondary).lineLimit(2)
                        Spacer()
                        Button { store.repositories.removeAll { $0 == path }; Task { await store.refresh() } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Stop explicitly tracking this repository")
                            .accessibilityLabel("Stop tracking \(path)")
                    }
                }
                HStack { Button("Add repository…") { store.addRepository() }; Spacer() }
            }
            SettingsGroup(title: "Comparison branches",
                          note: "Defaults to origin/HEAD, then origin/main, origin/master, or origin/staging. Uses local refs; no automatic network requests.") {
                if store.repositoriesFound.isEmpty {
                    SettingsNote("Repositories appear here after the first scan.")
                }
                ForEach(store.repositoriesFound, id: \.path) { repository in
                    SettingsRow(title: repository.name) {
                        TextField(repository.name, text: Binding(get: { store.baseOverrides[repository.path] ?? "" }, set: { store.baseOverrides[repository.path] = $0 }),
                                  prompt: Text("Automatic"))
                            .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                }
            }
            SettingsGroup(title: "Rescan", note: "Scans repositories and worktrees again with the settings above.") {
                HStack { Button("Apply & refresh") { Task { await store.refresh() } }.disabled(store.scanning); Spacer() }
            }
        }
    }
}
