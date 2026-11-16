// Settings → Privacy and data: "What leaves this Mac", one line per channel worked out from the
// real toggles (SettingsDisclosure), and where Burro keeps its data on this Mac, each with the
// action that already existed for it: delete all tracked activity (asks first), clear quota
// history (asks first), clear the copies of other machines' chats, or show the folder in Finder.
// The same "What leaves this Mac" card sits beside the Orchestrator pane with a link here.
import AppKit
import SwiftUI
import BurroCore

/// The toggles the disclosure depends on, read from the stores.
@MainActor func settingsDisclosureState(_ store: AppStore, shippedSummaries: Bool) -> SettingsDisclosure.State {
    SettingsDisclosure.State(triage: store.brief.autoTriage, shippedSummaries: shippedSummaries, usageLimits: store.usageEnabled,
                             notesAccess: store.orchestrator.notesAccess, todoSyncHost: store.todos.config.map { $0.url.host ?? "Convex" },
                             machines: store.remoteHosts.filter(\.enabled).map(\.name), smallModel: ShippedSummary.modelTitle)
}

/// "What leaves this Mac": a bright dot for what is sent, grey for what stays.
struct SettingsLeavesList: View {
    var lines: [SettingsDisclosure.Line]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(line.sends ? AppAppearance.text : AppAppearance.tertiary.opacity(0.7)).frame(width: 7, height: 7)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        .accessibilityHidden(true)
                    Text(line.text).foregroundStyle(line.sends ? AppAppearance.text : AppAppearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The side card on the Orchestrator pane.
struct SettingsLeavesCard: View {
    var store: AppStore
    var openPrivacy: () -> Void
    @AppStorage(ShippedStore.summariesKey) private var summaries = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WHAT LEAVES THIS MAC").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
            SettingsLeavesList(lines: SettingsDisclosure.lines(settingsDisclosureState(store, shippedSummaries: summaries)))
            SettingsRule()
            Button("Privacy and data settings", action: openPrivacy).buttonStyle(.link)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(AppCardSurface())
    }
}

struct SettingsPrivacyPane: View {
    var store: AppStore
    @AppStorage(ShippedStore.summariesKey) private var summaries = true
    @State private var confirm: Confirm?
    @State private var remoteBytes: Int64?
    @State private var remoteVersion = 0

    private enum Confirm: Identifiable { case activity, quotaHistory; var id: Self { self } }

    var body: some View {
        let lines = SettingsDisclosure.lines(settingsDisclosureState(store, shippedSummaries: summaries))
        VStack(alignment: .leading, spacing: 14) {
            SettingsPaneHeader(title: "Privacy and data",
                               summary: "No hooks or analytics. Here is everything that leaves this Mac, and where Burro keeps the rest.")
            SettingsGroup(title: "What leaves this Mac", note: "Each line follows its setting.") {
                SettingsLeavesList(lines: lines)
            }
            SettingsGroup(title: "Stored on this Mac",
                          note: "Session titles from other machines stay on this Mac. Optional Usage reads your selected provider sign-ins.") {
                location("Tracked activity", path: ActivityLog.defaultFolder) {
                    Button("Delete all activity…", role: .destructive) { confirm = .activity }
                }
                SettingsRule()
                revealRow("Orchestrator memory, Brief, proposals and runs", path: Orchestrator.folder)
                SettingsRule()
                revealRow("Notes, to-dos and queued replies", path: NotesStore.defaultFolder)
                SettingsRule()
                location("Quota history", path: NotesStore.defaultFolder.appendingPathComponent("usage-history.json")) {
                    Button("Clear quota history…", role: .destructive) { confirm = .quotaHistory }
                }
                SettingsRule()
                location("Copies of other machines' chats" + (remoteBytes.map { $0 > 0 ? " · \(RemoteHostsSection.size($0))" : "" } ?? ""),
                         path: RemoteCache.defaultRoot) {
                    Button("Clear all caches") { Task { await store.clearRemoteCache(nil); remoteVersion += 1 } }
                        .disabled((remoteBytes ?? 0) == 0)
                        .help("Removes what Burro copied from your other machines: last-seen chats, transcript copies, images and videos")
                }
            }
            SettingsGroup(title: "Worktree cleanup",
                          note: "Cleanup always asks first and checks again. Eligible local worktrees move to the Trash with their data preserved and their branches kept.")
        }
        .task(id: "\(remoteVersion)-\(store.remoteHosts.map(\.id))") {
            remoteBytes = await store.remoteCacheUsage().values.reduce(0, +)
        }
        .confirmationDialog(confirm == .activity ? "Delete all recorded activity?" : "Clear quota history?",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            if confirm == .activity {
                Button("Delete everything", role: .destructive) { store.activityTracker.deleteAll() }
            } else {
                Button("Clear history", role: .destructive) { store.usage.clearHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirm == .activity ? "Every recorded day is removed from this Mac. This can't be undone."
                                      : "The last 30 days of quota readings are removed from this Mac. Live limits stay.")
        }
    }

    private func location<Action: View>(_ title: String, path: URL, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(OrchestratorSettingsPane.abbreviate(path.path)).font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(AppAppearance.tertiary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action()
        }
    }

    private func revealRow(_ title: String, path: URL) -> some View {
        location(title, path: path) {
            Button("Show in Finder") { reveal(path) }.help("Shows \(OrchestratorSettingsPane.abbreviate(path.path)) in Finder")
        }
    }

    private func reveal(_ folder: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
