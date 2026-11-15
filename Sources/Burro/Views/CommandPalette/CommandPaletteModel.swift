// What the ⌘K palette offers, gathered once each time it opens: the pages, every chat on every
// machine (the same list the Chats page shows), projects, machines and a few actions. Typing only
// filters that snapshot in memory. Running a row navigates like the rest of the app does: a page or
// machine is chosen directly (no back pill), a chat, project or Orchestrator question is a jump; the
// actions open the New chat sheet, Settings or a prefilled (never sent) Orchestrator draft, so
// nothing here starts or messages an agent by itself.
import SwiftUI
import BurroCore

@MainActor @Observable final class CommandPaletteModel {
    /// How a row looks and what it does, beside the plain item the index ranks.
    struct Row {
        var symbol: String
        var kindLabel: String
        var needsYou = false
        var session: AgentSession?
        var run: @MainActor () -> Void
    }

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            results = index.results(for: query)
            selection = 0
        }
    }
    private(set) var results: [CommandPaletteItem] = []
    var selection = 0
    @ObservationIgnored private let index: CommandPaletteIndex
    @ObservationIgnored private let rows: [String: Row]

    init(store: AppStore, openSettings: @escaping @MainActor () -> Void) {
        var items: [CommandPaletteItem] = []
        var rows: [String: Row] = [:]
        func add(_ item: CommandPaletteItem, _ row: Row) {
            guard rows[item.id] == nil else { return }
            items.append(item); rows[item.id] = row
        }

        // Pages, in ⌘1–⌘8 order, then any page without a shortcut.
        let pages = AppPage.navigable + AppPage.allCases.filter { !AppPage.navigable.contains($0) }
        for page in pages {
            let shortcut = AppPage.navigable.contains(page) ? "⌘\(page.shortcut.character)" : ""
            add(CommandPaletteItem(id: "page:\(page.rawValue)", kind: .page, title: page.title, subtitle: shortcut,
                                   keywords: Self.pageKeywords(page)),
                Row(symbol: page.icon, kindLabel: "Page") { store.go(to: page) })
        }

        // Chats: needs-you, working and recent states drive the ranking.
        let sessions = ChatsModel.sessions(store: store, query: "")
        var asks: [(CommandPaletteItem, Row)] = []
        for session in sessions {
            let place = ChatsModel.place(session, store: store)
            let title = session.title.isEmpty ? "Untitled chat" : session.title
            let status: CommandPaletteItem.Status
            switch session.state {
            case .waiting where session.remote?.stale != true: status = .needsYou
            case .working, .scheduled: status = .working
            default: status = .recent
            }
            let folder = URL(fileURLWithPath: session.remote == nil ? store.workspacePath(for: session) : session.cwd).lastPathComponent
            let keywords = [session.remote?.hostName ?? "This Mac", folder, session.provider.rawValue, store.workspaceBranch(for: session) ?? ""]
            add(CommandPaletteItem(id: "chat:\(session.id)", kind: .chat, title: title, subtitle: place, keywords: keywords,
                                   status: status, updatedAt: session.updatedAt),
                Row(symbol: "bubble.left", kindLabel: status == .needsYou ? "Needs you" : (status == .working ? "Working" : "Chat"),
                    needsYou: status == .needsYou, session: session) { store.showChat(session) })
            // The same wording as the Orchestrator page's "Ask" button; it fills the composer, it doesn't send.
            let draft = "What's the latest on “\(session.title)” (\(session.remote?.hostName ?? "This Mac"))?"
            asks.append((CommandPaletteItem(id: "ask:\(session.id)", kind: .action, title: "Ask the Orchestrator about “\(title)”",
                                            subtitle: place, weight: -40),
                         Row(symbol: "sparkles", kindLabel: "Action") { store.orchestrator.draft = draft; store.page = .orchestrator }))
        }

        // Projects and machines, as Home lists them.
        let summary = store.homeSummary
        for project in summary.projects {
            let detail = project.isRepository
                ? (project.worktrees == 1 ? "1 worktree" : "\(project.worktrees) worktrees")
                : (project.id as NSString).abbreviatingWithTildeInPath
            add(CommandPaletteItem(id: "project:\(project.id)", kind: .project, title: project.name,
                                   subtitle: [detail, Self.counts(project.counts)].compactMap { $0 }.joined(separator: " · ")),
                Row(symbol: project.isRepository ? "folder" : "folder.badge.questionmark", kindLabel: "Project") { store.showProject(project) })
        }
        for machine in summary.machines {
            add(CommandPaletteItem(id: "machine:\(machine.id)", kind: .machine, title: machine.name,
                                   subtitle: [Self.connection(machine.connection), Self.counts(machine.counts)].compactMap { $0 }.joined(separator: " · ")),
                Row(symbol: machine.connection == .local ? "laptopcomputer" : "desktopcomputer", kindLabel: "Machine") { store.go(to: .machines) })
        }

        // Actions. Each opens something you then confirm, or changes only this Mac.
        add(CommandPaletteItem(id: "action:new-chat", kind: .action, title: "New chat…", subtitle: "⌘N",
                               keywords: ["start", "launch", "Codex", "Claude"]),
            Row(symbol: "plus.bubble", kindLabel: "Action") { store.newChatPresented = true })
        for folder in store.launchFolders {
            add(CommandPaletteItem(id: "action:new-chat-in:\(folder.path)", kind: .action, title: "New chat in \(folder.name)…",
                                   subtitle: "Opens the New chat sheet", keywords: ["start", "launch"]),
                Row(symbol: "plus.bubble", kindLabel: "Action") { store.startChat(in: folder.path) })
        }
        add(CommandPaletteItem(id: "action:settings", kind: .action, title: "Open Settings", subtitle: "⌘,", keywords: ["preferences"]),
            Row(symbol: "gearshape", kindLabel: "Action") { openSettings() })
        if !store.refreshingCurrentPage {
            add(CommandPaletteItem(id: "action:refresh", kind: .action, title: "Refresh \(store.page.title)", subtitle: "⌘R", keywords: ["reload"]),
                Row(symbol: "arrow.clockwise", kindLabel: "Action") { Task { await store.refreshCurrentPage() } })
        }
        let keepAwake = store.keepAwake
        if keepAwake.manualActive {
            add(CommandPaletteItem(id: "action:stop-awake", kind: .action, title: "Stop keeping awake", subtitle: keepAwake.headline,
                                   keywords: ["sleep", "caffeinate"]),
                Row(symbol: "moon.zzz", kindLabel: "Action") { keepAwake.stopManual() })
        } else if !keepAwake.busy {
            add(CommandPaletteItem(id: "action:keep-awake", kind: .action, title: "Keep awake for 2 hours", subtitle: "This Mac",
                                   keywords: ["sleep", "caffeinate"]),
                Row(symbol: "cup.and.saucer", kindLabel: "Action") { keepAwake.keepAwake(for: 2 * 3600) })
        }
        for (item, row) in asks { add(item, row) }

        index = CommandPaletteIndex(items)
        self.rows = rows
        results = index.results(for: "")
    }

    func row(_ item: CommandPaletteItem) -> Row? { rows[item.id] }
    var selected: CommandPaletteItem? { results.indices.contains(selection) ? results[selection] : nil }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }
    /// The selected row's action, for the caller to run once the palette has closed.
    func action(for item: CommandPaletteItem? = nil) -> (@MainActor () -> Void)? {
        guard let item = item ?? selected else { return nil }
        return rows[item.id]?.run
    }
    /// What VoiceOver reads for a row.
    func spokenLabel(_ item: CommandPaletteItem) -> String {
        let kind = rows[item.id]?.kindLabel ?? ""
        return [item.title, kind, item.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private static func pageKeywords(_ page: AppPage) -> [String] {
        switch page {
        case .remote: ["conversations", "sessions"]
        case .timeline: ["shipped", "github"]
        case .health: ["battery", "memory", "disk"]
        case .worktrees: ["branches", "cleanup"]
        case .orchestrator: ["ask"]
        default: []
        }
    }
    private static func counts(_ counts: HomeCounts) -> String? {
        let parts = [counts.waiting > 0 ? "\(counts.waiting) need you" : nil,
                     counts.running > 0 ? "\(counts.running) working" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    private static func connection(_ connection: HomeMachine.Connection) -> String {
        switch connection {
        case .local: "This Mac"
        case .online: "Connected"
        case .stale: "Status stale"
        case .offline: "Unreachable"
        case .connecting: "Connecting"
        case .paused: "Paused"
        }
    }
}
