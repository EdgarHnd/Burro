// Compact Mac resources beside agents; reviewing and stopping leftovers stays in the desktop page.
import SwiftUI
import BurroCore

struct NotchMacView: View {
    var health: MacHealthStore
    /// Samples only while the panel is expanded on this page and actually on screen.
    var active: Bool
    var onOpen: () -> Void
    @State private var onScreen = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let snapshot = health.snapshot {
                    VStack(spacing: 6) { rows(snapshot) }
                        .padding(.horizontal, 12).padding(.vertical, 9).modifier(AppCardSurface(translucent: true))
                    leftoverSummary
                    if snapshot.restartSuggested(now: snapshot.sampledAt), let booted = snapshot.bootedAt {
                        Label("Up \(LeftoverPolicy.duration(snapshot.sampledAt.timeIntervalSince(booted))) · a restart clears swap",
                              systemImage: "arrow.clockwise.circle").font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 4)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(0..<4) { _ in RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.06)).frame(height: 8) }
                    }.padding(14).modifier(AppCardSurface(translucent: true)).accessibilityLabel("Loading Mac health")
                }
            }.padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(AppAppearance.text)
        .background(WindowOcclusionReader { onScreen = $0 })
        .task(id: active && onScreen) { if active && onScreen { await health.observe() } }
    }
    @ViewBuilder private func rows(_ snapshot: MacHealthSnapshot) -> some View {
        row("CPU", fraction: snapshot.cpuBusy, value: HealthFormat.percent(snapshot.cpuBusy),
            detail: snapshot.load.first.map { "load \($0.formatted(.number.precision(.fractionLength(1))))" } ?? "", level: snapshot.cpuLevel)
        if let memory = snapshot.memory {
            row("Memory", fraction: HealthFormat.fraction(memory.used, of: memory.total), value: HealthFormat.bytes(memory.used),
                detail: memory.pressure == .normal ? "of \(HealthFormat.bytes(memory.total))" : "\(memory.pressure.rawValue.lowercased()) pressure",
                level: snapshot.memoryLevel)
            row("Swap", fraction: HealthFormat.fraction(memory.swapUsed, of: memory.swapTotal),
                value: memory.swapUsed == 0 ? "None" : HealthFormat.bytes(memory.swapUsed),
                detail: memory.swapTotal == 0 ? "" : "of \(HealthFormat.bytes(memory.swapTotal))", level: snapshot.swapLevel)
        }
        if let storage = snapshot.storage {
            row("Disk", fraction: HealthFormat.fraction(storage.total - min(storage.total, storage.available), of: storage.total),
                value: HealthFormat.bytes(storage.available, file: true), detail: "free", level: snapshot.storageLevel)
        }
    }
    private func row(_ title: String, fraction: Double?, value: String, detail: String, level: HealthLevel) -> some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(AppAppearance.secondary).lineLimit(1)
            Spacer(minLength: 4)
            HealthBar(fraction: fraction, level: level, height: 4).frame(width: 54)
            Text(value).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
                .foregroundStyle(level == .normal ? AppAppearance.text : level.color).frame(width: 62, alignment: .trailing)
            Text(detail).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).frame(width: 76, alignment: .trailing)
        }.font(.system(size: 11, weight: .semibold)).frame(minHeight: 19)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(title): \(value) \(detail)")
    }
    private var leftoverSummary: some View {
        let leftovers = health.report.leftovers
        return Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: leftovers.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(leftovers.isEmpty ? NotchStyle.accent : NotchStyle.attention)
                VStack(alignment: .leading, spacing: 3) {
                    Text(leftovers.isEmpty ? (health.report.complete ? "Nothing left running" : "Checking processes…")
                         : "\(leftovers.count) left running · \(HealthFormat.bytes(health.report.reclaimable))")
                        .font(.system(size: 11, weight: .semibold))
                    if !leftovers.isEmpty {
                        Text(leftovers.prefix(2).map(\.name).joined(separator: ", ") + (leftovers.count > 2 ? " +\(leftovers.count - 2)" : ""))
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
        }.buttonStyle(.plain).modifier(AppCardSurface(translucent: true))
            .help(leftovers.isEmpty ? "Open Mac Health in Burro" : "Review and stop leftovers in Burro")
    }
}
