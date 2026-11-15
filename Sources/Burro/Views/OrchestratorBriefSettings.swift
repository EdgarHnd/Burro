// Settings → Orchestrator: automatic triage on or off, its daily cap, when it pauses itself (in
// plain words), and the morning brief. The same on/off switch is in the Brief's footer on Home.
import SwiftUI
import BurroCore

struct OrchestratorBriefSettingsSection: View {
    @Bindable var brief: OrchestratorBriefStore
    var body: some View {
        Section("Orchestrator") {
            Toggle("Triage chats automatically", isOn: $brief.autoTriage)
            Picker("Daily cap", selection: $brief.dailyCap) {
                ForEach(OrchestratorBriefStore.caps, id: \.self) { Text("\($0) runs").tag($0) }
            }
            .disabled(!brief.autoTriage)
            Toggle("Morning brief", isOn: $brief.morningBrief).disabled(!brief.autoTriage)
            Text("When a chat waits on you or finishes, \(OrchestratorTriage.modelTitle) reads the end of it through your Claude Code sign-in and writes the Brief on Home: what it needs and, when a short reply would unblock it, a draft you can send, edit or discard. Nothing is sent without your click. Chats that stop close together go in one run of up to five. It never runs more than 30 times an hour, and pauses itself while Claude's session limit has under 15% left or the weekly limit under 10%. The morning brief catches up on chats still waiting, once a day on your first visit after 5 am.")
                .font(.caption).foregroundStyle(.secondary)
            Text(brief.footer).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
