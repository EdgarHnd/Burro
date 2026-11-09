// State for the Machines page: Tailscale peers, each machine's OS and tool versions, and the
// latest releases. Work runs only while the page is on screen: Tailscale every refresh,
// versions at most every ten minutes per machine, npm at most every six hours.
import Foundation
import Observation
import BurroCore

@MainActor @Observable final class MachinesStore {
    var peers: [TailscalePeer]?
    var facts: [String: MachineFacts] = [:]
    var latest: [Harness: String] = [:]
    private(set) var probing: Set<String> = []
    private(set) var updating: Set<String> = []
    var message: String?
    let tailscaleInstalled = Tailscale.executable() != nil
    @ObservationIgnored private var latestAt: Date?
    @ObservationIgnored private var peersTask: Task<Void, Never>?

    static let localID = "local"

    func refresh(hosts: [RemoteHost], force: Bool = false) {
        if tailscaleInstalled && peersTask == nil {
            peersTask = Task {
                let peers = await Task.detached(priority: .utility) { Tailscale.peers() }.value
                if let peers { self.peers = peers }
                peersTask = nil
            }
        }
        probe(Self.localID, host: nil, force: force)
        for host in hosts where host.enabled { probe(host.id.uuidString, host: host, force: force) }
        if force || latestAt.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true {
            latestAt = Date()
            Task { let found = await HarnessReleases.latest(); if !found.isEmpty { latest = found } }
        }
    }

    private func probe(_ id: String, host: RemoteHost?, force: Bool) {
        guard !probing.contains(id) else { return }
        if !force, let checked = facts[id]?.checkedAt, Date().timeIntervalSince(checked) < 600 { return }
        probing.insert(id)
        Task {
            let result = await Task.detached(priority: .utility) { host.map(MachineProbe.remote) ?? MachineProbe.local() }.value
            if let result { facts[id] = result }
            probing.remove(id)
        }
    }

    /// Runs the tool's own updater after the user confirmed, then re-checks that machine.
    func update(_ harness: Harness, machineID: String, host: RemoteHost?) {
        let key = machineID + ":" + harness.rawValue
        guard !updating.contains(key) else { return }
        updating.insert(key)
        Task {
            do {
                let last = try await Task.detached(priority: .userInitiated) { try HarnessUpdate.run(harness, on: host) }.value
                message = "\(harness.title) updated\(last.isEmpty ? "." : ": \(last.prefix(120))")"
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? "\(harness.title) didn't update."
            }
            updating.remove(key)
            probe(machineID, host: host, force: true)
        }
    }
}
