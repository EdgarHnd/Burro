// The app store's side of Burro's remote cache. At launch it removes the old one-run media folder,
// tidies old media copies, starts the hourly tidy of transcript copies, deletes folders of machines no longer configured, and shows each enabled
// machine's remembered chats as last seen (never live) until its first probe replaces them; the
// machine's OS and tool versions fill in on the Machines page the same way. Each successful probe is
// saved (only when something changed); removing a machine or changing its address deletes its folder.
// Settings reads each machine's status line and cache size here and can clear the cache.
import Foundation
import BurroCore

extension AppStore {
    func loadRemoteCache() {
        let hosts = remoteHosts
        Task {
            let loaded = await Task.detached(priority: .utility) { () -> [UUID: RemoteHostCache] in
                ChatMedia.removeLegacyCache()
                let values = RemoteCache.shared.loadAll(hosts)
                RemoteCache.shared.sweep(.media)
                return values
            }.value
            startTranscriptMirrorSweeps()
            var changed = false
            for host in remoteHosts where host.enabled {
                guard let cached = loaded[host.id], cached.matches(host) else { continue }
                if let facts = cached.facts, machines.facts[host.id.uuidString] == nil { machines.facts[host.id.uuidString] = facts.machineFacts }
                // A probe that already answered wins.
                guard remoteSnapshots[host.id] == nil, cached.sampledAt != nil else { continue }
                remoteSnapshots[host.id] = cached.snapshot(for: host)
                changed = true
            }
            if changed { rebuildAgentActivity() }
        }
    }

    func saveRemoteCache(_ snapshot: RemoteHostSnapshot) {
        Task.detached(priority: .utility) { RemoteCache.shared.saveProbe(snapshot) }
    }

    func forgetRemoteCache(_ id: UUID) {
        Task.detached(priority: .utility) { RemoteCache.shared.remove(hostID: id) }
    }

    /// "Connected · checked 12 s ago", "Unreachable since 14:02 · retrying in 30 s", "Paused", …
    func remoteStatusLine(for host: RemoteHost, now: Date = Date()) -> String {
        RemoteStatusLine.text(snapshot: connection(for: host), poll: remotePollStatus(host.id),
                              peer: TailscalePeer.matching(host.destination, in: machines.peers ?? []), now: now)
    }

    /// Bytes cached per machine. Slow-ish (walks folders): runs off the main thread.
    func remoteCacheUsage() async -> [UUID: Int64] {
        let ids = remoteHosts.map(\.id)
        return await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: ids.map { ($0, RemoteCache.shared.usage(hostID: $0)) })
        }.value
    }

    /// Clears one machine's cache, or every machine's. Chats already on screen stay until the next probe.
    func clearRemoteCache(_ id: UUID?) async {
        await Task.detached(priority: .utility) {
            if let id { RemoteCache.shared.clear(hostID: id) } else { RemoteCache.shared.clearAll() }
        }.value
    }
}
