// Shared desktop presentation for consistent filters and semantic statuses.
import SwiftUI
import BurroCore

enum WorktreeFilter: Hashable {
    case all, working, inUse, inactive, candidates, cleanup, protected, remote, usage, repository(String)
    var title: String {
        switch self {
        case .all: "All worktrees"
        case .working: "Working now"
        case .inUse: "In use"
        case .inactive: "Inactive"
        case .candidates: "Ready to remove"
        case .cleanup: "Cleanup"
        case .protected: "Protected"
        case .remote: "Remote sessions"
        case .usage: "Usage"
        case .repository: "Repository"
        }
    }
    var icon: String {
        switch self {
        case .all, .repository: "square.stack.3d.up"
        case .working: "waveform.path"
        case .inUse: "person.2"
        case .inactive: "moon"
        case .candidates: "checkmark.circle"
        case .cleanup: "trash"
        case .protected: "lock"
        case .remote: "network"
        case .usage: "gauge.with.dots.needle.33percent"
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
        case .remote, .usage: false
        case .repository(let path): tree.repositoryPath == path
        }
    }
}
extension SafetyLevel {
    var color: Color {
        switch self { case .keep: .secondary; case .review: .orange; case .candidate: .green }
    }
    var icon: String {
        switch self { case .keep: "shield.lefthalf.filled"; case .review: "exclamationmark.circle"; case .candidate: "checkmark.circle" }
    }
}
extension AgentState {
    var color: Color {
        switch self { case .working: .green; case .scheduled: .teal; case .waiting: .orange; case .recent: .blue; case .unknown: .orange; default: .secondary }
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
        case .ready: .green
        case .localChanges, .needsBranch, .gitBusy, .unknown: .orange
        case .inUse: .blue
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
