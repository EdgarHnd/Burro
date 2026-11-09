// Quiet building blocks for Burro Home: cards, chips, tiles and the agent dock.
import SwiftUI
import BurroCore

enum HomeStyle {
    /// Brand colours that read the same in both themes (the app icon is butter on charcoal).
    static let butter = Color(red: 0.98, green: 0.79, blue: 0.27)
    static let charcoal = Color(red: 0.13, green: 0.13, blue: 0.125)
    /// Warm butter light on paper; a faint glow on charcoal so it never reads as olive.
    static let heroWash = AppAppearance.adaptive(light: (0.98, 0.79, 0.27, 0.18), dark: (0.98, 0.79, 0.27, 0.06))
    static let cardRadius: CGFloat = 16
    static let palette: [Color] = [AppAppearance.blue, .purple, .teal, AppAppearance.green, AppAppearance.amber, AppAppearance.claude, .pink, .indigo]
    /// A stable colour per project name, so a project keeps its tile colour across launches.
    static func tint(for name: String) -> Color {
        let hash = name.unicodeScalars.reduce(UInt32(2166136261)) { ($0 ^ $1.value) &* 16777619 }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

enum HomeFormat {
    static func tokens(_ value: Double) -> String { value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
    static func money(_ value: Double) -> String { value.formatted(.currency(code: "USD").precision(.fractionLength(0))) }
    static func ago(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }
}

struct HomeSectionHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
            Spacer()
            trailing().buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
        }.padding(.horizontal, 2)
    }
}

