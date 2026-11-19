// The sidebar's state as the window and the View menu see it: the saved choice (rail or full),
// whether the window is too narrow for it right now, and the toggle both the header button and
// View ▸ Hide/Show Sidebar (⌃⌘S) use, and opening a crew chat. The rules are SidebarLayout's.
import BurroCore

extension AppStore {
    /// Whether the sidebar shows as an icon rail right now.
    var sidebarIsCollapsed: Bool {
        SidebarLayout.collapsed(saved: sidebarCollapsed, narrow: sidebarNarrow, expandedWhileNarrow: sidebarExpandedWhileNarrow)
    }
    func toggleSidebar() {
        let next = SidebarLayout.toggled(saved: sidebarCollapsed, narrow: sidebarNarrow, expandedWhileNarrow: sidebarExpandedWhileNarrow)
        if next.saved != sidebarCollapsed { sidebarCollapsed = next.saved }
        sidebarExpandedWhileNarrow = next.expandedWhileNarrow
    }
    /// A crew row: opens the chat on the Chats page as a page picked directly, so no back pill.
    func openChatFromSidebar(_ session: AgentSession) {
        search = ""
        remoteSelection = session.id
        go(to: .remote)
    }
    /// The window crossed the narrow threshold; widening forgets a temporary open.
    func windowNarrowChanged(_ narrow: Bool) {
        guard narrow != sidebarNarrow else { return }
        sidebarNarrow = narrow
        if !narrow { sidebarExpandedWhileNarrow = false }
    }
}
