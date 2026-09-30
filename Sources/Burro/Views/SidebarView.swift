// Lightweight native filters expose inactive worktrees without hiding their risks.
import SwiftUI
import BurroCore

struct SidebarView: View {
    @Bindable var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.filter) {
                Section("Workspace") {
                    ForEach([WorktreeFilter.all, .working, .inUse, .inactive, .candidates, .cleanup, .protected], id: \.self) { filter in
                        HStack {
                            Label(filter.title, systemImage: filter.icon)
                            Spacer()
                            Text("\(store.snapshot.worktrees.filter { store.matches(filter, tree: $0) }.count)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        }.tag(filter)
                    }
                }
                Section("Agents") {
                    HStack {
                        Label("Remote sessions", systemImage: "network")
                        Spacer()
                        Text("\(store.remoteSessions.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }.tag(WorktreeFilter.remote)
                }
                Section("Accounts") {
                    Label("Usage", systemImage: WorktreeFilter.usage.icon).tag(WorktreeFilter.usage)
                }
                Section("Repositories") {
                    ForEach(store.repositoriesFound, id: \.path) { repository in
                        Label(repository.name, systemImage: "folder").lineLimit(1)
                            .tag(WorktreeFilter.repository(repository.path)).help(repository.path)
                    }
                }
            }
            .listStyle(.sidebar)
            VStack(alignment: .leading, spacing: Layout.small) {
                Label(store.remoteHosts.isEmpty ? "Local on this Mac" : "This Mac + \(store.remoteHosts.count) remote", systemImage: "desktopcomputer")
                    .font(.caption.weight(.medium))
                Text("Refreshes every 30 seconds")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack { Spacer(); SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Settings") }
            }.foregroundStyle(.secondary).padding(Layout.inset)
        }
    }
}
