// Worktree filters for the Worktrees page; other destinations live in the page switcher.
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
                            Text("\(store.availableWorktrees.filter { store.matches(filter, tree: $0) }.count)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        }.tag(filter)
                    }
                }
                if !store.benches.benches.isEmpty {
                    Section("Benches") {
                        ForEach(store.benches.benches) { bench in
                            Label { Text(bench.name).lineLimit(1) } icon: { Image(systemName: bench.symbol).foregroundStyle(bench.tint) }
                                .tag(WorktreeFilter.bench(bench.id))
                        }
                    }
                }
                Section("Repositories") {
                    ForEach(store.repositoriesFound, id: \.path) { repository in
                        Label(repository.name, systemImage: "folder").lineLimit(1)
                            .tag(WorktreeFilter.repository(repository.path)).help(repository.path)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .font(.system(size: 12, weight: .medium))
            .tint(AppAppearance.text)
            VStack(alignment: .leading, spacing: Layout.small) {
                Label(store.remoteHosts.isEmpty ? "Local on this Mac" : "This Mac + \(store.remoteHosts.count) remote", systemImage: "desktopcomputer")
                    .font(.caption.weight(.medium))
                if store.didScan {
                    Text("Checked \(store.snapshot.scannedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack { Spacer(); SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Settings") }
            }.foregroundStyle(.secondary).padding(Layout.inset)
        }.background(AppAppearance.background)
    }
}
