// Machine cards and the harness version table.
import SwiftUI
import BurroCore

struct MachineCard: View {
    var model: MachineModel
    var facts: MachineFacts?
    var probing: Bool
    var addOverSSH: () -> Void
    var showSessions: () -> Void
    @State private var softwareOpen = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                .foregroundStyle(tint).frame(width: 46, height: 46)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(model.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text([model.os ?? (probing ? "Checking…" : nil), presence].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).lineLimit(2)
                if model.running + model.waiting > 0 || model.kind != .tailnet {
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(statusLine).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                    }
                }
                if !model.roots.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.roots, id: \.self) { root in
                            Text(root).font(.system(size: 11, design: .monospaced)).foregroundStyle(AppAppearance.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                    }.padding(.top, 2)
                }
                HStack(spacing: 6) {
                    if model.peer != nil { tag("Tailscale") }
                    if model.host != nil { tag("SSH") }
                }.padding(.top, 2)
                if let facts, !facts.versions.isEmpty {
                    DisclosureGroup(isExpanded: $softwareOpen) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Harness.allCases.filter { facts.versions[$0] != nil }) { harness in
                                HStack {
                                    Text(harness.title); Spacer()
                                    Text(facts.versions[harness] ?? "").font(.system(size: 11, design: .monospaced))
                                }.font(.system(size: 11)).foregroundStyle(AppAppearance.secondary)
                            }
                        }.padding(.top, 4)
                    } label: {
                        Text("Software · \(facts.versions.count) tool\(facts.versions.count == 1 ? "" : "s")").font(.system(size: 12))
                            .foregroundStyle(AppAppearance.secondary)
                    }
                }
                if model.kind == .tailnet {
                    Button("Add over SSH", action: addOverSSH).buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppAppearance.blue).padding(.top, 2)
                        .help("Monitor this device's Codex and Claude sessions over SSH (needs an SSH login from this Mac)")
                } else if model.kind == .ssh {
                    Button("Sessions", action: showSessions).buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppAppearance.blue).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .modifier(AppCardSurface(radius: 18))
    }
    private var symbol: String {
        let os = (model.os ?? model.peer?.os ?? "").lowercased()
        if model.kind == .local { return "laptopcomputer" }
        if os.contains("ios") || os.contains("iphone") { return "iphone" }
        if os.contains("android") { return "candybarphone" }
        if os.contains("macos") { return "desktopcomputer" }
        return "server.rack"
    }
    private var tint: Color {
        if model.kind == .local { return AppAppearance.green }
        if model.online == false { return AppAppearance.tertiary }
        let os = (model.os ?? model.peer?.os ?? "").lowercased()
        return os.contains("linux") || os.contains("ubuntu") || os.contains("debian") ? .purple : AppAppearance.blue
    }
    private var presence: String? {
        if model.kind == .local { return "Online" }
        if model.online == true { return "Online" }
        if let seen = model.lastSeen { return "Seen \(HomeFormat.ago(seen))" }
        return model.online == false ? "Offline" : nil
    }
    private var statusColor: Color {
        model.waiting > 0 ? AppAppearance.amber : (model.running > 0 ? AppAppearance.green : (model.online == false ? AppAppearance.tertiary : AppAppearance.green.opacity(0.5)))
    }
    private var statusLine: String {
        var parts: [String] = []
        if model.waiting > 0 { parts.append("\(model.waiting) need\(model.waiting == 1 ? "s" : "") you") }
        if model.running > 0 { parts.append("\(model.running) running") }
        if parts.isEmpty { parts.append(model.detail ?? "Quiet") }
        return parts.joined(separator: " · ")
    }
    private func tag(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
            .padding(.horizontal, 7).padding(.vertical, 2).background(AppAppearance.raised, in: Capsule())
    }
}

struct HarnessTable: View {
    var store: AppStore
    var machines: [MachineModel]
    var requestUpdate: (Harness, MachineModel) -> Void

    var body: some View {
        let facts = store.machines.facts
        let columns = machines.filter { facts[$0.id] != nil }
        let harnesses = Harness.allCases.filter { harness in columns.contains { facts[$0.id]?.versions[harness] != nil } }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(AppAppearance.tertiary)
                Text("Harnesses").font(.system(size: 16, weight: .semibold))
                Spacer()
                if !store.machines.probing.isEmpty { ProgressView().controlSize(.small) }
            }
            if columns.isEmpty {
                HomeEmptyCard(symbol: "terminal", title: "Checking installed tools…", detail: "Burro asks each machine for its agent CLI versions.") { EmptyView() }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        header("HARNESS")
                        ForEach(columns) { header($0.name.uppercased()) }
                    }
                    ForEach(harnesses) { harness in
                        Divider().overlay(AppAppearance.separator).gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            HStack(spacing: 8) {
                                Text(harness.title).font(.system(size: 13, weight: .semibold))
                                if let latest = store.machines.latest[harness] {
                                    Text("latest \(latest)").font(.system(size: 11, design: .monospaced)).foregroundStyle(AppAppearance.tertiary)
                                }
                            }.padding(.horizontal, 18).padding(.vertical, 13).frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(columns) { machine in cell(harness, machine) }
                        }
                    }
                }
                .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(AppAppearance.separator))
                .shadow(color: AppAppearance.shadow, radius: 8, y: 2)
                Text("Versions are read on each machine with the tool's own --version; latest releases come from npm. Update runs the tool's own updater after you confirm.")
                    .font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
            }
        }
    }
    private func header(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(AppAppearance.tertiary)
            .padding(.horizontal, 18).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func cell(_ harness: Harness, _ machine: MachineModel) -> some View {
        let installed = store.machines.facts[machine.id]?.versions[harness]
        let latest = store.machines.latest[harness]
        let outdated = installed.flatMap { i in latest.map { Harness.isOlder(i, than: $0) } } ?? false
        let busy = store.machines.updating.contains(machine.id + ":" + harness.rawValue)
        HStack(spacing: 8) {
            Circle().fill(installed == nil ? AppAppearance.tertiary.opacity(0.5) : (outdated ? AppAppearance.amber : AppAppearance.green))
                .frame(width: 7, height: 7)
            Text(installed ?? "—").font(.system(size: 12, design: .monospaced))
                .foregroundStyle(installed == nil ? AppAppearance.tertiary : AppAppearance.text)
            if busy { ProgressView().controlSize(.mini) }
            else if outdated, harness.updateArguments != nil, machine.online != false {
                Button { requestUpdate(harness, machine) } label: {
                    Label("Update", systemImage: "arrow.up.circle").font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(AppAppearance.blue.opacity(0.1), in: Capsule()).foregroundStyle(AppAppearance.blue)
                }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 18).padding(.vertical, 13).frame(maxWidth: .infinity, alignment: .leading)
    }
}
