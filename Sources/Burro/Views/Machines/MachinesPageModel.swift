// What the Machines page draws, as plain values, and how it is built from the app store. The page
// itself (`MachinesPage`) takes only these values and an actions bundle, so it can be rendered in
// tests with invented machines. Building reads only what Burro already holds in memory (the chat
// feed, each machine's last probe and poll schedule, the Machines store's facts and local-copy
// totals); it never scans files or opens connections, so it is cheap enough to rebuild on a timer.
import SwiftUI
import BurroCore

struct MachineHarnessRow: Identifiable, Equatable {
    var harness: Harness
    var installed: String
    var latest: String?
    var outdated: Bool
    var canUpdate: Bool
    var updating: Bool
    var id: String { harness.rawValue }
}

struct MachineCardModel: Identifiable {
    enum Reach: Equatable { case local, online, connecting, stale, unreachable, paused }
    var id: String
    var name: String
    var reach: Reach
    /// "macOS 26.2", from the machine's own probe or Tailscale.
    var os: String?
    /// The existing status line ("Connected · checked 8 s ago", "Unreachable since 14:02 · retrying in 30 s").
    var statusLine: String
    var host: RemoteHost?
    var chats: [AgentSession]
    var moreChats: Int
    var counts: MachinesOverview.Counts
    var harnesses: [MachineHarnessRow]
    var probing: Bool
    var cacheBytes: Int64?
    var localCopy: MachinesOverview.LocalCopy?
    var lastError: String?
    var isLocal: Bool { reach == .local }
    /// "Unreachable since 14:02" and "retrying in 30 s · offline on Tailscale since 13:58".
    var statusParts: (head: String, rest: String?) {
        let parts = statusLine.components(separatedBy: " · ")
        return (parts.first ?? statusLine, parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : nil)
    }
}

struct MachinesPageModel {
    var headline: String
    var cards: [MachineCardModel]
    /// Tailscale devices that aren't configured machines.
    var tailnet: [TailscalePeer]
    var tailscaleInstalled: Bool
    var message: String?
    var checking: Bool
    /// Chats on this page with an Attach check running.
    var attaching: Set<String>
}

/// Everything the page can do; each closure is wired to existing store functions by `MachinesView`.
struct MachinesActions {
    var openChat: (AgentSession) -> Void = { _ in }
    var attach: (AgentSession, RemoteHost) -> Void = { _, _ in }
    var showChats: () -> Void = {}
    var newChat: (MachineCardModel) -> Void = { _ in }
    var openTerminal: (MachineCardModel) -> Void = { _ in }
    var update: (Harness, MachineCardModel) -> Void = { _, _ in }
    var clearCache: (MachineCardModel) -> Void = { _ in }
    var retry: (MachineCardModel) -> Void = { _ in }
    var resume: (MachineCardModel) -> Void = { _ in }
    var edit: (MachineCardModel) -> Void = { _ in }
    var forget: (MachineCardModel) -> Void = { _ in }
    var add: (String) -> Void = { _ in }
    var addTailnet: (TailscalePeer) -> Void = { _ in }
    var checkAll: () -> Void = {}
    var dismissMessage: () -> Void = {}
}

enum MachinesPageBuilder {
    @MainActor static func build(store: AppStore, now: Date) -> MachinesPageModel {
        let machines = store.machines
        let sessions = store.agentActivity.sessions
        let peers = machines.peers ?? []
        var cards: [MachineCardModel] = []

        let localChats = MachinesOverview.chats(machine: nil, sessions: sessions)
        cards.append(MachineCardModel(
            id: MachinesStore.localID, name: "This Mac", reach: .local,
            os: machines.facts[MachinesStore.localID]?.os, statusLine: "Online",
            host: nil, chats: localChats.rows, moreChats: localChats.more,
            counts: .of(sessions.filter { $0.remote == nil }),
            harnesses: harnessRows(machines, id: MachinesStore.localID, online: true),
            probing: machines.probing.contains(MachinesStore.localID), cacheBytes: nil, localCopy: nil, lastError: nil))

        var remote: [MachineCardModel] = []
        for host in store.remoteHosts {
            let snapshot = store.connection(for: host)
            let reach: MachineCardModel.Reach
            switch snapshot.state {
            case .disabled: reach = .paused
            case .notChecked: reach = .connecting
            case .offline: reach = .unreachable
            case .online: reach = snapshot.sampledAt.map { now.timeIntervalSince($0) > RemoteHostSnapshot.freshFor } ?? true ? .stale : .online
            }
            let id = host.id.uuidString
            let peer = TailscalePeer.matching(host.destination, in: peers)
            let chats = MachinesOverview.chats(machine: host.id, sessions: sessions)
            remote.append(MachineCardModel(
                id: id, name: host.name, reach: reach, os: machines.facts[id]?.os ?? peer.map(\.os).flatMap { $0.isEmpty ? nil : $0 },
                statusLine: store.remoteStatusLine(for: host, now: now), host: host,
                chats: chats.rows, moreChats: chats.more, counts: .of(sessions.filter { $0.remote?.hostID == host.id }),
                harnesses: harnessRows(machines, id: id, online: reach == .online),
                probing: machines.probing.contains(id), cacheBytes: machines.cacheBytes[host.id],
                localCopy: machines.localCopies[host.id], lastError: snapshot.error))
        }
        // Unreachable machines go last, as the quieter cards they are.
        cards += remote.filter { $0.reach != .unreachable } + remote.filter { $0.reach == .unreachable }

        let enabled = store.remoteHosts.filter(\.enabled)
        let reachable = 1 + cards.filter { $0.reach == .online }.count
        let headline = MachinesOverview.headline(reachable: reachable, total: 1 + enabled.count, counts: .of(sessions))
        let tailnet = peers.filter { peer in !peer.isSelf && !store.remoteHosts.contains { TailscalePeer.matching($0.destination, in: [peer]) != nil } }
        return MachinesPageModel(headline: headline, cards: cards, tailnet: tailnet, tailscaleInstalled: machines.tailscaleInstalled,
                                 message: machines.message, checking: store.checkingRemotes || !machines.probing.isEmpty,
                                 attaching: machines.attaching)
    }

    @MainActor static func harnessRows(_ machines: MachinesStore, id: String, online: Bool) -> [MachineHarnessRow] {
        guard let facts = machines.facts[id] else { return [] }
        return Harness.allCases.compactMap { harness in
            guard let installed = facts.versions[harness] else { return nil }
            let latest = machines.latest[harness]
            let outdated = latest.map { Harness.isOlder(installed, than: $0) } ?? false
            return MachineHarnessRow(harness: harness, installed: installed, latest: latest, outdated: outdated,
                                     canUpdate: outdated && harness.updateArguments != nil && online,
                                     updating: machines.updating.contains(id + ":" + harness.rawValue))
        }
    }
}