/// Cards lift on hover with a stronger hairline instead of moving or glowing.
struct HomeCardButtonStyle: ButtonStyle {
    var radius: CGFloat = HomeStyle.cardRadius
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(hovering ? AppAppearance.hover : .clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(hovering ? AppAppearance.hairline : AppAppearance.separator))
            .shadow(color: AppAppearance.shadow, radius: hovering ? 14 : 8, y: hovering ? 5 : 2)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct HomeChip: View {
    var text: String
    var color: Color = AppAppearance.secondary
    var symbol: String
    var dimmed = false
    var action: () -> Void
    @State private var hovering = false
    init(count: Int, label: String, color: Color, symbol: String, action: @escaping () -> Void) {
        self.text = "\(count) \(label)"; self.color = color; self.symbol = symbol; self.dimmed = count == 0; self.action = action
    }
    init(text: String, symbol: String, action: @escaping () -> Void) {
        self.text = text; self.symbol = symbol; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(text).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            .foregroundStyle(dimmed ? AppAppearance.tertiary : color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(hovering ? AppAppearance.raised : AppAppearance.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(AppAppearance.separator))
            .contentShape(Capsule())
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}

private struct HomeTile: View {
    var initial: String? = nil
    var symbol: String? = nil
    var tint: Color
    var body: some View {
        Group {
            if let initial { Text(initial).font(.system(size: 16, weight: .semibold, design: .rounded)) }
            else if let symbol { Image(systemName: symbol).font(.system(size: 15, weight: .medium)) }
        }
        .foregroundStyle(tint)
        .frame(width: 40, height: 40)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// One line of live status, coloured by the most urgent state, or a calm "Quiet".
private struct HomeStatusLine: View {
    var counts: HomeCounts
    var quiet = "Quiet"
    /// Machines show activity only; reading results is about chats, not hardware.
    var activityOnly = false
    var body: some View {
        if counts.isQuiet || (activityOnly && counts.running + counts.waiting == 0) {
            Text(quiet).foregroundStyle(AppAppearance.tertiary)
        } else {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(parts.joined(separator: " · ")).foregroundStyle(AppAppearance.secondary)
            }
        }
    }
    private var color: Color {
        counts.waiting > 0 ? AppAppearance.amber : (counts.running > 0 ? AppAppearance.green : (counts.done > 0 ? AppAppearance.blue : .teal))
    }
    private var parts: [String] {
        var parts: [String] = []
        if counts.waiting > 0 { parts.append("\(counts.waiting) need\(counts.waiting == 1 ? "s" : "") you") }
        if counts.running > 0 { parts.append("\(counts.running) running") }
        if counts.done > 0 && !activityOnly { parts.append("\(counts.done) to read") }
        if counts.scheduled > 0 && !activityOnly { parts.append("\(counts.scheduled) scheduled") }
        return parts.isEmpty ? [quiet] : parts
    }
}

struct HomeProjectCard: View {
    var project: HomeProject
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if project.isRepository {
                    HomeTile(initial: String(project.name.prefix(1)).uppercased(), tint: HomeStyle.tint(for: project.name))
                } else {
                    HomeTile(symbol: "folder", tint: AppAppearance.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).font(.system(size: 14, weight: .semibold)).lineLimit(1).foregroundStyle(AppAppearance.text)
                    HomeStatusLine(counts: project.counts).font(.system(size: 12)).lineLimit(1)
                    Text(meta).font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(HomeCardButtonStyle())
        .help(project.isRepository ? "Show \(project.name)'s worktrees" : "Show chats in \(project.id)")
    }
    private var meta: String {
        var parts: [String] = []
        if project.isRepository { parts.append("\(project.worktrees) worktree\(project.worktrees == 1 ? "" : "s")") }
        else { parts.append("Folder") }
        if project.readyToRemove > 0 { parts.append("\(project.readyToRemove) to clean") }
        if project.tokensToday > 0 { parts.append(HomeFormat.tokens(project.tokensToday) + " today") }
        else if let last = project.lastActive { parts.append(HomeFormat.ago(last)) }
        return parts.joined(separator: " · ")
    }
}

struct HomeMachineCard: View {
    var machine: HomeMachine
    var health: MacHealthSnapshot?
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                HomeTile(symbol: machine.connection == .local ? "laptopcomputer" : "desktopcomputer",
                         tint: available ? AppAppearance.text : AppAppearance.tertiary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(machine.name).font(.system(size: 14, weight: .semibold)).lineLimit(1).foregroundStyle(AppAppearance.text)
                    if available { HomeStatusLine(counts: machine.counts, activityOnly: true).font(.system(size: 12)).lineLimit(1) }
                    else { Text(connection).font(.system(size: 12)).foregroundStyle(AppAppearance.amber).lineLimit(1) }
                    Text(meta).font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(HomeCardButtonStyle())
        .help(machine.connection == .local ? "Open Mac Health" : "Show remote sessions")
    }
    private var available: Bool { machine.connection == .local || machine.connection == .online }
    private var connection: String {
        switch machine.connection {
        case .offline: "Unreachable"
        case .stale: "Status expired"
        case .connecting: "Connecting…"
        case .paused: "Paused"
        case .local, .online: "Online"
        }
    }
    private var meta: String {
        if machine.connection == .local {
            guard let health else { return "This Mac" }
            var parts = ["CPU " + HealthFormat.percent(health.cpuBusy)]
            if let memory = health.memory { parts.append("Memory " + HealthFormat.percent(HealthFormat.fraction(memory.used, of: memory.total))) }
            return parts.joined(separator: " · ")
        }
        return machine.lastSeen.map { "Seen " + HomeFormat.ago($0) } ?? "Over SSH"
    }
}

struct HomeEmptyCard<Actions: View>: View {
    var symbol: String
    var title: String
    var detail: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack(spacing: 14) {
            HomeTile(symbol: symbol, tint: AppAppearance.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
            }
            Spacer()
            actions()
        }.padding(16).modifier(AppCardSurface(radius: HomeStyle.cardRadius))
    }
}

// MARK: Right column

struct HomeInbox: View {
    var store: AppStore
    var summary: HomeSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if summary.needsYou.isEmpty && summary.unread.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").font(.system(size: 16)).foregroundStyle(AppAppearance.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Inbox clear").font(.system(size: 13, weight: .semibold))
                        Text("Nothing needs you right now.").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                    }
                }
            } else {
                if !summary.needsYou.isEmpty { section("Needs you", summary.needsYou, color: AppAppearance.amber) }
                if !summary.unread.isEmpty { section("Ready to read", summary.unread, color: AppAppearance.blue) }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(AppCardSurface(radius: HomeStyle.cardRadius))
    }
    private func section(_ title: String, _ sessions: [AgentSession], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(sessions.count)").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            }.padding(.bottom, 4)
            ForEach(sessions.prefix(4)) { session in HomeInboxRow(session: session, place: place(session)) { store.open(session) } }
            if sessions.count > 4 {
                Text("and \(sessions.count - 4) more in the notch").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).padding(.top, 2)
            }
        }
    }
    private func place(_ session: AgentSession) -> String {
        let folder = URL(fileURLWithPath: store.workspacePath(for: session)).lastPathComponent
        return [session.remote?.hostName, folder.isEmpty ? nil : folder].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct HomeInboxRow: View {
    var session: AgentSession
    var place: String
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AgentAvatar(session: session, active: false, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(1).foregroundStyle(AppAppearance.text)
                    Text(place).font(.system(size: 11)).lineLimit(1).foregroundStyle(AppAppearance.tertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppAppearance.tertiary).opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(hovering ? AppAppearance.hover : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, -8)
        .onHover { hovering = $0 }
        .help(session.chatURL == nil ? "Show details in Burro" : "Open in \(session.provider == .codex ? "Codex" : "Claude")")
    }
}

struct HomeUsageTile: View {
    @Bindable var store: AppStore
    var body: some View {
        Button { store.page = .usage } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Usage").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(AppAppearance.tertiary)
                }
                if !store.usageEnabled {
                    Text("Paused. Turn on usage limits in Settings.").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                } else if rows.isEmpty {
                    Text(store.providerUsage.availability == .loading ? "Loading limits…" : "Connect an account on the Usage page.")
                        .font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                } else {
                    ForEach(rows, id: \.label) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(row.label).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                                Spacer()
                                Text("\(Int(row.remaining.rounded()))% left").font(.system(size: 12, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(row.stale ? AppAppearance.tertiary : AppAppearance.text)
                            }
                            UsageQuotaBar(percent: row.remaining, remaining: row.remaining, stale: row.stale, height: 4)
                        }
                    }
                }
                if let activity = store.projectActivity, activity.tokens > 0 {
                    Divider().overlay(AppAppearance.separator)
                    HStack {
                        Text("Today on this Mac").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                        Spacer()
                        Text(HomeFormat.tokens(activity.tokens) + " tokens").font(.system(size: 12, weight: .medium)).monospacedDigit()
                    }.help(activity.apiValue > 0 ? "About \(HomeFormat.money(activity.apiValue)) at API prices" : "")
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(HomeCardButtonStyle())
    }
    /// The tightest window per provider: the number that decides whether you can keep going.
    private var rows: [(label: String, remaining: Double, stale: Bool)] {
        store.providerUsage.providers.compactMap { provider in
            guard provider.issue == nil,
                  let window = provider.windows.filter({ $0.remainingPercent != nil }).min(by: { $0.remainingPercent! < $1.remainingPercent! }),
                  let remaining = window.remainingPercent else { return nil }
            return ("\(provider.title) · \(window.title.lowercased())", remaining, provider.isStale(now: .now))
        }
    }
}

