// The window's top bar, drawn by Burro instead of the system toolbar: Home, Orchestrator and
// Today on the left (in ⌘1–⌘3 order), then a back pill after a jump from inside a page (and
// "‹ Today" on the Timeline), page tools in the middle, and icon buttons with badges on the right.
// The current page's icon widens into a pill with its title. The Chats badge is amber while a
// chat needs you and blue when there are only results to read. The traffic lights sit in its
// left inset; dragging the bar moves the window.
import AppKit
import SwiftUI
import BurroCore

struct TopBar: View {
    @Bindable var store: AppStore
    var notch: NotchController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 74, height: 1) // traffic lights
            icon(.home, symbol: "house")
            icon(.orchestrator, symbol: "sparkles", help: AppPage.orchestrator.help + ": your agents' project manager",
                 working: store.orchestrator.running)
            icon(.today, symbol: "calendar")
            if let target = store.backPillTarget {
                TopBarBackPill(title: target.title) { store.followBackPill() }
                    .padding(.leading, 6)
                    .transition(.opacity)
            }
            Spacer(minLength: 16)
            pageTools.padding(.trailing, 10)
            icon(.remote, symbol: "bubble.left.and.bubble.right", help: AppPage.remote.help + ": every conversation, badge = needs you (amber) or ready to read (blue)",
                 badge: store.agentActivity.attentionCount,
                 badgeColor: store.agentActivity.waitingCount > 0 ? AppAppearance.amber : AppAppearance.blue)
            icon(.worktrees, symbol: "arrow.triangle.branch")
            icon(.machines, symbol: "server.rack")
            icon(.usage, symbol: "gauge.with.dots.needle.33percent")
            icon(.health, symbol: "heart.text.square", help: AppPage.health.help + (store.keepAwake.awake ? ": keeping this Mac awake" : ""),
                 badge: store.health.report.leftovers.count, badgeColor: AppAppearance.amber,
                 dot: store.keepAwake.awake ? AppAppearance.green : nil)
            TopBarIcon(symbol: "square.and.pencil", help: "New chat (⌘N)", selected: false) { store.newChatPresented = true }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(AppAppearance.background)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSApp.keyWindow?.zoom(nil) }
        .modifier(WindowDragArea())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: store.page)
    }

    private func icon(_ page: AppPage, symbol: String, help: String? = nil, badge: Int = 0, badgeColor: Color = AppAppearance.amber,
                      working: Bool = false, dot: Color? = nil) -> TopBarIcon {
        TopBarIcon(symbol: symbol, help: help ?? page.help, title: page.title, badge: badge, badgeColor: badgeColor,
                   working: working, dot: dot, selected: store.page == page) { store.go(to: page) }
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
                .padding(.horizontal, 10).frame(width: 260, height: 30)
                .background(AppAppearance.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(AppAppearance.separator))
                TopBarIcon(symbol: "trash", help: "Review inactive worktrees and cleanup blockers", selected: store.filter == .cleanup) { store.filter = .cleanup }
                TopBarIcon(symbol: "folder.badge.plus", help: "Add a repository", selected: false) { store.addRepository() }
            }
            if [.worktrees, .today, .machines].contains(store.page) {
                if store.refreshingCurrentPage { ProgressView().controlSize(.small).frame(width: 32) }
                else {
                    TopBarIcon(symbol: "arrow.clockwise", help: "Refresh (⌘R)", selected: false) { Task { await store.refreshCurrentPage() } }
                }
            }
        }
    }
}

/// A plain top-bar icon: a soft circle on hover, and an optional badge. When it is the current
/// page and has a title, it widens into a pill showing the icon and the page's name.
struct TopBarIcon: View {
    var symbol: String
    var help: String
    var title: String? = nil
    var badge: Int = 0
    /// Amber for something that needs you, blue for something ready to read.
    var badgeColor: Color = AppAppearance.amber
    /// A small pulsing dot while something runs behind this page.
    var working = false
    /// A small steady dot for a state that stays on (Keep Awake).
    var dot: Color? = nil
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var showsTitle: Bool { selected && title != nil }
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 15, weight: .regular))
                    if showsTitle, let title {
                        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                            .transition(.opacity)
                    }
                }
                .foregroundStyle(selected || hovering ? AppAppearance.text : AppAppearance.secondary)
                .padding(.horizontal, showsTitle ? 12 : 0)
                .frame(minWidth: 34, minHeight: 34)
                .background(selected ? AppAppearance.raised : (hovering ? AppAppearance.hover : .clear), in: Capsule())
                if badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)").font(.system(size: 9.5, weight: .bold)).monospacedDigit()
                        .foregroundStyle(.white).padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                        .background(badgeColor, in: Capsule())
                        .overlay(Capsule().strokeBorder(AppAppearance.background, lineWidth: 1.5))
                        .offset(x: 4, y: -1)
                } else if working {
                    Circle().fill(OrchestratorStyle.tint).frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(AppAppearance.background, lineWidth: 1.5))
                        .offset(x: -3, y: 4)
                        .symbolEffect(.pulse, isActive: !reduceMotion)
                } else if let dot {
                    Circle().fill(dot).frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(AppAppearance.background, lineWidth: 1.5))
                        .offset(x: -3, y: 4)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(badge > 0 ? "\(help), \(badge)" : help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "‹ Page": returns to where a jump from inside a page started (⌘[ does the same).
struct TopBarBackPill: View {
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

/// Lets the bar move the window like a title bar (macOS 15+; macOS 14 drags by the window background).
struct WindowDragArea: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.gesture(WindowDragGesture()) } else { content }
    }
}
