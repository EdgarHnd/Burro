// Shared desktop presentation for consistent filters and semantic statuses.
import SwiftUI
import BurroCore

/// Top-level destinations. Home is the landing page; the others open from it, the toolbar or ⌘1–⌘5.
enum AppPage: String, CaseIterable, Identifiable, Hashable {
    case home, today, worktrees, machines, usage, health, remote
    var id: String { rawValue }
    /// Pages in the top bar and ⌘1–⌘6. Remote sessions open from a machine card.
    static let navigable: [AppPage] = [.home, .today, .remote, .worktrees, .machines, .usage, .health]
    var title: String {
        switch self {
        case .home: "Home"
        case .today: "Today"
        case .machines: "Machines"
        case .worktrees: "Worktrees"
        case .usage: "Usage"
        case .health: "Mac Health"
        case .remote: "Chats"
        }
    }
    var icon: String {
        switch self {
        case .home: "house"
        case .today: "calendar"
        case .machines: "server.rack"
        case .worktrees: "arrow.triangle.branch"
        case .usage: "gauge.with.dots.needle.33percent"
        case .health: NotchPage.mac.symbol
        case .remote: "bubble.left.and.bubble.right"
        }
    }
    var shortcut: KeyEquivalent { KeyEquivalent(Character(String((Self.navigable.firstIndex(of: self) ?? 8) + 1))) }
    /// Pages that show worktree facts, so opening them refreshes a stale inventory.
    var showsWorktrees: Bool { self == .home || self == .today || self == .worktrees }
}

enum WorktreeFilter: Hashable {
    case all, working, inUse, inactive, candidates, cleanup, protected, repository(String), bench(UUID)
    var title: String {
        switch self {
        case .all: "All worktrees"
        case .working: "Working now"
        case .inUse: "In use"
        case .inactive: "Inactive"
        case .candidates: "Ready to remove"
        case .cleanup: "Cleanup"
        case .protected: "Protected"
        case .repository: "Repository"
        case .bench: "Bench"
        }
    }
    var icon: String {
        switch self {
        case .all, .repository, .bench: "square.stack.3d.up"
        case .working: "waveform.path"
        case .inUse: "person.2"
        case .inactive: "moon"
        case .candidates: "checkmark.circle"
        case .cleanup: "trash"
        case .protected: "lock"
        }
    }
    func matches(_ tree: Worktree) -> Bool {
        switch self {
        case .all: true
        case .working: tree.isWorking
        case .inUse: tree.isInUse
        case .inactive: !tree.isInUse
        case .candidates: false // Resolved by AppStore with current cleanup evidence.
        case .cleanup: !tree.isInUse && !tree.isPrimary
        case .protected: tree.protectedByUser || tree.isPrimary || tree.isLocked || tree.agents.contains { $0.pinned }
        case .repository(let path): tree.repositoryPath == path
        case .bench: false // Resolved by AppStore from the bench's projects.
        }
    }
}
extension SafetyLevel {
    var color: Color {
        switch self { case .keep: .secondary; case .review: AppAppearance.amber; case .candidate: AppAppearance.green }
    }
    var icon: String {
        switch self { case .keep: "shield.lefthalf.filled"; case .review: "exclamationmark.circle"; case .candidate: "checkmark.circle" }
    }
}
extension AgentState {
    var color: Color {
        switch self { case .working: AppAppearance.green; case .scheduled: .teal; case .waiting: AppAppearance.amber; case .recent: AppAppearance.blue; case .unknown: AppAppearance.amber; default: .secondary }
    }
}
enum Layout {
    static let small: CGFloat = 6
    static let gap: CGFloat = 12
    static let inset: CGFloat = 20
    static let sidebar: CGFloat = 210
    static let inspector: CGFloat = 320
}
extension CleanupStatus {
    var color: Color {
        switch self {
        case .ready: AppAppearance.green
        case .localChanges, .needsBranch, .gitBusy, .unknown: AppAppearance.amber
        case .inUse: AppAppearance.blue
        case .protected, .managed: .secondary
        }
    }
    var icon: String {
        switch self {
        case .ready: "checkmark.circle"
        case .inUse: "person.2"
        case .localChanges: "doc.badge.ellipsis"
        case .protected: "lock"
        case .managed: "archivebox"
        case .needsBranch: "arrow.triangle.branch"
        case .gitBusy: "arrow.triangle.2.circlepath"
        case .unknown: "questionmark.circle"
        }
    }
}
struct CleanupBadge: View {
    var status: CleanupStatus
    var body: some View {
        Label(status.rawValue, systemImage: status.icon)
            .font(.caption.weight(.medium)).foregroundStyle(status.color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(status.color.opacity(0.08), in: Capsule())
            .accessibilityLabel("Cleanup: \(status.rawValue)")
    }
}
