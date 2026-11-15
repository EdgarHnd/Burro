// Explicit repository and comparison-branch preferences persist only in Burro's defaults; so do the
// notification, activity and Shipped toggles (AppSettingsSections.swift).
import SwiftUI
import BurroCore

struct SettingsView: View {
    @Bindable var store: AppStore
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $store.appearance) {
                    ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Text("Applies to the Burro window and Settings. The agent notch stays dark so it blends with the camera housing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LoginItemSettingsSection(loginItem: store.loginItem)
            TodoSyncSection(todos: store.todos)
            Section("Notes") {
                Toggle("Open Notes with ⌥P from any app", isOn: $store.notesShortcut)
                if let problem = store.notesShortcutProblem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
                Text("A floating notes window over every app and Space. ⌘P browses notes, ⌘K shows actions, ⇧⌘L turns lines into a checklist. Notes are stored on this Mac and listed on Home.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Notes") { store.showNotes?(.last) }
            }
            Section("Agent notch") {
                Toggle("Show agent notch", isOn: $store.notchEnabled)
                Toggle("Prefer the main display", isOn: $store.notchPreferMainDisplay)
                    .disabled(!store.notchEnabled)
                OpenChatsInBurroToggle()
                Text("Hover to expand and move away to collapse. Use the pin button to keep it open. Agent status refreshes about every 3 seconds. Automatic placement prefers a display with a camera notch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            NotificationSettingsSection(notifier: store.chatNotifier)
            KeepAwakeSettingsSection(keepAwake: store.keepAwake)
            Section("Usage limits") {
                Toggle("Show usage limits", isOn: $store.usageEnabled)
                Text("Connects directly to Codex, Claude, and Grok. Open Usage from Home or the toolbar for accounts, refresh settings, history and display controls.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Connect Claude", action: store.connectClaudeUsage).disabled(store.checkingUsage || !store.usageEnabled)
            }
            RemoteHostsSection(store: store)
            ActivityBrowserSettingsSection(tracker: store.activityTracker)
            ShippedSummarySettingsSection()
            OrchestratorBriefSettingsSection(brief: store.brief)
            Section("Discovery") {
                Toggle("Discover repositories automatically", isOn: $store.discover)
                Text("Reads Codex projects, Claude Code sessions, ~/Dev (two levels), and Codex worktree folders. Add repositories stored elsewhere below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Added repositories") {
                ForEach(store.repositories, id: \.self) { path in
                    HStack {
                        Text(path).font(.caption).lineLimit(2)
                        Spacer()
                        Button { store.repositories.removeAll { $0 == path }; Task { await store.refresh() } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Stop explicitly tracking this repository")
                    }
                }
                Button("Add repository…") { store.addRepository() }
            }
            Section("Comparison branches") {
                Text("Defaults to origin/HEAD, then origin/main, origin/master, or origin/staging. Uses local refs; no automatic network requests.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(store.repositoriesFound, id: \.path) { repository in
                    TextField(repository.name, text: Binding(get: { store.baseOverrides[repository.path] ?? "" }, set: { store.baseOverrides[repository.path] = $0 }), prompt: Text("Automatic"))
                }
            }
            Section("Privacy & cleanup") {
                Text("No hooks or analytics. Optional Usage reads your selected provider sign-ins. Remote machines you add are read through SSH; session titles stay on this Mac. Cleanup requires confirmation and a fresh check. Eligible local worktrees move to Trash with their data preserved and branches kept.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Apply & refresh") { Task { await store.refresh() } }.disabled(store.scanning)
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).frame(width: 560, height: 680)
    }
}

/// Open at login: the toggle follows macOS's status, with a note and an approval button when needed.
private struct LoginItemSettingsSection: View {
    var loginItem: LoginItemStore
    var body: some View {
        let shown = loginItem.presentation
        Section("Startup") {
            Toggle("Open at login", isOn: Binding(get: { shown.isOn }, set: { loginItem.setEnabled($0) }))
            if let note = shown.note {
                Text(note).font(.caption).foregroundStyle(shown.isProblem ? .orange : .secondary)
            }
            if shown.needsApproval {
                Button("Open Login Items…") { loginItem.openSystemSettings() }
            }
            Text("Activity tracking and the agent notch start with your Mac. Tracking only records while Burro is open. Also in System Settings › General › Login Items.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { loginItem.refresh() }
    }
}
