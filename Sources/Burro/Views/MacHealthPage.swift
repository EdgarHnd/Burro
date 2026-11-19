// The Mac Health page in the dashboard layout (Today's): the shared page header with
// `MacHealthHeadline` as its sentence (the title amber only while a vital is high or worse) and the
// refresh button trailing; the store's message line; a strip of four vitals (CPU, Memory pressure,
// Swap, Disk: the value, the verdict word, a sparkline of the samples taken while a Mac view was on
// screen, the unit underneath, load, pressure and the history caption in help); then one joined
// surface whose main row is 2:1, stacked below Today's 880 points: Left running (with its Stop… /
// Force Quit… / Shut Down… confirmations, Ignore, Copy PID, Show Folder and "Show N ignored") beside
// a column of stacked panels: Keep awake, Top by agents (only when agent chats run processes) and
// Busiest now. It only reads store values; sampling and stopping are owned by MacHealthView and
// MacHealthStore. `MacHealthPageContent` takes no scroll view, so snapshot tests can size it.
import SwiftUI
import BurroCore

struct MacHealthPage: View {
    var health: MacHealthStore
    var keepAwake: KeepAwakeStore
    var body: some View {
        ScrollView {
            MacHealthPageContent(health: health, keepAwake: keepAwake)
                .padding(.horizontal, 36).padding(.vertical, 28)
                .frame(maxWidth: 1240).frame(maxWidth: .infinity)
        }
        .modifier(AppTheme())
    }
}

struct MacHealthPageContent: View {
    var health: MacHealthStore
    var keepAwake: KeepAwakeStore
    /// Below this content width the main row stacks (Today's breakpoint).
    nonisolated static var mainStackBelow: CGFloat { 880 }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Mac Health", inset: 0, eyebrow: "This Mac", sentence: sentence, top: 0, bottom: 0) { refresh }
            if let message = health.message {
                HStack {
                    Label(message, systemImage: "info.circle").fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { health.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        .accessibilityLabel("Dismiss message").help("Dismiss")
                }
                .font(.system(size: 13)).foregroundStyle(AppAppearance.secondary).padding(12)
                .background(AppAppearance.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            StatStrip(cells: cells)
                .accessibilityElement(children: health.snapshot == nil ? .ignore : .contain)
                .accessibilityLabel(health.snapshot == nil ? "Loading Mac health" : "Vitals")
            JoinedPanels {
                JoinedRow(weights: [2, 1], stackBelow: Self.mainStackBelow) {
                    MacHealthLeftoversSection(health: health)
                    // The side panels, always stacked, with hairlines between them.
                    JoinedRow(weights: [], stackBelow: .infinity) {
                        KeepAwakeCard(keepAwake: keepAwake)
                        if !health.agents.top.isEmpty {
                            MacHealthAgentsCard(summary: health.agents) { health.openChat($0) }
                        }
                        MacHealthBusiestCard(report: health.report)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sentence: [TextRun] {
        let report = health.report
        let headline = MacHealthHeadline.make(snapshot: health.snapshot, leftovers: report.leftovers.count, leftoverMemory: report.reclaimable,
                                              leftoversKnown: report.complete, bytes: { HealthFormat.bytes($0) })
        return MacHealthComposition.sentence(headline, strained: MacHealthComposition.strained(health.snapshot))
    }

    @ViewBuilder private var refresh: some View {
        if health.refreshing {
            ProgressView().controlSize(.small).accessibilityLabel("Refreshing")
        } else {
            Button { Task { await health.refresh(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                .help("Check again now. Mac Health updates every few seconds while it is on screen; the process list every 15 seconds.")
                .accessibilityLabel("Refresh")
        }
    }

    /// The strip: each vital's verdict word after its sparkline (the newest bar in the verdict's colour
    /// when high), the unit as a footnote, and the history caption added to its help.
    private var cells: [StatCellData] {
        let snapshot = health.snapshot, history = health.history
        let memoryBytes: (UInt64) -> String = { HealthFormat.bytes($0) }
        let diskBytes: (UInt64) -> String = { HealthFormat.bytes($0, file: true) }
        let stats = MacHealthComposition.stats(snapshot, bytes: memoryBytes, fileBytes: diskBytes,
                                               load: { $0.map { $0.formatted(.number.precision(.fractionLength(1))) }.joined(separator: " · ") })
        return stats.map { stat in
            let vital = MacVital(rawValue: stat.id) ?? .cpu
            let verdict = snapshot?.verdict(vital)
            let bars = history.bars(vital, count: MacHealthSparkline.stripSlots)
            let scale = vital == .swap ? max(Double(1 << 30), (bars.compactMap { $0 }.max() ?? 0) * 1.15) : 1
            let caption = history.caption(vital, bytes: vital == .disk ? diskBytes : memoryBytes)
            var cell = StatCellData(id: stat.id, label: stat.label, value: stat.value, muted: stat.unknown, sub: stat.sub,
                                    help: stat.help + (history.isEmpty ? "" : "\nHistory: \(caption)"))
            if snapshot != nil {
                cell.accessory = AnyView(MacHealthSparkline(values: bars, scale: scale, accent: (verdict ?? .fine) >= .high ? (verdict ?? .fine).color : AppAppearance.secondary,
                                                            height: 14, slots: MacHealthSparkline.stripSlots, spacing: 1.5).frame(width: 64))
            }
            if let footnote = stat.footnote {
                cell.footer = AnyView(Text(footnote).font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.tertiary).lineLimit(1))
            }
            return cell
        }
    }
}

/// The small uppercase label Mac Health uses for card and section titles.
struct MacHealthLabel: View {
    var text: String
    var color: Color = AppAppearance.tertiary
    init(_ text: String, color: Color = AppAppearance.tertiary) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(color)
    }
}

extension VitalVerdict {
    var color: Color {
        switch self {
        case .fine: AppAppearance.green
        case .moderate: AppAppearance.secondary
        case .high: AppAppearance.amber
        // No red on the page: critical reads amber like high, with its own word.
        case .critical: AppAppearance.amber
        }
    }
}

/// Bars of recent samples, newest on the right; the newest bar carries the card's accent.
struct MacHealthSparkline: View {
    static let slots = 30
    /// Fewer, wider bars in the strip's sub-line.
    static let stripSlots = 18
    var values: [Double?]
    var scale: Double
    var accent: Color
    var height: CGFloat = 32
    var slots = Self.slots
    var spacing: CGFloat = 2
    var body: some View {
        let padded = Array(repeating: Double?.none, count: max(0, slots - values.count)) + values.suffix(slots)
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(Array(padded.enumerated()), id: \.offset) { index, value in
                if let value {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(index == padded.count - 1 ? accent : AppAppearance.hairline)
                        .frame(height: max(2, height * min(1, max(0, value / max(scale, .leastNonzeroMagnitude)))))
                        .frame(maxWidth: .infinity)
                } else {
                    Color.clear.frame(height: 2).frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityHidden(true)
    }
}
