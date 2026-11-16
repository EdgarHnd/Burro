// Home's Machines card in the right column: one line per machine (this Mac first, then each one
// you added): a dot (green when Burro can reach it, grey when not), its name, and its counts
// with the machine's own status line ("2 working · 1 needs you", "1 working · checked 8 s ago",
// "Unreachable since 14:02 · retrying in 30 s"; HomeBoard.machineLine). Click this Mac for Mac
// Health, another machine for Machines. It replaces the old grid of machine cards; nothing here
// probes a machine: the status comes from the checks Burro already runs.
import SwiftUI
import BurroCore

struct HomeMachineRowData: Identifiable, Equatable {
    var id: String
    var name: String
    var reachable: Bool
    var line: String
    var local: Bool
}

struct HomeMachinesCardContent: View {
    var rows: [HomeMachineRowData]
    var open: (HomeMachineRowData) -> Void = { _ in }
    var openAll: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HomeSectionLabel(title: "Machines") {
                Button(action: openAll) {
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(AppAppearance.tertiary)
                .help("Open Machines").accessibilityLabel("Open Machines")
            }
            .padding(.bottom, 2)
            ForEach(rows) { row in HomeMachineRow(row: row) { open(row) } }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(HomeCardSurface())
    }
}

private struct HomeMachineRow: View {
    var row: HomeMachineRowData
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(row.reachable ? AppAppearance.green : AppAppearance.tertiary).frame(width: 8, height: 8).padding(.top, 5)
                Text(row.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppAppearance.text).lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Text(row.line).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(AppAppearance.secondary)
                    .lineLimit(2).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(hovering ? AppAppearance.hover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, -6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .help(row.local ? "Open Mac Health" : "\(row.name): \(row.line). Open Machines")
        .accessibilityLabel("\(row.name), \(row.reachable ? "reachable" : "not reachable"), \(row.line)")
    }
}

/// The card on the live store.
struct HomeMachinesCard: View {
    var store: AppStore
    var summary: HomeSummary

    var body: some View {
        HomeMachinesCardContent(rows: rows, open: { row in store.page = row.local ? .health : .machines },
                                openAll: { store.page = .machines })
    }

    private var rows: [HomeMachineRowData] {
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
