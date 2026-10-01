// A serialized cleanup queue projects optimistic rows while retaining per-item recovery results.
import Foundation
import Observation
import BurroCore

struct CleanupRequest: Identifiable {
    let id = UUID()
    let trees: [Worktree]
}
struct CleanupItem: Identifiable {
    enum State {
        case queued, moving, moved(URL), failed(String), skipped
    }
    let tree: Worktree
    var state: State = .queued
    var id: String { tree.id }
}
@MainActor @Observable final class CleanupBatchStore {
    typealias Remove = @Sendable (Worktree, ScanConfiguration) async throws -> URL
    private(set) var items: [CleanupItem] = []
    private(set) var hiddenPaths: Set<String> = []
    private(set) var isRunning = false
    @ObservationIgnored private var executing = false
    @ObservationIgnored private let remove: Remove

    init(remove: Remove? = nil) {
        let service = WorktreeCleanup()
        self.remove = remove ?? { tree, config in try await service.remove(tree, configuration: config) }
    }
    @discardableResult func begin(_ trees: [Worktree]) -> Bool {
        guard !isRunning, hiddenPaths.isEmpty, !trees.isEmpty else { return false }
        var seen: Set<String> = []
        items = trees.filter { seen.insert($0.id).inserted }.map { CleanupItem(tree: $0) }
        hiddenPaths = Set(items.map(\.id)); isRunning = true
        return true
    }
    func run(configuration: ScanConfiguration) async {
        guard isRunning, !executing else { return }
        executing = true
        defer { executing = false; isRunning = false }
        for index in items.indices {
            guard case .queued = items[index].state else { continue }
            let tree = items[index].tree
            items[index].state = .moving
            do { items[index].state = .moved(try await remove(tree, configuration)) }
            catch {
                items[index].state = .failed(error.localizedDescription)
                hiddenPaths.remove(tree.id)
            }
        }
    }
    func stopRemaining() {
        for index in items.indices where isQueued(items[index]) {
            items[index].state = .skipped
            hiddenPaths.remove(items[index].id)
        }
    }
    // Only a scan started after the batch can retire the optimistic projection.
    func settle() { if !isRunning { hiddenPaths = [] } }
    func dismiss() { guard !isRunning, hiddenPaths.isEmpty else { return }; items = [] }
    var movedCount: Int { items.filter { if case .moved = $0.state { true } else { false } }.count }
    var failedCount: Int { items.filter { if case .failed = $0.state { true } else { false } }.count }
    var skippedCount: Int { items.filter { if case .skipped = $0.state { true } else { false } }.count }
    var queuedCount: Int { items.filter(isQueued).count }
    var current: CleanupItem? { items.first { if case .moving = $0.state { true } else { false } } }
    var summary: String {
        if isRunning && items.count == skippedCount { return "Finishing cleanup…" }
        if isRunning { return "Moving \(movedCount + failedCount + 1) of \(items.count - skippedCount) to Trash…" }
        var parts: [String] = []
        if movedCount > 0 { parts.append("\(movedCount) moved to Trash") }
        if failedCount > 0 { parts.append("\(failedCount) need attention") }
        if skippedCount > 0 { parts.append("\(skippedCount) skipped") }
        return parts.joined(separator: " · ")
    }
    func failure(for path: String) -> String? {
        guard let item = items.first(where: { $0.id == path }), case .failed(let reason) = item.state else { return nil }
        return reason
    }
    private func isQueued(_ item: CleanupItem) -> Bool { if case .queued = item.state { true } else { false } }
}
