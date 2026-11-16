// Settings → Orchestrator: automatic triage on or off with its daily cap (and today's count) and
// when it pauses itself; the morning brief; the model and effort used when you ask it something
// (the same choices as the Orchestrator page's menus); whether it may read your notes; how many
// memory notes it keeps, with a button to the Orchestrator page's Memory tab; and what files it can read. On a
// wide window "What leaves this Mac" sits on the right, below the groups otherwise. The triage
// switch is the same one as in the Brief's footer on Home.
import SwiftUI
import BurroCore

struct OrchestratorSettingsPane: View {
    var store: AppStore
    @Bindable var brief: OrchestratorBriefStore
    @Bindable var orchestrator: OrchestratorStore
    var memoryCount: Int?
    /// Room for "What leaves this Mac" beside the groups.
    var wide: Bool
    var openPrivacy: () -> Void

    var body: some View {
        if wide {
            HStack(alignment: .top, spacing: 28) {
                groups.frame(maxWidth: .infinity)
                SettingsLeavesCard(store: store, openPrivacy: openPrivacy).frame(width: 300).padding(.top, 86)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                groups
                SettingsLeavesCard(store: store, openPrivacy: openPrivacy)
            }
        }
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsPaneHeader(title: "Orchestrator",
                               summary: SettingsDisclosure.orchestratorSummary(triage: brief.autoTriage, morningBrief: brief.morningBrief,
                                                                               notesAccess: orchestrator.notesAccess))
            SettingsGroup(title: "Automatic triage",
                          note: "When a chat waits on you or finishes, \(OrchestratorTriage.modelTitle) reads the end of it through your Claude Code sign-in and sorts it on Home's Brief: what it needs and, when a short reply would unblock it, a draft you can send, edit or discard. Nothing is sent without your click.",
                          isOn: $brief.autoTriage) {
                SettingsRow(title: "Daily cap", detail: SettingsDisclosure.capUsage(runsToday: brief.runsToday, cap: brief.dailyCap)) {
                    SettingsMenuPicker(label: "Daily triage cap", selection: $brief.dailyCap,
                                       options: OrchestratorBriefStore.caps.map { ($0, "\($0) runs") })
                        .disabled(!brief.autoTriage)
                }
                SettingsRow(title: "Pauses itself", detail: brief.gate == .off ? nil : brief.gate.reason,
                            note: "Never more than 30 runs an hour, and paused while Claude's session limit has under 15% left or the weekly limit under 10%. Chats that stop close together go in one run of up to five.") { EmptyView() }
            }
            SettingsGroup(title: "Morning brief",
                          note: "Once a day, on your first visit after 5 am, triage catches up on chats still waiting or unread from the last day."
                            + (brief.autoTriage ? "" : " Needs automatic triage."),
                          isOn: $brief.morningBrief, switchDisabled: !brief.autoTriage)
            SettingsGroup(title: "Model and effort for your questions",
                          note: "Used when you ask the Orchestrator something, from your next message. Triage always uses Claude \(OrchestratorTriage.modelTitle).") {
                SettingsRow(title: "Model") {
                    SettingsMenuPicker(label: "Orchestrator model", selection: $orchestrator.model,
                                       options: Orchestrator.models.map { ($0.id, $0.id == Orchestrator.model ? "\($0.title) (default)" : $0.title) })
                }
                SettingsRow(title: "Effort") {
                    SettingsMenuPicker(label: "Orchestrator effort", selection: $orchestrator.effort,
                                       options: Orchestrator.efforts.map { ($0, Orchestrator.effortTitle($0)) })
                }
            }
            .disabled(orchestrator.running)
            SettingsGroup(title: "Notes access",
                          note: orchestrator.notesAccess
                            ? "On. The Orchestrator can read your Burro notes, titles and text, when you ask it something. It never writes to them."
                            : "Off. Turning it on lets the Orchestrator read your Burro notes when you ask it something. It would never write to them.",
                          isOn: $orchestrator.notesAccess)
            memory
            canRead
        }
    }

    private var memory: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Memory").font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Text("What the Orchestrator keeps between days, such as which branch is staging. You can read, edit and forget notes on its Memory tab.")
                    .foregroundStyle(AppAppearance.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let memoryCount {
                Text(memoryCount == 1 ? "1 note" : "\(memoryCount) notes").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).monospacedDigit()
            }
            Button("Open Orchestrator memory") {
                store.orchestratorTabRequest = .memory
                store.go(to: .orchestrator)
                AppLaunch.shared.showMainWindow()
            }
            .help("Opens the Orchestrator page's Memory tab in the Burro window")
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(AppCardSurface())
    }

    private var canRead: some View {
        let repos = store.repositoriesFound.map { Self.abbreviate($0.path) }
        let listed = repos.prefix(3).joined(separator: ", ")
        let more = repos.count > 3 ? " and \(repos.count - 3) more" : ""
        return SettingsGroup(title: "What it can read") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(AppAppearance.green).accessibilityHidden(true)
                (Text("Git repositories and their worktrees")
                    + Text(repos.isEmpty ? ", once Burro has found them" : ": ")
                    + Text(listed).font(.system(size: 12, design: .monospaced)).foregroundStyle(AppAppearance.secondary)
                    + Text(more))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(AppAppearance.tertiary).accessibilityHidden(true)
                Text("Never Burro's own data, your tracked activity, your Library folder, .git folders, credential folders such as ~/.ssh and ~/.aws, or files that look like secrets")
                    .foregroundStyle(AppAppearance.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    nonisolated static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
