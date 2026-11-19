// The Orchestrator page's Memory tab: the standing notes it is given every turn, global ones first,
// then per project, each marked as yours or noted by it. Add a note, edit one in place, or delete it.
// One panel on a joined surface; the page scrolls it and reloads the notes when the tab opens.
import SwiftUI
import BurroCore

struct OrchestratorMemoryView: View {
    @Bindable var store: AppStore
    @State private var draft = ""
    @State private var scope = OrchestratorMemoryEntry.global
    var body: some View {
        let orchestrator = store.orchestrator
        let entries = orchestrator.memory
        let scopes = [OrchestratorMemoryEntry.global] + Array(Set(entries.map(\.scope).filter { $0 != OrchestratorMemoryEntry.global })).sorted()
        JoinedPanels {
            Panel(title: entries.isEmpty ? "Memory" : "Memory · \(entries.count) notes",
                  subtitle: [TextRun("Notes it reads at the start of every answer: global ones, then your main project's. It can add its own with “remember”; you can change or delete any of them.")]) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 8) {
                    TextField("Add a note, e.g. “Prefer small PRs”", text: $draft)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(AppAppearance.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AppAppearance.separator))
                        .onSubmit(add)
                    Picker("", selection: $scope) {
                        Text("Global").tag(OrchestratorMemoryEntry.global)
                        if let main = store.mainProject { Text(main.name).tag(main.path) }
                    }
                    .labelsHidden().fixedSize()
                    PillButton(title: "Add", symbol: "plus") { add() }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if entries.isEmpty {
                    Text("No notes yet.").font(.system(size: 12.5)).foregroundStyle(AppAppearance.tertiary)
                }
                ForEach(scopes.filter { scope in entries.contains { $0.scope == scope } }, id: \.self) { scope in
                    VStack(alignment: .leading, spacing: 0) {
                        Text((scope == OrchestratorMemoryEntry.global ? "Global" : URL(fileURLWithPath: scope).lastPathComponent).uppercased())
                            .font(.system(size: 10.5, weight: .semibold)).tracking(0.7).foregroundStyle(AppAppearance.tertiary).padding(.bottom, 4)
                        ForEach(Array(entries.filter { $0.scope == scope }.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { QueueRule() }
                            MemoryRow(store: store, entry: entry)
                        }
                    }
                }
            }
            }
        }
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.orchestrator.addMemory(text, scope: scope)
        draft = ""
    }
}

private struct MemoryRow: View {
    var store: AppStore
    var entry: OrchestratorMemoryEntry
    @State private var editing = false
    @State private var text = ""
    @State private var hovering = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if editing {
                TextField("Note", text: $text, axis: .vertical).textFieldStyle(.plain).font(.system(size: 13))
                    .onSubmit(save)
                Button("Save", action: save).buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                Button("Cancel") { editing = false }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
            } else {
                Text(entry.text).font(.system(size: 13)).foregroundStyle(AppAppearance.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.source == .user ? "you" : "noted by it").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
                if hovering {
                    Button { text = entry.text; editing = true } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain).foregroundStyle(AppAppearance.secondary).help("Edit")
                    Button { store.orchestrator.deleteMemory(entry.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(AppAppearance.secondary).help("Delete")
                }
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func save() {
        store.orchestrator.editMemory(entry.id, text: text)
        editing = false
    }
}