struct HomeMacTile: View {
    var store: AppStore
    var body: some View {
        let health = store.health
        Button { store.page = .health } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("This Mac").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if !health.report.leftovers.isEmpty {
                        Text("\(health.report.leftovers.count) left running").font(.system(size: 11, weight: .medium)).foregroundStyle(AppAppearance.amber)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(AppAppearance.tertiary)
                }
                if let snapshot = health.snapshot {
                    meter("CPU", HealthFormat.percent(snapshot.cpuBusy), snapshot.cpuBusy, snapshot.cpuLevel)
                    if let memory = snapshot.memory {
                        let used = HealthFormat.fraction(memory.used, of: memory.total)
                        meter("Memory", HealthFormat.percent(used), used, snapshot.memoryLevel)
                    }
                    if let storage = snapshot.storage {
                        meter("Disk", HealthFormat.bytes(storage.available, file: true) + " free",
                              HealthFormat.fraction(storage.total - min(storage.total, storage.available), of: storage.total), snapshot.storageLevel)
                    }
                } else {
                    Text("Sampling…").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(HomeCardButtonStyle())
    }
    private func meter(_ label: String, _ value: String, _ fraction: Double?, _ level: HealthLevel) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                Spacer()
                Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            HealthBar(fraction: fraction, level: level)
        }
    }
}

// MARK: Dock

