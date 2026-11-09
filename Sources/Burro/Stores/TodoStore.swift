// Today's to-dos: instant local edits, a persistent queue, and a sync with Maurice's Convex
// backend when one is set up. Without sync the list lives on this Mac and uploads later.
// Syncs only after a change or while Home is on screen; there is no timer of its own.
import AppKit
import Foundation
import Observation
import BurroCore

@MainActor @Observable final class TodoStore {
    enum SyncState: Equatable {
        case localOnly
        case syncing
        case synced(Date)
        case offline(String)
        case failed(String)
    }
    private(set) var items: [TodoItem] = []
    private(set) var state: SyncState = .localOnly
    private(set) var config: ConvexConfig?
    var message: String?

    @ObservationIgnored private var base: [TodoItem] = []
    @ObservationIgnored private var pending: [TodoOp] = []
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private let remote: (ConvexConfig) -> TodoRemote
    @ObservationIgnored private let now: () -> Date

    init(cacheURL: URL = TodoStore.defaultCacheURL, config: ConvexConfig? = ConvexCredentials.load(),
         remote: @escaping (ConvexConfig) -> TodoRemote = { TodoRemote(client: ConvexClient(config: $0)) },
         now: @escaping () -> Date = Date.init) {
        self.cacheURL = cacheURL; self.config = config; self.remote = remote; self.now = now
        loadCache()
        state = config == nil ? .localOnly : .syncing
        rebuild()
    }
    static var defaultCacheURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Burro/todos.json")
    }

    var openCount: Int { items.filter { !$0.done }.count }
    var hasUnsyncedChanges: Bool { !pending.isEmpty }

    // MARK: Editing
    func add(_ text: String, project: String? = nil) {
        guard let clean = TodoLedger.clean(text) else { return }
        change(.add(clientId: UUID().uuidString.lowercased(), text: clean, day: TodoDay.key(now()), project: project))
    }
    func toggle(_ item: TodoItem) { change(.setDone(id: item.id, done: !item.done)) }
    func edit(_ item: TodoItem, text: String) {
        guard let clean = TodoLedger.clean(text), clean != item.text else { return }
        change(.edit(id: item.id, text: clean))
    }
    func remove(_ item: TodoItem) { change(.remove(id: item.id)) }

    private func change(_ op: TodoOp) {
        pending = TodoLedger.enqueue(op, into: pending)
        rebuild(); saveCache()
        sync()
    }

    // MARK: Connection
    func connect(_ config: ConvexConfig) async -> Bool {
        do {
            _ = try await remote(config).today(day: TodoDay.key(now()), doneSince: TodoDay.startMillis(now()))
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "Couldn't connect to Convex."
            return false
        }
        guard ConvexCredentials.save(config) else { message = "Couldn't save the token to your Keychain."; return false }
        self.config = config; message = nil
        sync()
        return true
    }
    func importFromMaurice() async -> Bool {
        guard let text = try? String(contentsOf: ConvexCredentials.mauriceSecrets, encoding: .utf8),
              let config = ConvexConfig.parseXcconfig(text) else {
            message = "Couldn't find CONVEX_URL and EDGAR_API_TOKEN in ~/Dev/maurice-app/Config/Secrets.xcconfig."
            return false
        }
        return await connect(config)
    }
    func disconnect() {
        ConvexCredentials.clear()
        config = nil; state = .localOnly
    }

    // MARK: Sync
    /// Uploads queued changes in order, then reloads today's list. Concurrent requests coalesce.
    func sync() {
        guard let config else { state = .localOnly; return }
        if syncTask != nil { syncAgain = true; return }
        state = .syncing
        let remote = remote(config)
        syncTask = Task { [weak self] in
            await self?.runSync(remote)
            guard let self else { return }
            self.syncTask = nil
            if self.syncAgain { self.syncAgain = false; self.sync() }
        }
    }
    private func runSync(_ remote: TodoRemote) async {
        while let op = pending.first {
            do {
                let id = try await remote.perform(op)
                pending.removeFirst()
                if case .add(let clientId, _, _, _) = op, let id {
                    let local = TodoLedger.localPrefix + clientId
                    pending = TodoLedger.remap(pending, from: local, to: id)
                }
                saveCache()
            } catch let error as ConvexClientError where error.isRetryable {
                state = .offline(error.errorDescription ?? "Offline"); return
            } catch {
                // A refusal won't succeed on retry: drop that change and say why.
                pending.removeFirst()
                message = (error as? LocalizedError)?.errorDescription ?? "A to-do change was rejected."
                saveCache()
                if case ConvexClientError.unauthorized = error { state = .failed(message ?? ""); return }
            }
        }
        do {
            base = try await remote.today(day: TodoDay.key(now()), doneSince: TodoDay.startMillis(now()))
            state = .synced(now())
        } catch let error as ConvexClientError where error.isRetryable {
            state = .offline(error.errorDescription ?? "Offline")
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? "Sync failed")
        }
        rebuild(); saveCache()
    }

    private func rebuild() {
        let date = now()
        items = TodoLedger.view(base: base, pending: pending, day: TodoDay.key(date),
                                doneSince: TodoDay.startMillis(date), now: (date.timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: Cache
    private struct Cache: Codable { var base: [TodoItem]; var pending: [TodoOp] }
    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        base = cache.base; pending = cache.pending
    }
    private func saveCache() {
        // Without sync the queue is the only copy of local to-dos, so it is saved on every change.
        guard let data = try? JSONEncoder().encode(Cache(base: base, pending: pending)) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
