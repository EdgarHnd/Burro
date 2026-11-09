// The window's top bar, drawn by Burro instead of the system toolbar: Today and Home with a
// breadcrumb on the left, page tools in the middle, and icon buttons with badges on the right.
// The traffic lights sit in its left inset; dragging the bar moves the window.
import AppKit
import SwiftUI
import BurroCore

struct TopBar: View {
    @Bindable var store: AppStore
    var notch: NotchController

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 74, height: 1) // traffic lights
            TopBarIcon(symbol: "calendar", help: AppPage.today.help, selected: store.page == .today) { store.page = .today }
            TopBarIcon(symbol: "house", help: AppPage.home.help, selected: store.page == .home) { store.page = .home }
            TopBarIcon(symbol: "sparkles", help: AppPage.orchestrator.help + ": your agents' project manager",
                       working: store.orchestrator.running, selected: store.page == .orchestrator) { store.page = .orchestrator }
            if ![.home, .today, .orchestrator].contains(store.page) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(AppAppearance.tertiary)
                    .padding(.horizontal, 4)
                Label(store.page.title, systemImage: store.page.icon)
                    .font(.system(size: 14, weight: .semibold)).labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 16)
            pageTools.padding(.trailing, 10)
            TopBarIcon(symbol: "bubble.left.and.bubble.right", help: AppPage.remote.help + ": every conversation, badge = needs you or ready to read",
                       badge: store.agentActivity.attentionCount, selected: store.page == .remote) { store.page = .remote }
            TopBarIcon(symbol: "arrow.triangle.branch", help: AppPage.worktrees.help, selected: store.page == .worktrees) { store.page = .worktrees }
            TopBarIcon(symbol: "server.rack", help: AppPage.machines.help, selected: store.page == .machines) { store.page = .machines }
            TopBarIcon(symbol: "gauge.with.dots.needle.33percent", help: AppPage.usage.help, selected: store.page == .usage) { store.page = .usage }
            TopBarIcon(symbol: "heart.text.square", help: AppPage.health.help, badge: store.health.report.leftovers.count,
                       badgeColor: AppAppearance.amber, selected: store.page == .health) { store.page = .health }
            TopBarIcon(symbol: "square.and.pencil", help: "New chat (⌘N)", selected: false) { store.newChatPresented = true }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(AppAppearance.background)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSApp.keyWindow?.zoom(nil) }
        .modifier(WindowDragArea())
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

/// A plain top-bar icon: a soft circle on hover or when it's the current page, and an optional badge.
struct TopBarIcon: View {
    var symbol: String
    var help: String
    var badge: Int = 0
    var badgeColor: Color = .red
    /// A small pulsing dot while something runs behind this page.
    var working = false
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol).font(.system(size: 15, weight: .regular))
                    .foregroundStyle(selected || hovering ? AppAppearance.text : AppAppearance.secondary)
                    .frame(width: 34, height: 34)
                    .background(selected ? AppAppearance.raised : (hovering ? AppAppearance.hover : .clear), in: Circle())
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
                        .symbolEffect(.pulse, isActive: true)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(badge > 0 ? "\(help), \(badge)" : help)
    }
}

/// Lets the bar move the window like a title bar (macOS 15+; macOS 14 drags by the window background).
struct WindowDragArea: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.gesture(WindowDragGesture()) } else { content }
    }
}
