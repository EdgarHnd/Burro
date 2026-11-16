// Mac Health's "Left running" list and its side cards. Each leftover row shows what it is and where, why Burro
// flagged it (with the chat it belongs to when Burro can tell), how long it has run, its memory, and Stop…, which
// only opens the confirmation dialog. "Top by agents" lists the processes running under this Mac's agent chats;
// when there are none, "Busiest now" lists the busiest processes instead.
import SwiftUI
import BurroCore

struct MacHealthLeftoversSection: View {
    var health: MacHealthStore
    @State private var width: CGFloat = 800
    /// Below this the rows stack instead of lining up in columns.
    static let columns: CGFloat = 720
    private static let ageWidth: CGFloat = 56, memoryWidth: CGFloat = 70, actionsWidth: CGFloat = 132
    var body: some View {
        let report = health.report
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if !report.leftovers.isEmpty {
                    Circle().fill(AppAppearance.amber).frame(width: 7, height: 7).accessibilityHidden(true)
                    MacHealthLabel("Left running · \(report.leftovers.count)", color: AppAppearance.amber)
                } else {
                    MacHealthLabel("Left running")
                }
                Spacer()
                if report.reclaimable > 0 {
                    Text("\(HealthFormat.bytes(report.reclaimable)) in all").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                }
            }.padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 0) {
                if report.leftovers.isEmpty {
                    Label(report.complete ? "Nothing left running." : "Checking processes…", systemImage: report.complete ? "checkmark.circle" : "ellipsis")
                        .foregroundStyle(report.complete ? AppAppearance.green : AppAppearance.secondary)
                        .padding(.horizontal, 18).padding(.vertical, 14)
                } else {
                    if width >= Self.columns { columnHeader }
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(report.leftovers.enumerated()), id: \.element.id) { index, item in
                                if index > 0 || width >= Self.columns { Divider().overlay(AppAppearance.separator) }
                                row(item, now: context.date)
                            }
                        }
                    }
                }
                if !report.leftovers.isEmpty || !health.ignored.isEmpty {
                    Divider().overlay(AppAppearance.separator)
                    footer
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(AppCardSurface())
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        }
    }
    private var nameWidth: CGFloat {
        max(150, (width - 36 - 4 * 14 - Self.ageWidth - Self.memoryWidth - Self.actionsWidth) * 0.38)
    }
    private var columnHeader: some View {
        HStack(spacing: 14) {
            MacHealthLabel("Process").frame(width: nameWidth, alignment: .leading)
            MacHealthLabel("Why it’s flagged").frame(maxWidth: .infinity, alignment: .leading)
            MacHealthLabel("Age").frame(width: Self.ageWidth, alignment: .trailing)
            MacHealthLabel("Memory").frame(width: Self.memoryWidth, alignment: .trailing)
            Color.clear.frame(width: Self.actionsWidth, height: 1)
        }
        .padding(.horizontal, 18).padding(.top, 11).padding(.bottom, 8)
        .accessibilityHidden(true)
    }
    @ViewBuilder private func row(_ item: Leftover, now: Date) -> some View {
        let age = LeftoverPolicy.duration(now.timeIntervalSince(item.started))
        if width >= Self.columns {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                identity(item, now: now).frame(width: nameWidth, alignment: .leading)
                why(item).frame(maxWidth: .infinity, alignment: .leading)
                Text(age).foregroundStyle(AppAppearance.secondary).monospacedDigit().frame(width: Self.ageWidth, alignment: .trailing)
                Text(HealthFormat.bytes(item.memory)).monospacedDigit().frame(width: Self.memoryWidth, alignment: .trailing)
                actions(item).frame(width: Self.actionsWidth, alignment: .trailing)
            }
            .padding(.horizontal, 18).padding(.vertical, 11)
            .accessibilityElement(children: .contain)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    identity(item, now: now)
                    Spacer(minLength: 8)
                    actions(item)
                }
                why(item)
                Text("\(age) · \(HealthFormat.bytes(item.memory))").font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .accessibilityElement(children: .contain)
        }
    }
    private func identity(_ item: Leftover, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            if !item.folder.isEmpty {
                Text(Self.place(item)).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
        .help("\(item.kind.title). \(HealthFormat.facts(item, now: now))\(item.folder.isEmpty ? "" : "\n\(item.folder)")")
    }
    /// The folder's last component for a process ("support-console"), or the simulator's own line ("No apps running").
    static func place(_ item: Leftover) -> String {
        guard case .process = item.target, item.folder.hasPrefix("/") || item.folder.hasPrefix("~") else { return item.folder }
        return item.folder == "~" ? "~" : (item.folder.split(separator: "/").last.map(String.init) ?? item.folder)
    }
    private func why(_ item: Leftover) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.reason).foregroundStyle(AppAppearance.secondary).fixedSize(horizontal: false, vertical: true)
            if let chat = health.leftoverChats[item.id] {
                Button { health.openChat(chat.id) } label: {
                    Label(chat.title, systemImage: "bubble.left").font(.system(size: 12)).lineLimit(1)
                        .foregroundStyle(AppAppearance.text).underline(color: AppAppearance.hairline)
                }
                .buttonStyle(.plain)
                .help("Show the chat this belongs to")
            }
        }
    }
    @ViewBuilder private func actions(_ item: Leftover) -> some View {
        HStack(spacing: 4) {
            if health.acting.contains(item.id) {
                ProgressView().controlSize(.small).accessibilityLabel("Stopping \(item.name)")
            } else {
                Button(health.actionTitle(item)) { health.review(item) }.lineLimit(1).fixedSize()
                    .help("Asks before doing anything")
                    .accessibilityLabel("\(health.actionTitle(item).replacingOccurrences(of: "…", with: "")) \(item.name)")
            }
            Menu {
                Button("Ignore") { health.ignore(item) }
                if item.pid != nil { Button("Copy PID") { health.copyPID(item) } }
                if item.folder.hasPrefix("/") || item.folder.hasPrefix("~") { Button("Show Folder in Finder") { health.reveal(item) } }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More actions").accessibilityLabel("More actions for \(item.name)")
        }
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Text("Stop asks first, then sends a quit request; if it is ignored, Force Quit is offered.")
                .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if !health.ignored.isEmpty {
                Button("Show \(health.ignored.count) ignored") { health.resetIgnored() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                    .help("Stop ignoring them; anything still running reappears on the next check")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }
}

/// A compact process table row shared by the two side cards.
private struct MacHealthProcessRow<Middle: View>: View {
    var name: String
    var cpu: Double?
    var memory: UInt64?
    /// A fixed name column when a middle column follows; nil lets the name take the room.
    var nameWidth: CGFloat? = 84
    @ViewBuilder var middle: () -> Middle
    var body: some View {
        HStack(spacing: 10) {
            Text(name).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                .frame(minWidth: nameWidth, maxWidth: nameWidth ?? .infinity, alignment: .leading)
            middle()
            Text(cpu.map { "\(Int($0.rounded()))%" } ?? "—").monospacedDigit().lineLimit(1).fixedSize().frame(minWidth: 38, alignment: .trailing)
            Text(HealthFormat.bytes(memory)).monospacedDigit().foregroundStyle(AppAppearance.secondary).lineLimit(1).fixedSize()
                .frame(minWidth: 58, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }
}

struct MacHealthAgentsCard: View {
    var summary: AgentProcessSummary
    var openChat: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MacHealthLabel("Top by agents")
                Spacer()
                Text("CPU · memory").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
            }.padding(.bottom, 4)
            ForEach(Array(summary.top.enumerated()), id: \.element.id) { index, line in
                if index > 0 { Divider().overlay(AppAppearance.separator) }
                MacHealthProcessRow(name: line.name, cpu: line.cpuPercent, memory: line.memory) {
                    Button { openChat(line.chat.id) } label: {
                        Text(line.chat.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                            .underline(color: AppAppearance.hairline)
                    }
                    .buttonStyle(.plain).frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
                    .help("Show “\(line.chat.title)” in Burro")
                }
            }
            Text("Agents use \(Int(summary.cpuPercent.rounded()))% CPU and \(HealthFormat.bytes(summary.memory)) in all.")
                .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).padding(.top, 6)
                .help("\(summary.processes) process\(summary.processes == 1 ? "" : "es") under Claude Code chats whose process Burro has verified on this Mac. CPU is a share of one core.")
        }
        .padding(.horizontal, 18).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading).modifier(AppCardSurface())
    }
}

struct MacHealthBusiestCard: View {
    var report: LeftoverReport
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MacHealthLabel("Busiest now")
                Spacer()
                Text("CPU · memory").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
            }.padding(.bottom, 4)
            if report.busiest.isEmpty {
                Text("Measuring…").foregroundStyle(AppAppearance.secondary).padding(.vertical, 7)
            }
            ForEach(Array(report.busiest.enumerated()), id: \.element.id) { index, line in
                if index > 0 { Divider().overlay(AppAppearance.separator) }
                MacHealthProcessRow(name: line.name, cpu: line.cpuPercent, memory: line.memory, nameWidth: nil) { EmptyView() }
            }
            Text(report.agentProcesses > 0
                 ? "\(report.agentProcesses) Claude and Codex process\(report.agentProcesses == 1 ? " uses" : "es use") \(HealthFormat.bytes(report.agentMemory)) in all."
                 : "Your processes; CPU is a share of one core.")
                .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).padding(.top, 6)
        }
        .padding(.horizontal, 18).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading).modifier(AppCardSurface())
    }
}