/// Floating strip of live agents (click to open the chat), machines, New chat and a few tools.
struct HomeDock: View {
    var store: AppStore
    var summary: HomeSummary
    var notch: NotchController
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 14) {
                if summary.running.isEmpty && summary.needsYou.isEmpty && summary.unread.isEmpty {
                    BurroMark(active: false, working: false, tint: AppAppearance.tertiary).frame(width: 18, height: 18)
                    Text(store.didCheckAgents ? "No agents running" : "Checking…").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppAppearance.secondary)
                } else {
                    group(summary.running, symbol: "arrow.triangle.2.circlepath", color: AppAppearance.green, label: "Running")
                    group(summary.needsYou + summary.unread, symbol: "exclamationmark.bubble", color: AppAppearance.amber, label: "Needs you")
                }
            }
            .padding(.horizontal, 14).frame(height: 48)
            .modifier(FloatingSurface())
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                ForEach(summary.machines) { machine in
                    Button { store.page = machine.connection == .local ? .health : .machines } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Image(systemName: machine.connection == .local ? "laptopcomputer" : "desktopcomputer")
                                .font(.system(size: 14, weight: .medium)).frame(width: 34, height: 34)
                            Circle().fill(machine.connection == .local || machine.connection == .online ? AppAppearance.green : AppAppearance.tertiary)
                                .frame(width: 7, height: 7).overlay(Circle().strokeBorder(AppAppearance.surface, lineWidth: 1.5)).offset(x: -5, y: -6)
                        }
                    }.buttonStyle(HomeDockButtonStyle()).help("\(machine.name): \(machine.counts.running) running")
                }
            }
            .padding(.horizontal, 6).frame(height: 48)
            .modifier(FloatingSurface())
            Button { store.newChatPresented = true } label: {
                Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 48, height: 48).background(Color(white: 0.12), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            }.buttonStyle(PressableStyle()).help("New chat (⌘N)").accessibilityLabel("New chat")
            HStack(spacing: 2) {
                action("rectangle.topthird.inset.filled", "Show agent notch (⇧⌘B)") { notch.show() }
                action("calendar", "Today (⌘2)") { store.page = .today }
                action("arrow.clockwise", "Refresh everything") { Task { await store.refreshCurrentPage() } }
                SettingsLink { Image(systemName: "slider.horizontal.3").frame(width: 34, height: 34).contentShape(Rectangle()) }
                    .buttonStyle(HomeDockButtonStyle()).help("Settings")
            }
            .padding(.horizontal, 6).frame(height: 48)
            .modifier(FloatingSurface())
        }
    }
    @ViewBuilder private func group(_ sessions: [AgentSession], symbol: String, color: Color, label: String) -> some View {
        if !sessions.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                    .help("\(sessions.count) \(label.lowercased())")
                HStack(spacing: -7) {
                    ForEach(sessions.prefix(6)) { session in
                        Button { store.open(session) } label: {
                            AgentAvatar(session: session, active: true, working: session.state == .working, size: 26)
                                .padding(2).background(AppAppearance.surface, in: Circle())
                                .overlay(Circle().strokeBorder(AppAppearance.separator))
                        }.buttonStyle(.plain).help("\(label): \(session.title)")
                    }
                }
                if sessions.count > 6 {
                    Text("+\(sessions.count - 6)").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(AppAppearance.secondary)
                }
            }
        }
    }
    private func action(_ symbol: String, _ help: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Image(systemName: symbol).frame(width: 34, height: 34).contentShape(Rectangle()) }
            .buttonStyle(HomeDockButtonStyle()).help(help).accessibilityLabel(help)
    }
}

private struct HomeDockButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(hovering ? AppAppearance.text : AppAppearance.secondary)
            .background(hovering ? AppAppearance.hover : .clear, in: Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .onHover { hovering = $0 }
    }
}

/// Liquid Glass on macOS 26 builds; a frosted material with a hairline elsewhere.
struct FloatingSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular, in: Capsule())
        } else { frosted(content) }
        #else
        frosted(content)
        #endif
    }
    private func frosted(_ content: Content) -> some View {
        content
            .background(reduceTransparency ? AnyShapeStyle(AppAppearance.surface) : AnyShapeStyle(.regularMaterial), in: Capsule())
            .overlay(Capsule().strokeBorder(AppAppearance.separator))
            .shadow(color: AppAppearance.shadow, radius: 16, y: 6)
    }
}
