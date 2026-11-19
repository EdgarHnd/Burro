// Mac Health's "Left running" panel and its side panels (cells of the page's joined surface). Each leftover row shows what it is and where, why Burro
// flagged it (with the chat it belongs to when Burro can tell), how long it has run, its memory, and Stop…, which
// only opens the confirmation dialog. "Top by agents" lists the processes running under this Mac's agent chats;
// when there are none, "Busiest now" lists the busiest processes instead.
import SwiftUI
import BurroCore

struct MacHealthLeftoversSection: View {
    var health: MacHealthStore
    /// Below this the rows stack instead of lining up in columns.
    nonisolated static var columns: CGFloat { 720 }
    var body: some View {
        let report = health.report
        Panel(title: "Left running", subtitle: subtitle(report)) {
            if report.reclaimable > 0 {
                Text("\(HealthFormat.bytes(report.reclaimable)) in all").font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if report.leftovers.isEmpty {
                    Label(report.complete ? "Nothing left running." : "Checking processes…", systemImage: report.complete ? "checkmark.circle" : "ellipsis")
                        .font(.system(size: 13)).foregroundStyle(AppAppearance.secondary).padding(.vertical, 4)
                } else {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        // Columns when they fit, else stacked rows; decided by layout, not by a measured width.
                        ViewThatFits(in: .horizontal) {
                            table(report.leftovers, columns: true, now: context.date).frame(minWidth: Self.columns)
                            table(report.leftovers, columns: false, now: context.date)
                        }
                    }
                }
                if !report.leftovers.isEmpty || !health.ignored.isEmpty {
                    Rectangle().fill(AppAppearance.separator).frame(height: 1).padding(.top, report.leftovers.isEmpty ? 10 : 0)
                    footer
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func table(_ items: [Leftover], columns: Bool, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if columns { columnHeader }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 || columns { Rectangle().fill(AppAppearance.separator).frame(height: 1) }
                row(item, columns: columns, now: now)
            }
        }
    }
    /// The count in amber (the page's warning for leftovers, as before), or what the list is for.
    private func subtitle(_ report: LeftoverReport) -> [TextRun] {
        guard !report.leftovers.isEmpty else {
            return [TextRun("Dev servers, watchers, simulators and scripts your work left behind")]
        }
        let count = report.leftovers.count
        return [TextRun("\(count) thing\(count == 1 ? "" : "s") left running", .needsYou),
                TextRun(" · each asks before it stops")]
    }
    private var columnHeader: some View {
        LeftoverColumnsLayout {
            MacHealthLabel("Process").frame(maxWidth: .infinity, alignment: .leading)
            MacHealthLabel("Why it’s flagged").frame(maxWidth: .infinity, alignment: .leading)
            MacHealthLabel("Age").frame(maxWidth: .infinity, alignment: .trailing)
            MacHealthLabel("Memory").frame(maxWidth: .infinity, alignment: .trailing)
            Color.clear.frame(height: 1)
        }
        .padding(.bottom, 8)
        .accessibilityHidden(true)
    }
    @ViewBuilder private func row(_ item: Leftover, columns: Bool, now: Date) -> some View {
        let age = LeftoverPolicy.duration(now.timeIntervalSince(item.started))
        if columns {
            LeftoverColumnsLayout {
                identity(item, now: now).frame(maxWidth: .infinity, alignment: .leading)
                why(item).frame(maxWidth: .infinity, alignment: .leading)
                Text(age).foregroundStyle(AppAppearance.secondary).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                Text(HealthFormat.bytes(item.memory)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                actions(item).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.vertical, 11)
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
            .padding(.vertical, 11)
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
        .padding(.top, 10)
    }
}

/// Left running's columns: the process (38% of what the fixed columns leave, at least 150), why it's
/// flagged (the rest), then age, memory and the actions at fixed widths; children are top-aligned.
/// Widths come from the proposal, so the table never feeds a measured width back into its layout.
struct LeftoverColumnsLayout: SwiftUI.Layout {
    static let spacing: CGFloat = 14
    static let fixed: [CGFloat] = [56, 70, 132]
    func widths(_ total: CGFloat) -> [CGFloat] {
        let flexible = max(0, total - Self.fixed.reduce(0, +) - Self.spacing * 4)
        let name = max(150, flexible * 0.38)
        return [name, max(0, flexible - name)] + Self.fixed
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 720
        let heights = zip(subviews, widths(width)).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
        return CGSize(width: width, height: heights.max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(bounds.width)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: nil))
            x += width + Self.spacing
        }
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
        Panel(title: "Top by agents", subtitle: [TextRun("Processes your agent chats are running")]) {
            Text("CPU · memory").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(summary.top.enumerated()), id: \.element.id) { index, line in
                    if index > 0 { Rectangle().fill(AppAppearance.separator).frame(height: 1) }
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
        }
    }
}

struct MacHealthBusiestCard: View {
    var report: LeftoverReport
    var body: some View {
        Panel(title: "Busiest now", subtitle: [TextRun("Your busiest processes")]) {
            Text("CPU · memory").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if report.busiest.isEmpty {
                    Text("Measuring…").font(.system(size: 13)).foregroundStyle(AppAppearance.secondary).padding(.vertical, 7)
                }
                ForEach(Array(report.busiest.enumerated()), id: \.element.id) { index, line in
                    if index > 0 { Rectangle().fill(AppAppearance.separator).frame(height: 1) }
                    MacHealthProcessRow(name: line.name, cpu: line.cpuPercent, memory: line.memory, nameWidth: nil) { EmptyView() }
                }
                Text(report.agentProcesses > 0
                     ? "\(report.agentProcesses) Claude and Codex process\(report.agentProcesses == 1 ? " uses" : "es use") \(HealthFormat.bytes(report.agentMemory)) in all."
                     : "CPU is a share of one core.")
                    .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).padding(.top, 6)
            }
        }
    }
}
