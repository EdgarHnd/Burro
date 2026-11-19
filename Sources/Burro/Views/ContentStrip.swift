// The slim strip above every page, drawn by Burro instead of a toolbar. Left: the sidebar button
// while the sidebar is a rail (the traffic lights overhang into the strip then, so it starts after
// them), and a back pill after a jump from inside a page ("‹ Today" on the Timeline). Right: the
// current page's tools (Worktrees: its search field, Cleanup and Add a repository; Worktrees, Today
// and Machines: Refresh or its progress), the "Search chats, or type to start one ⌘K" field that
// opens the command palette (a magnifier when the strip is crowded, and always on Worktrees, so two
// fields never sit side by side), and New chat (⌘N), the window's one amber button, far right. It
// is always there, so pages never jump; dragging its background moves the window and a
// double-click zooms. Also the small controls the window chrome shares: ChromeIcon, BackPill and
// WindowDragArea.
import AppKit
import SwiftUI
import BurroCore

struct ContentStrip: View {
    @Bindable var store: AppStore
    /// The sidebar is a rail: clear the traffic lights and show the sidebar button here.
    var rail: Bool
    var toggleSidebar: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 44

    var body: some View {
        HStack(spacing: 8) {
            if rail {
                // On the traffic lights' line, not the strip's centre.
                SidebarToggle(collapsed: true, action: toggleSidebar)
                    .padding(.top, SidebarLayout.trafficLightLine - SidebarToggle.size / 2)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            if let target = store.backPillTarget {
                BackPill(title: target.title) { store.followBackPill() }
                    .transition(.opacity)
            }
            Spacer(minLength: 12)
            pageTools.layoutPriority(1)
            search
            StripNewChatButton { store.newChatPresented = true }.layoutPriority(2)
        }
        .padding(.leading, rail ? SidebarLayout.trafficLights - SidebarLayout.railWidth - 1 : 14)
        .padding(.trailing, 14)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        // The drag and zoom layer sits behind the controls, so they stay plain buttons.
        .background {
            AppAppearance.background
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { NSApp.keyWindow?.zoom(nil) }
                .modifier(WindowDragArea())
                .accessibilityHidden(true)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: store.page)
    }

    private var searchIcon: some View {
        ChromeIcon(symbol: "magnifyingglass", help: "Search chats, or type to start one (⌘K)", selected: false) { CommandPalette.toggle() }
    }

    /// The ⌘K field when there's room; a magnifier (still ⌘K) when the strip is crowded or on Worktrees.
    @ViewBuilder private var search: some View {
        if store.page == .worktrees {
            searchIcon
        } else {
            ViewThatFits(in: .horizontal) {
                StripSearchField { CommandPalette.toggle() }.frame(minWidth: 220, idealWidth: 300, maxWidth: 300)
                searchIcon
            }
        }
    }

    @ViewBuilder private var pageTools: some View {
        HStack(spacing: 8) {
            if store.page == .worktrees {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                    TextField("Branch, repository, or agent", text: $store.search).textFieldStyle(.plain).font(.system(size: 13))
                    if !store.search.isEmpty {
                        Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                            .foregroundStyle(AppAppearance.tertiary).accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 10).frame(minWidth: 130, idealWidth: 260, maxWidth: 260).frame(height: 30)
                .background(AppAppearance.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(AppAppearance.separator))
                ChromeIcon(symbol: "trash", help: "Review inactive worktrees and cleanup blockers", selected: store.filter == .cleanup) { store.filter = .cleanup }
                ChromeIcon(symbol: "folder.badge.plus", help: "Add a repository", selected: false) { store.addRepository() }
            }
            if [.worktrees, .today, .machines].contains(store.page) {
                if store.refreshingCurrentPage { ProgressView().controlSize(.small).frame(width: 34) }
                else {
                    ChromeIcon(symbol: "arrow.clockwise", help: "Refresh (⌘R)", selected: false) { Task { await store.refreshCurrentPage() } }
                }
            }
        }
    }
}

/// The sidebar button (`sidebar.left`): in the sidebar's header, or in the strip while it is a rail.
struct SidebarToggle: View {
    var collapsed: Bool
    var action: () -> Void
    static let size: CGFloat = 26
    var body: some View {
        ChromeIcon(symbol: "sidebar.left", help: collapsed ? "Show Sidebar (⌃⌘S)" : "Hide Sidebar (⌃⌘S)", selected: false, size: Self.size, action: action)
    }
}

/// Looks like a search field and opens the ⌘K command palette, where searching and "Start chat: …"
/// already live; nothing is typed here.
struct StripSearchField: View {
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium))
                Text("Search chats, or type to start one").font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text("⌘K").font(.system(size: 11, design: .monospaced)).foregroundStyle(AppAppearance.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(AppAppearance.raised, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(AppAppearance.hairline))
                    .fixedSize()
            }
            .foregroundStyle(AppAppearance.tertiary)
            .padding(.horizontal, 10).frame(height: 30)
            .background(hovering ? AppAppearance.raised : AppAppearance.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppAppearance.separator))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Search chats, pages and projects, or start a chat (⌘K)")
        .accessibilityLabel("Search chats, or type to start one")
        .accessibilityHint("Opens the command palette")
    }
}

