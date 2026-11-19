// The window sidebar's pure rules: its widths, its labelled groups (in ⌘1–⌘8 order, top to
// bottom), how many crew rows show, which row a page lights up, and when it shows as an icon rail. It collapses when you hide it (saved) or
// while the window is too narrow for it plus a page at full layout (never saved): Home and Worktrees
// both reflow below 900 points of their own width. Showing it in a narrow window opens it until the
// window widens again, without touching the saved choice.
import CoreGraphics

enum SidebarLayout {
    static let fullWidth: CGFloat = 224
    static let railWidth: CGFloat = 64
    /// The traffic lights' share of the window's top-left corner, wider than the rail.
    static let trafficLights: CGFloat = 88
    /// Below this page width Home drops its side column and Worktrees goes compact.
    static let comfortablePage: CGFloat = 900
    /// The traffic lights' centre line, from the window's top; the sidebar button sits on it.
    static let trafficLightLine: CGFloat = 14
    /// Crew rows before "Show all N in Chats" (SidebarCrew), and avatars in the rail.
    static let crewCap = 12
    static let railCrewCap = 6
    /// The UserDefaults key for the saved choice.
    static let collapsedKey = "sidebar.collapsed"

    /// The sidebar's sections; flattened, they are `AppPage.navigable`.
    static let groups: [(label: String, pages: [AppPage])] = [
        ("Overview", [.home, .orchestrator, .today]),
        ("Workspace", [.remote, .worktrees, .machines]),
        ("System", [.usage, .health]),
    ]

    /// The row that shows as selected: the Timeline opens from Today, so Today stays lit.
    static func row(for page: AppPage) -> AppPage { page == .timeline ? .today : page }

    /// Too narrow for the full sidebar beside a page at its full layout (with the 1 pt divider).
    static func isNarrow(windowWidth: CGFloat) -> Bool { windowWidth < fullWidth + 1 + comfortablePage }

    static func collapsed(saved: Bool, narrow: Bool, expandedWhileNarrow: Bool) -> Bool {
        narrow ? !expandedWhileNarrow : saved
    }

    /// The header button and View ▸ Hide/Show Sidebar: in a narrow window it only opens or closes the
    /// sidebar for now; otherwise it flips the saved choice.
    static func toggled(saved: Bool, narrow: Bool, expandedWhileNarrow: Bool) -> (saved: Bool, expandedWhileNarrow: Bool) {
        narrow ? (saved, !expandedWhileNarrow) : (!saved, false)
    }
}
