// Home's Machines panel (the bottom row's first): one line per machine (this Mac first, then each
// one you added): a dot (green when Burro can reach it, grey when not), its name, and its counts
// with the machine's own status line ("2 working · 1 needs you", "1 working · checked 8 s ago",
// "Unreachable since 14:02 · retrying in 30 s"; HomeBoard.machineLine), grey when unreachable (no
// red). Click this Mac for Mac Health, another machine for Machines; the panel's arrow opens
// Machines. Nothing here probes a machine: the status comes from the checks Burro already runs.
import SwiftUI
import BurroCore

struct HomeMachineRowData: Identifiable, Equatable {
    var id: String
    var name: String
    var reachable: Bool
    var line: String
    var local: Bool
}

/// The rows, for a `Panel`.
struct HomeMachineRows: View {
    var rows: [HomeMachineRowData]
    var open: (HomeMachineRowData) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in HomeMachineRow(row: row) { open(row) } }
        }
    }

    /// "2 of 3 reachable", "This Mac".
    static func subtitle(_ rows: [HomeMachineRowData]) -> String {
        guard rows.count > 1 else { return rows.isEmpty ? "None yet" : "This Mac" }
        let reachable = rows.filter(\.reachable).count
        return reachable == rows.count ? "All \(rows.count) reachable" : "\(reachable) of \(rows.count) reachable"
    }

    /// The machines from what Burro already knows (no probe).
    @MainActor static func rows(store: AppStore, summary: HomeSummary) -> [HomeMachineRowData] {
        let now = Date()
        return summary.machines.map { machine in
            let local = machine.connection == .local
            let host = local ? nil : store.remoteHosts.first { $0.id.uuidString == machine.id }
            let status = host.map { store.remoteStatusLine(for: $0, now: now) }
            return HomeMachineRowData(id: machine.id, name: machine.name, reachable: local || machine.connection == .online,
                                      line: HomeBoard.machineLine(counts: machine.counts, status: local ? nil : (status ?? "Not checked yet")),
                                      local: local)
        }
    }
}

/// The panel's arrow: opens Machines.
struct HomePanelLink: View {
    var help: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(AppAppearance.tertiary)
        .help(help).accessibilityLabel(help)
    }
}

private struct HomeMachineRow: View {
    var row: HomeMachineRowData
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(row.reachable ? AppAppearance.green : AppAppearance.tertiary).frame(width: 7, height: 7).padding(.top, 5)
                Text(row.name).font(.system(size: 13, weight: .medium)).foregroundStyle(row.reachable ? AppAppearance.text : AppAppearance.secondary)
                    .lineLimit(1).layoutPriority(1)
                Spacer(minLength: 8)
                Text(row.line).font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(row.reachable ? AppAppearance.secondary : AppAppearance.tertiary)
                    .lineLimit(2).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .background(hovering ? AppAppearance.hover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, -6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .help(row.local ? "Open Mac Health" : "\(row.name): \(row.line). Open Machines")
        .accessibilityLabel("\(row.name), \(row.reachable ? "reachable" : "not reachable"), \(row.line)")
    }
}
