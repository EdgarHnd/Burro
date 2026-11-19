// The window's left sidebar, drawn by Burro instead of the system's. Top to bottom: a header for
// the traffic lights and the sidebar button (drag it to move the window; double-click to zoom), the
// brand row (Burro's mark, its name and the agents' state in one line, MenuBarStatus.summary), the
// pages in ⌘1–⌘8 order in labelled sections (Overview: Home, Orchestrator, Today; Workspace: Chats,
// Worktrees, Machines; System: Usage, Mac Health), "The crew" (the chats at work right now, as
// SidebarCrew picks them, scrolling in the space that is left) and Settings. Page rows carry what
// needs a glance: the Chats count (amber while a chat needs you, blue when there are only results
// to read), quiet totals for Worktrees and Machines when they are already known, a pulsing dot while
// the Orchestrator works, Mac Health's leftover count and a green dot while the Mac is kept awake.
// The current page's row is raised, never coloured. Crew rows are one line each: the chat's still
// avatar, its title (bold only when it needs you) and its state as a dot. Nothing here animates
// on a timer. Collapsed (by choice or a narrow window, SidebarLayout) it is an icon rail with the
// same tooltips, badges as corner marks and at most six crew avatars.
import AppKit
import SwiftUI
import BurroCore

struct Sidebar: View {
    @Bindable var store: AppStore
    var collapsed: Bool
    var toggle: () -> Void

    static let headerHeight: CGFloat = 52

    var body: some View {
        let chats = store.notchChatSessions
        let crew = SidebarCrew.make(chats, cap: collapsed ? SidebarLayout.railCrewCap : SidebarLayout.crewCap)
        VStack(alignment: collapsed ? .center : .leading, spacing: 0) {
            header
            brand(chats).padding(.bottom, collapsed ? 6 : 4)
            ForEach(Array(SidebarLayout.groups.enumerated()), id: \.offset) { _, group in
                section(group.label, pages: group.pages)
            }
            crewSection(crew)
            SidebarSettingsRow(compact: collapsed)
                .padding(.horizontal, collapsed ? 0 : 12)
                .padding(.top, 6).padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppAppearance.background)
    }

