// The window's frame around every page: the Sidebar on the left (full, or an icon rail by choice or
// while the window is too narrow, SidebarLayout), a 1 pt divider, and on the right the ContentStrip
// above the page. Pages stay inside their column, so Home's fixed aquarium never runs under the
// sidebar. The width change animates briefly unless Reduce Motion is on.
import SwiftUI
import BurroCore

struct AppShell<Page: View>: View {
    @Bindable var store: AppStore
    @ViewBuilder var page: () -> Page
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Read synchronously, so a window never opens as a rail and then animates out.
        GeometryReader { geometry in
            let narrow = SidebarLayout.isNarrow(windowWidth: geometry.size.width)
            let collapsed = SidebarLayout.collapsed(saved: store.sidebarCollapsed, narrow: narrow,
                                                    expandedWhileNarrow: store.sidebarExpandedWhileNarrow)
            HStack(spacing: 0) {
                Sidebar(store: store, collapsed: collapsed, toggle: store.toggleSidebar)
                    .frame(width: collapsed ? SidebarLayout.railWidth : SidebarLayout.fullWidth)
                    .clipped()
                // In rail mode the divider starts below the traffic lights, which overhang the rail.
                Rectangle().fill(AppAppearance.separator).frame(width: 1)
                    .padding(.top, collapsed ? ContentStrip.height : 0)
                    .background(AppAppearance.background)
                VStack(spacing: 0) {
                    ContentStrip(store: store, rail: collapsed, toggleSidebar: store.toggleSidebar)
                    page().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: collapsed)
            .onChange(of: narrow, initial: true) { _, narrow in store.windowNarrowChanged(narrow) }
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}
