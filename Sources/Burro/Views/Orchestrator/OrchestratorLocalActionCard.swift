// A to-do the orchestrator added or ticked off, shown under the turn that did it: one quiet line,
// "Added to-do … · Undo" or "Completed … · Undo". Burro has already applied it; Undo reverses it
// for a day. A change that couldn't be applied says why.
import SwiftUI
import BurroCore

struct OrchestratorLocalActionCard: View {
    var store: AppStore
    var action: OrchestratorAction
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: action.kind == .addTodo ? "checklist" : "checkmark.circle")
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(AppAppearance.tertiary).frame(width: 16)
            Text(action.headline).font(.system(size: 12.5)).foregroundStyle(action.status == .undone ? AppAppearance.tertiary : AppAppearance.secondary)
                .lineLimit(1)
            if let error = action.error {
                Text("· " + error).font(.system(size: 12)).foregroundStyle(AppAppearance.amber).lineLimit(1)
            } else if action.status == .pending {
                Text("· applying…").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
            }
            Spacer(minLength: 6)
            if action.canUndo() && action.error == nil {
                Button("Undo") { store.orchestrator.undo(action) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                    .help(action.kind == .addTodo ? "Remove this to-do" : "Mark this to-do as not done")
            }
        }
        .padding(.horizontal, 12).frame(height: 34)
        .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AppAppearance.separator))
    }
}