    /// The traffic lights' corner. The drag and zoom layer sits behind the button, not around it,
    /// so the button is only itself to clicks and to accessibility.
    private var header: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { NSApp.keyWindow?.zoom(nil) }
                .modifier(WindowDragArea())
                .accessibilityHidden(true)
            // On the traffic lights' line; in rail mode they fill the corner, so it moves to the strip.
            if !collapsed {
                SidebarToggle(collapsed: false, action: toggle)
                    .padding(.trailing, 12).padding(.top, SidebarLayout.trafficLightLine - SidebarToggle.size / 2)
            }
        }
        .frame(height: Self.headerHeight)
        .frame(maxWidth: .infinity)
    }

    /// Burro's mark and name, and the agents' state in a line ("2 need you · 5 working"), counted
    /// from Home's own board so it says what Home's sentence says (sub-agents left out, chats
    /// triage found ending on a question counted as needing you).
    private func brand(_ chats: [AgentSession]) -> some View {
        let board = HomeBoard.build(sessions: store.agentActivity.sessions, briefNeeds: store.brief.needsYou, all: chats)
        let summary = MenuBarStatus(board).summary
        return HStack(spacing: 10) {
            Image(nsImage: BurroBrand.image).renderingMode(.template).resizable().interpolation(.high)
                .frame(width: 20, height: 20).foregroundStyle(AppAppearance.text)
            if !collapsed {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Burro").font(.system(size: 13, weight: .semibold)).foregroundStyle(AppAppearance.text)
                    Text(summary).font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, collapsed ? 0 : 22)
        .frame(height: 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Burro, \(summary)")
        .help(summary)
    }

    @ViewBuilder private func section(_ label: String, pages: [AppPage]) -> some View {
        VStack(alignment: collapsed ? .center : .leading, spacing: 2) {
            SidebarSectionLabel(title: label, compact: collapsed)
            ForEach(pages) { page in row(page) }
        }
        .padding(.horizontal, collapsed ? 0 : 12)
    }

    private func row(_ page: AppPage) -> some View {
        let item = item(page)
        // Mac Health keeps its heart here; AppPage.icon (the notch's chip) serves lists.
        let symbol = page == .health ? "heart.text.square" : page.icon
        let selected = SidebarLayout.row(for: store.page) == page
        return Group {
            if collapsed {
                ChromeIcon(symbol: symbol, help: item.help, badge: item.badge, badgeColor: item.badgeColor,
                           working: item.working, dot: item.dot, selected: selected, width: 40) { store.go(to: page) }
            } else {
                SidebarRow(title: page.title, symbol: symbol, help: item.help, badge: item.badge, badgeColor: item.badgeColor,
                           total: item.total, working: item.working, dot: item.dot, selected: selected) { store.go(to: page) }
            }
        }
    }

    /// What a page's row carries besides its name.
    private func item(_ page: AppPage) -> (help: String, badge: Int, badgeColor: Color, total: Int?, working: Bool, dot: Color?) {
        switch page {
        case .orchestrator:
            return (page.help + ": your agents' project manager", 0, AppAppearance.amber, nil, store.orchestrator.running, nil)
        case .remote:
            return (page.help + ": every conversation, badge = needs you (amber) or ready to read (blue)",
                    store.agentActivity.attentionCount,
                    store.agentActivity.waitingCount > 0 ? AppAppearance.amber : AppAppearance.blue, nil, false, nil)
        case .worktrees:
            // The last scan's count, already in memory; nothing is scanned for it.
            let count = store.availableWorktrees.count
            return (page.help, 0, AppAppearance.amber, store.didScan && count > 0 ? count : nil, false, nil)
        case .machines:
            // This Mac plus your SSH machines, from settings; a lone "1" would say nothing.
            let count = store.remoteHosts.count
            return (page.help, 0, AppAppearance.amber, count > 0 ? count + 1 : nil, false, nil)
        case .health:
            let awake = store.keepAwake.awake
            return (page.help + (awake ? ": keeping this Mac awake" : ""), store.health.report.leftovers.count, AppAppearance.amber,
                    nil, false, awake ? AppAppearance.green : nil)
        default:
            return (page.help, 0, AppAppearance.amber, nil, false, nil)
        }
    }

    /// "THE CREW  7", its rows scrolling in the space between System and Settings, and "Show all N in Chats".
    private func crewSection(_ crew: SidebarCrew) -> some View {
        VStack(alignment: collapsed ? .center : .leading, spacing: 2) {
            SidebarSectionLabel(title: "The crew", count: crew.total, compact: collapsed)
                .padding(.horizontal, collapsed ? 0 : 12)
            ScrollView {
                VStack(alignment: collapsed ? .center : .leading, spacing: 2) {
                    if crew.members.isEmpty {
                        if !collapsed {
                            Text("No agents working").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                                .padding(.horizontal, 10).frame(height: 30, alignment: .leading)
                        }
                    } else {
                        ForEach(crew.members) { member in
                            SidebarCrewRow(member: member, place: ChatsModel.place(member.session, store: store), compact: collapsed) {
                                store.openChatFromSidebar(member.session)
                            }
                        }
                        if crew.overflow > 0 {
                            if collapsed {
                                ChromeIcon(symbol: "ellipsis", help: "Show all \(crew.total) in Chats", selected: false, size: 26, width: 40) {
                                    store.go(to: .remote)
                                }
                            } else {
                                SidebarShowAllRow(total: crew.total) { store.go(to: .remote) }
                            }
                        }
                    }
                }
                .padding(.horizontal, collapsed ? 0 : 12)
                .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            }
            .scrollIndicators(.never)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A section's small uppercase label with an optional quiet count; a short hairline in the rail.
struct SidebarSectionLabel: View {
    var title: String
    var count: Int? = nil
    var compact = false
    var body: some View {
        if compact {
            Rectangle().fill(AppAppearance.hairline).frame(width: 24, height: 1).padding(.vertical, 9).accessibilityHidden(true)
        } else {
            HStack(spacing: 6) {
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.9)
                Spacer(minLength: 6)
                if let count, count > 0 { Text("\(count)").font(.system(size: 11, weight: .medium)).monospacedDigit() }
            }
            .foregroundStyle(AppAppearance.tertiary)
            .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 6)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }
}

/// One chat in the crew: its still avatar, the title on one line and its state as a dot.
struct SidebarCrewRow: View {
    var member: SidebarCrew.Member
    var place: String
    var compact: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        let session = member.session
        let needsYou = member.status == .needsYou
        Button(action: action) {
            Group {
                if compact {
                    ChatRowAvatar(provider: session.provider, id: session.id, status: member.status)
                        .frame(width: 40, height: 30)
                        .background(hovering ? AppAppearance.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    HStack(spacing: 10) {
                        ProviderAvatar(provider: session.provider, id: session.id, active: false, working: false, size: 18)
                            .frame(width: 20).accessibilityHidden(true)
                        Text(session.title).font(.system(size: 13, weight: needsYou ? .medium : .regular))
                            .foregroundStyle(needsYou || hovering ? AppAppearance.text : AppAppearance.secondary)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 6)
                        Circle().fill(ChatStatusColor.of(member.status)).frame(width: 7, height: 7)
                    }
                    .padding(.horizontal, 10).frame(height: 30).frame(maxWidth: .infinity)
                    .background(hovering ? AppAppearance.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(session.title)\n\(place)")
        .accessibilityLabel("\(session.title), \(member.status.title), \(place)")
    }
}

/// One page in the full sidebar: icon, name and a trailing mark, all rows the same height.
struct SidebarRow: View {
    var title: String
    var symbol: String
    var help: String
    var badge: Int = 0
    var badgeColor: Color = AppAppearance.amber
    /// A quiet total (plain tertiary number), when it is already known.
    var total: Int? = nil
    var working = false
    var dot: Color? = nil
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            SidebarRowLabel(title: title, symbol: symbol, selected: selected, hovering: hovering) {
                HStack(spacing: 6) {
                    if let total { Text("\(total)").font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.tertiary) }
                    if working {
                        Circle().fill(OrchestratorStyle.tint).frame(width: 7, height: 7)
                            .symbolEffect(.pulse, isActive: !reduceMotion)
                    }
                    if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                    if badge > 0 { SidebarCount(count: badge, color: badgeColor) }
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(badge > 0 ? "\(help), \(badge)" : total.map { "\(help), \($0)" } ?? help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The row's look, shared by page rows and Settings.
struct SidebarRowLabel<Accessory: View>: View {
    var title: String
    var symbol: String
    var selected = false
    var hovering = false
    /// Tertiary text, for "Show all N in Chats".
    var quiet = false
    @ViewBuilder var accessory: () -> Accessory
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: quiet ? 13 : 15, weight: .regular)).frame(width: 20)
            Text(title).font(.system(size: quiet ? 12 : 13, weight: selected ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 6)
            accessory()
        }
        .foregroundStyle(selected || hovering ? AppAppearance.text : (quiet ? AppAppearance.tertiary : AppAppearance.secondary))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(selected ? AppAppearance.raised : (hovering ? AppAppearance.hover : .clear), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// "Show all N in Chats" under a capped crew.
struct SidebarShowAllRow: View {
    var total: Int
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            SidebarRowLabel(title: "Show all \(total) in Chats", symbol: "ellipsis", hovering: hovering, quiet: true) { EmptyView() }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open Chats")
    }
}

/// A small count capsule: amber for something that needs you, blue for something ready to read.
struct SidebarCount: View {
    var count: Int
    var color: Color
    /// The rail's corner mark.
    var small = false
    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: small ? 9.5 : 11, weight: .bold)).monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, small ? 4 : 6)
            .frame(minWidth: small ? 16 : 20, minHeight: small ? 16 : 18)
            .background(color, in: Capsule())
            .fixedSize()
    }
}

/// Settings at the foot of the sidebar; opens the Settings window like ⌘,.
struct SidebarSettingsRow: View {
    var compact: Bool
    @State private var hovering = false
    var body: some View {
        SettingsLink {
            if compact {
                Image(systemName: "gearshape").font(.system(size: 15, weight: .regular))
                    .foregroundStyle(hovering ? AppAppearance.text : AppAppearance.secondary)
                    .frame(width: 40, height: 34)
                    .background(hovering ? AppAppearance.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            } else {
                SidebarRowLabel(title: "Settings", symbol: "gearshape", hovering: hovering) { EmptyView() }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Settings (⌘,)")
        .accessibilityLabel("Settings")
    }
}
