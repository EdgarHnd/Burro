// The Orchestrator page's right column. Memory: the first standing notes it reads every turn
// (global ones, then the main project's), a field that adds a global note on Return, and "All N",
// which opens the Memory tab to edit or delete them. Budget: triage runs today of the daily cap,
// what today's runs cost (the Orchestrator's own and triage's, from the runs log), Claude's session
// and weekly windows as meters with when they reset (amber once below the floor where triage
// pauses; hidden while Burro doesn't know them), the floors in words, why triage is paused if it
// is, and the switch that turns automatic triage on or off (the same switch as Settings).
import SwiftUI
import BurroCore

struct OrchestratorMemoryCard: View {
    @Bindable var store: AppStore
    var openMemory: () -> Void
    @State private var draft = ""

    var body: some View {
        let entries = store.orchestrator.memory
        let shown = OrchestratorMemory.preview(entries, mainProject: store.mainProject?.path)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                OrchSectionLabel(title: "Memory", dot: nil)
                Spacer(minLength: 6)
                Button(entries.isEmpty ? "Open" : "All \(entries.count)", action: openMemory)
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                    .help("Edit or delete notes on the Memory tab")
            }
            if shown.isEmpty {
                Text("No notes yet. Add one it should always keep in mind.").font(.system(size: 12.5)).foregroundStyle(AppAppearance.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(shown) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("·").foregroundStyle(AppAppearance.tertiary).accessibilityHidden(true)
                    Text(entry.text).font(.system(size: 13)).foregroundStyle(AppAppearance.text).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            TextField("Add a standing note", text: $draft)
                .textFieldStyle(.plain).font(.system(size: 12))
                .modifier(OrchField())
                .padding(.top, 4)
                .onSubmit(add)
                .accessibilityLabel("Add a standing note")
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(OrchCard())
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.orchestrator.addMemory(text)
        draft = ""
    }
}

struct OrchestratorBudgetCard: View {
    var budget: OrchestratorBudget
    @Binding var enabled: Bool
    var now: Date
    var calendar: Calendar = .current

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                OrchSectionLabel(title: "Budget", dot: nil)
                Spacer(minLength: 6)
                Text(enabled ? "On" : "Off").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(enabled ? AppAppearance.green : AppAppearance.tertiary)
                Toggle("Automatic triage", isOn: $enabled)
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(AppAppearance.green)
                    .accessibilityLabel("Orchestrator triage")
                    .help(enabled ? "Turn automatic triage off" : "Turn automatic triage on (\(OrchestratorTriage.modelTitle), at most \(budget.cap) runs a day)")
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Triage runs today").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(budget.runsToday)").font(.system(size: 22, weight: .bold)).monospacedDigit()
                        Text("of \(budget.cap)").font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cost today").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                    Text(budget.cost).font(.system(size: 22, weight: .bold)).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("What Claude Code reports for today's Orchestrator and triage runs, at API prices. On a subscription they count toward your usage windows instead.")
            }
            if budget.session == nil && budget.weekly == nil {
                Text("Claude's usage windows aren't known yet, so triage runs on the caps alone.")
                    .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach([budget.session, budget.weekly].compactMap { $0 }, id: \.title) { meter in meterView(meter) }
            if let reason = budget.pausedReason, enabled {
                Label(reason, systemImage: "pause.circle").font(.system(size: 12)).foregroundStyle(AppAppearance.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(budget.floorsLine).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(OrchCard())
    }

    private func meterView(_ meter: OrchestratorBudget.Meter) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(meter.title).font(.system(size: 12)).foregroundStyle(AppAppearance.text)
                Spacer(minLength: 6)
                Text(meter.left).font(.system(size: 12)).monospacedDigit().foregroundStyle(meter.paused ? AppAppearance.amber : AppAppearance.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppAppearance.raised)
                    Capsule().fill(meter.paused ? AppAppearance.amber : AppAppearance.green)
                        .frame(width: max(0, proxy.size.width * meter.remaining / 100))
                }
            }
            .frame(height: 6)
            .accessibilityElement().accessibilityLabel("\(meter.title), \(meter.left)")
            if let reset = meter.resetText(now: now, calendar: calendar) {
                Text(reset).font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
            }
        }
    }
}