/// "+ New chat": the window's one amber action. Opens the New chat sheet; it never starts a chat.
struct StripNewChatButton: View {
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                Text("New chat").font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(Color.black.opacity(0.86))
            .padding(.horizontal, 12).frame(height: 30)
            .background(AppAppearance.amber.opacity(hovering ? 0.88 : 1), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("New chat (⌘N)")
        .accessibilityLabel("New chat")
    }
}

/// A plain chrome icon: a soft rounded square on hover, raised when selected, with an optional
/// badge, a pulsing dot while something runs behind it, or a steady dot for a state that stays on.
struct ChromeIcon: View {
    var symbol: String
    var help: String
    var badge: Int = 0
    /// Amber for something that needs you, blue for something ready to read.
    var badgeColor: Color = AppAppearance.amber
    var working = false
    var dot: Color? = nil
    var selected: Bool
    var size: CGFloat = 34
    var width: CGFloat? = nil
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .regular))
                .foregroundStyle(selected || hovering ? AppAppearance.text : AppAppearance.secondary)
                .frame(width: width ?? size, height: size)
                .background(selected ? AppAppearance.raised : (hovering ? AppAppearance.hover : .clear), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    ChromeBadge(count: badge, color: badgeColor, working: working, dot: dot).offset(x: badge > 0 ? 3 : -4, y: badge > 0 ? -3 : 5)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(badge > 0 ? "\(help), \(badge)" : help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// An icon's corner mark: a count capsule, else a pulsing working dot, else a steady dot.
struct ChromeBadge: View {
    var count: Int
    var color: Color
    var working = false
    var dot: Color? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if count > 0 {
            SidebarCount(count: count, color: color, small: true)
                .overlay(Capsule().strokeBorder(AppAppearance.background, lineWidth: 1.5))
        } else if working {
            Circle().fill(OrchestratorStyle.tint).frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(AppAppearance.background, lineWidth: 1.5))
                .symbolEffect(.pulse, isActive: !reduceMotion)
        } else if let dot {
            Circle().fill(dot).frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(AppAppearance.background, lineWidth: 1.5))
        }
    }
}

/// "‹ Page": returns to where a jump from inside a page started (⌘[ does the same).
struct BackPill: View {
    var title: String
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(hovering ? AppAppearance.text : AppAppearance.secondary)
            .padding(.horizontal, 10).frame(height: 26)
            .background(hovering ? AppAppearance.hover : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(AppAppearance.separator))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Back to \(title) (⌘[)")
        .accessibilityLabel("Back to \(title)")
    }
}

/// Lets the chrome move the window like a title bar (macOS 15+; macOS 14 drags by the window background).
struct WindowDragArea: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.gesture(WindowDragGesture()) } else { content }
    }
}
