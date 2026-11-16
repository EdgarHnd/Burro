// The Mac Health page: a headline that answers "is this Mac all right?", a row of vitals (CPU, memory pressure,
// swap, disk) each with its value, a one-word verdict and a sparkline of the samples taken while a Mac view was on
// screen, then what was left running beside a side column: the Keep awake card, the processes agent chats are
// running (when there are any), and "Busiest now" (the busiest of your processes) beneath them.
// It only reads store values; sampling and stopping are owned by MacHealthView and MacHealthStore.
import SwiftUI
import BurroCore

struct MacHealthPage: View {
    var health: MacHealthStore
    var keepAwake: KeepAwakeStore
    @State private var width: CGFloat = 1200
    /// Below this the side column moves under the list.
    static let twoColumns: CGFloat = 900
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let message = health.message {
                    HStack {
                        Label(message, systemImage: "info.circle").fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button { health.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                            .accessibilityLabel("Dismiss message").help("Dismiss")
                    }.font(.callout).padding(12).modifier(AppCardSurface(radius: 10))
                }
                MacHealthVitalsRow(snapshot: health.snapshot, history: health.history)
                if width >= Self.twoColumns {
                    HStack(alignment: .top, spacing: 16) {
                        MacHealthLeftoversSection(health: health).frame(maxWidth: .infinity)
                        side.frame(width: 340)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        MacHealthLeftoversSection(health: health)
                        side
                    }
                }
            }
            .padding(.horizontal, width < 600 ? 16 : 28).padding(.top, 30).padding(.bottom, 36)
            .frame(maxWidth: 1240).frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .modifier(AppTheme())
    }
    private var headline: MacHealthHeadline {
        let report = health.report
        return MacHealthHeadline.make(snapshot: health.snapshot, leftovers: report.leftovers.count, leftoverMemory: report.reclaimable,
                                      leftoversKnown: report.complete, bytes: { HealthFormat.bytes($0) })
    }
    private var header: some View {
        let headline = headline
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(headline.title).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(AppAppearance.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !headline.detail.isEmpty {
                    Text(headline.detail).font(.system(size: 15)).foregroundStyle(AppAppearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Group {
                if health.refreshing {
                    ProgressView().controlSize(.small).accessibilityLabel("Refreshing")
                } else {
                    Button { Task { await health.refresh(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Check again now. Mac Health updates every few seconds while it is on screen; the process list every 15 seconds.")
                        .accessibilityLabel("Refresh")
                }
            }.padding(.top, 6)
        }
    }
    private var side: some View {
        VStack(alignment: .leading, spacing: 16) {
            KeepAwakeCard(keepAwake: keepAwake)
            if !health.agents.top.isEmpty {
                MacHealthAgentsCard(summary: health.agents) { health.openChat($0) }
            }
            MacHealthBusiestCard(report: health.report)
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
        case .critical: .red
        }
    }
}

// MARK: Vitals

struct MacHealthVitalsRow: View {
    var snapshot: MacHealthSnapshot?
    var history: MacHealthHistory
    @State private var width: CGFloat = 1200
    /// Four across when they fit, then two, then one, so a row never ends with an empty slot.
    private var columns: Int { width >= 4 * 220 + 3 * 14 ? 4 : (width >= 2 * 220 + 14 ? 2 : 1) }
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns), spacing: 14) {
            if let snapshot {
                cards(snapshot)
            } else {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 12) {
                        RoundedRectangle(cornerRadius: 4).fill(AppAppearance.raised).frame(width: 90, height: 12)
                        RoundedRectangle(cornerRadius: 4).fill(AppAppearance.raised).frame(width: 120, height: 24)
                        RoundedRectangle(cornerRadius: 4).fill(AppAppearance.raised).frame(height: 32)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).modifier(AppCardSurface())
                }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .accessibilityElement(children: snapshot == nil ? .ignore : .contain)
        .accessibilityLabel(snapshot == nil ? "Loading Mac health" : "Vitals")
    }
    @ViewBuilder private func cards(_ snapshot: MacHealthSnapshot) -> some View {
        let memoryBytes: (UInt64) -> String = { HealthFormat.bytes($0) }
        let diskBytes: (UInt64) -> String = { HealthFormat.bytes($0, file: true) }
        MacHealthVitalCard(title: "CPU", verdict: snapshot.verdict(.cpu), vital: .cpu,
            value: HealthFormat.percent(snapshot.cpuBusy), unit: "of \(snapshot.cores) cores",
            bars: history.bars(.cpu, count: MacHealthSparkline.slots), scale: 1,
            caption: history.caption(.cpu, bytes: memoryBytes),
            help: snapshot.load.isEmpty ? "" : "Load \(snapshot.load.map { $0.formatted(.number.precision(.fractionLength(1))) }.joined(separator: " · ")) over 1, 5 and 15 minutes on \(snapshot.cores) cores")
        if let memory = snapshot.memory {
            MacHealthVitalCard(title: "Memory pressure", verdict: snapshot.verdict(.memory), vital: .memory,
                value: HealthFormat.bytes(memory.used), unit: "of \(HealthFormat.bytes(memory.total)) used",
                bars: history.bars(.memory, count: MacHealthSparkline.slots), scale: 1,
                caption: history.caption(.memory, bytes: memoryBytes),
                help: "Pressure \(memory.pressure.rawValue.lowercased()) · \(HealthFormat.bytes(memory.compressed)) compressed · \(HealthFormat.bytes(memory.cached)) cached")
            let swapBars = history.bars(.swap, count: MacHealthSparkline.slots)
            MacHealthVitalCard(title: "Swap", verdict: snapshot.verdict(.swap), vital: .swap,
                value: memory.swapUsed == 0 ? "None" : HealthFormat.bytes(memory.swapUsed), unit: memory.swapUsed == 0 ? "" : "in use",
                bars: swapBars, scale: max(Double(1 << 30), (swapBars.compactMap { $0 }.max() ?? 0) * 1.15),
                caption: history.caption(.swap, bytes: memoryBytes),
                help: memory.swapTotal == 0 ? "No swap files in use" : "\(HealthFormat.bytes(memory.swapTotal)) in swap files; macOS grows them as needed")
        }
        if let storage = snapshot.storage {
            MacHealthVitalCard(title: "Disk", verdict: snapshot.verdict(.disk), vital: .disk,
                value: HealthFormat.bytes(storage.available, file: true), unit: "free of \(HealthFormat.bytes(storage.total, file: true))",
                bars: history.bars(.disk, count: MacHealthSparkline.slots), scale: 1,
                caption: history.caption(.disk, bytes: diskBytes),
                help: "Free space on the startup disk, including purgeable space; checked every minute")
        }
    }
}

struct MacHealthVitalCard: View {
    var title: String
    var verdict: VitalVerdict?
    var vital: MacVital
    var value: String
    var unit: String
    var bars: [Double?]
    var scale: Double
    var caption: String
    var help: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                MacHealthLabel(title)
                Spacer(minLength: 6)
                if let verdict {
                    Text(verdict.word(for: vital)).font(.system(size: 12, weight: .semibold)).foregroundStyle(verdict.color)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 26, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                if !unit.isEmpty { Text(unit).foregroundStyle(AppAppearance.tertiary).lineLimit(1) }
            }
            MacHealthSparkline(values: bars, scale: scale, accent: (verdict ?? .fine) >= .high ? (verdict ?? .fine).color : AppAppearance.secondary)
            Text(caption).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(AppCardSurface())
        .overlay {
            if let verdict, verdict >= .high {
                RoundedRectangle(cornerRadius: AppAppearance.cardRadius, style: .continuous).strokeBorder(verdict.color.opacity(0.45))
            }
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value) \(unit). \(verdict.map { $0.word(for: vital) } ?? ""). \(caption)")
    }
}

/// Bars of recent samples, newest on the right; the newest bar carries the card's accent.
struct MacHealthSparkline: View {
    static let slots = 30
    var values: [Double?]
    var scale: Double
    var accent: Color
    var height: CGFloat = 32
    var body: some View {
        let padded = Array(repeating: Double?.none, count: max(0, Self.slots - values.count)) + values.suffix(Self.slots)
        HStack(alignment: .bottom, spacing: 2) {
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
