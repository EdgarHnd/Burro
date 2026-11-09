// The Machines page: every machine you work on (this Mac, SSH machines, Tailscale devices) and a
// table of agent tools per machine with their versions and one-click updates.
import SwiftUI
import BurroCore

struct MachineModel: Identifiable {
    enum Kind { case local, ssh, tailnet }
    var id: String
    var name: String
    var kind: Kind
    var os: String?
    var online: Bool?
    var running: Int
    var waiting: Int
    var roots: [String]
    var peer: TailscalePeer?
    var host: RemoteHost?
    var lastSeen: Date?
    var detail: String?
}

struct MachinesView: View {
    @Bindable var store: AppStore
    @State private var onScreen = false
    @State private var editing: RemoteHost?
    @State private var pendingUpdate: (harness: Harness, machine: MachineModel)?
    private var machines: MachinesStore { store.machines }

    var body: some View {
        let models = MachinesModel.build(store: store)
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("MACHINES").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
                        Text("\(models.count)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 1).background(AppAppearance.raised, in: Capsule())
                            .foregroundStyle(AppAppearance.secondary)
                        Spacer()
                        PillButton(title: "Add", symbol: "plus") { editing = RemoteHost(name: "", destination: "") }
                            .help("Add a machine you can reach over SSH")
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 16, alignment: .top)], spacing: 16) {
                        ForEach(models) { model in
                            MachineCard(model: model, facts: machines.facts[model.id], probing: machines.probing.contains(model.id),
                                        addOverSSH: { editing = RemoteHost(name: model.name, destination: model.peer?.dnsName ?? model.name) },
                                        showSessions: { store.page = .remote })
                        }
                    }
                    if !machines.tailscaleInstalled {
                        Text("Install Tailscale to see every device on your tailnet here.").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                    }
                }
                HarnessTable(store: store, machines: models.filter { $0.kind != .tailnet || $0.host != nil }) { harness, machine in
                    pendingUpdate = (harness, machine)
                }
                if let message = machines.message {
                    HStack {
                        Label(message, systemImage: "info.circle").font(.system(size: 12))
                        Spacer()
                        Button { machines.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.foregroundStyle(AppAppearance.secondary)
                }
            }
            .padding(.horizontal, 36).padding(.vertical, 28)
            .frame(maxWidth: 1240).frame(maxWidth: .infinity)
        }
        .background(AppAppearance.background)
        .background(WindowOcclusionReader { onScreen = $0 })
        .task(id: onScreen) {
            while onScreen && !Task.isCancelled {
                machines.refresh(hosts: store.remoteHosts)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .sheet(item: $editing) { host in RemoteHostEditor(host: host) { store.saveRemoteHost($0) } }
        .confirmationDialog(pendingUpdate.map { "Update \($0.harness.title) on \($0.machine.name)?" } ?? "",
                            isPresented: Binding(get: { pendingUpdate != nil }, set: { if !$0 { pendingUpdate = nil } }),
                            titleVisibility: .visible) {
            Button("Update") {
                if let pending = pendingUpdate { machines.update(pending.harness, machineID: pending.machine.id, host: pending.machine.host) }
                pendingUpdate = nil
            }
            Button("Cancel", role: .cancel) { pendingUpdate = nil }
        } message: {
            Text(pendingUpdate.map { "Runs `\($0.harness.command) \(($0.harness.updateArguments ?? []).joined(separator: " "))`\($0.machine.kind == .local ? "" : " over SSH"). Running chats keep the version they started with." } ?? "")
        }
    }
}

enum MachinesModel {
    @MainActor static func build(store: AppStore) -> [MachineModel] {
        let summary = store.homeSummary
        let peers = store.machines.peers ?? []
        func matches(_ peer: TailscalePeer, _ destination: String) -> Bool {
            let host = destination.split(separator: "@").last.map(String.init)?.lowercased() ?? destination.lowercased()
            let dns = peer.dnsName?.lowercased()
            return host == peer.hostName.lowercased() || host == dns || dns?.hasPrefix(host + ".") == true
        }
        var models: [MachineModel] = []
        let local = summary.machines.first { $0.connection == .local }
        models.append(MachineModel(id: MachinesStore.localID, name: Host.current().localizedName ?? "This Mac", kind: .local,
                                   os: store.machines.facts[MachinesStore.localID]?.os, online: true,
                                   running: local?.counts.running ?? 0, waiting: local?.counts.waiting ?? 0,
                                   roots: roots(store.repositoriesFound.map(\.path)), peer: peers.first(where: \.isSelf), host: nil,
                                   lastSeen: nil, detail: "This Mac"))
        for host in store.remoteHosts {
            let machine = summary.machines.first { $0.id == host.id.uuidString }
            let peer = peers.first { !$0.isSelf && matches($0, host.destination) }
            let sessions = store.remoteSessions.filter { $0.remote?.hostID == host.id }.map(\.cwd)
            models.append(MachineModel(id: host.id.uuidString, name: host.name, kind: .ssh,
                                       os: store.machines.facts[host.id.uuidString]?.os ?? peer.map { $0.os }, online: machine.map { $0.connection == .online },
                                       running: machine?.counts.running ?? 0, waiting: machine?.counts.waiting ?? 0,
                                       roots: roots(sessions), peer: peer, host: host, lastSeen: machine?.lastSeen,
                                       detail: connection(machine?.connection)))
        }
        for peer in peers where !peer.isSelf && !store.remoteHosts.contains(where: { matches(peer, $0.destination) }) {
            models.append(MachineModel(id: "tailnet:" + peer.id, name: peer.hostName, kind: .tailnet, os: peer.os, online: peer.online,
                                       running: 0, waiting: 0, roots: [], peer: peer, host: nil, lastSeen: peer.lastSeen,
                                       detail: peer.online ? "On your tailnet" : "Offline on your tailnet"))
        }
        return models
    }
    /// The folders projects live in, most common first ("~/Dev"), up to three.
    static func roots(_ paths: [String]) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let parents = paths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        let counts = Dictionary(grouping: parents, by: { $0 }).mapValues(\.count)
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3)
            .map { $0.key.hasPrefix(home) ? "~" + $0.key.dropFirst(home.count) : $0.key }
    }
    static func connection(_ value: HomeMachine.Connection?) -> String {
        switch value {
        case .online: "Online over SSH"; case .offline: "Unreachable"; case .stale: "Status expired"
        case .connecting: "Connecting…"; case .paused: "Paused"; case .local, nil: "SSH"
        }
    }
}

struct PillButton: View {
    var title: String
    var symbol: String
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(hovering ? AppAppearance.raised : AppAppearance.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(AppAppearance.separator))
                .shadow(color: AppAppearance.shadow, radius: 6, y: 2)
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}
