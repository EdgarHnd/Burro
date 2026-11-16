// State for the Machines page: Tailscale peers, each machine's OS and tool versions, and the
// latest releases. Work runs only while the page is on screen: Tailscale every refresh,
// versions at most every ten minutes per machine, npm at most every six hours. Another machine's
// versions are also kept in Burro's remote cache for when it is asleep.
// It also holds what the page shows about Burro's copies of each machine (cache size, how many chats
// can be read from the transcript copies, read off the main thread while the page is on screen) and
// the page's explicit actions: Attach to a remote Claude background chat (a read-only check of that
// chat on its machine, then the existing Attach), Open SSH and Open in Terminal.
import AppKit
import Foundation
import Observation
import BurroCore

@MainActor @Observable final class MachinesStore {
    var peers: [TailscalePeer]?
    var facts: [String: MachineFacts] = [:]
    var latest: [Harness: String] = [:]
    private(set) var probing: Set<String> = []
    private(set) var updating: Set<String> = []
    /// Bytes Burro keeps for each machine, and what its transcript copies add up to.
    private(set) var cacheBytes: [UUID: Int64] = [:]
    private(set) var localCopies: [UUID: MachinesOverview.LocalCopy] = [:]
    /// Chats with an Attach check running.
    private(set) var attaching: Set<String> = []
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
            // Remembered in that machine's host.json so the Machines page knows it while it sleeps.
            if let result, let host { Task.detached(priority: .utility) { try? RemoteCache.shared.update(host) { $0.facts = RemoteMachineFacts(result) } } }
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

    // MARK: Local copies

    /// Cache size and transcript copies per machine. Walks folders: runs off the main thread.
    func loadLocalCopies(_ hosts: [RemoteHost]) async {
        let ids = hosts.map(\.id)
        let loaded = await Task.detached(priority: .utility) { () -> [UUID: (Int64, MachinesOverview.LocalCopy)] in
            Dictionary(uniqueKeysWithValues: ids.map { id in
                (id, (RemoteCache.shared.usage(hostID: id), MachinesOverview.LocalCopy(entries: RemoteCache.shared.entries(.transcripts, hostID: id))))
            })
        }.value
        cacheBytes = loaded.mapValues(\.0)
        localCopies = loaded.mapValues(\.1)
    }

    // MARK: Explicit actions

    /// Attach on <machine>: asks that machine whether this Claude chat is open as a background
    /// session (read-only) and, when it is, opens the existing Attach command in Terminal.
    func attach(_ session: AgentSession, host: RemoteHost) {
        guard !attaching.contains(session.id) else { return }
        attaching.insert(session.id)
        Task {
            let check = await Task.detached(priority: .userInitiated) { ChatReply.claudeCheck(session, host: host) }.value
            attaching.remove(session.id)
            if check.background, let handle = check.attach {
                message = RemoteAttachOpener.open(host: host, handle: handle)
            } else {
                message = check.problem ?? "\(session.title) isn't open as a background session on \(host.name), so there's nothing to attach to. Open it in Chats instead."
            }
        }
    }

    /// Open SSH: a Terminal window logged in to the machine with the strict options remote monitoring uses.
    func openSSH(_ host: RemoteHost) {
        guard let body = RemoteShell.script(host: host) else { message = "Burro can't open SSH to \(host.name) safely: check its address."; return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-attach")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let script = folder.appendingPathComponent("ssh-\(host.id.uuidString.prefix(8)).command")
        try? FileManager.default.removeItem(at: script)
        guard FileManager.default.createFile(atPath: script.path, contents: Data(body.utf8), attributes: [.posixPermissions: 0o700]) else {
            message = "Couldn't write the Terminal command."; return
        }
        openInTerminal(script)
    }

    /// Open in Terminal on this Mac: a Terminal window in the folder.
    func openTerminal(folder: String) {
        guard FileManager.default.fileExists(atPath: folder) else { message = "That folder isn't there any more."; return }
        openInTerminal(URL(fileURLWithPath: folder, isDirectory: true))
    }

    private func openInTerminal(_ url: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { message = "Terminal isn't available."; return }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}
