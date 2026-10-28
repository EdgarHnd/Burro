// The desktop home for this Mac's CPU, memory, swap, storage and anything left running after its work ended.
import SwiftUI
import BurroCore

extension HealthLevel {
    var color: Color {
        switch self { case .normal: AppAppearance.green; case .elevated: AppAppearance.amber; case .critical: .red }
    }
    var title: String {
        switch self { case .normal: "Healthy"; case .elevated: "Under pressure"; case .critical: "Critical" }
    }
}
extension LeftoverKind {
    var symbol: String {
        switch self {
        case .runaway: "flame"
        case .watcher: "eye"
        case .devServer: "server.rack"
        case .agentScript: "terminal"
        case .orphan: "person.fill.questionmark"
        case .simulator: "iphone"
        }
    }
}
enum HealthFormat {
    static func bytes(_ value: UInt64?, file: Bool = false) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: file ? .file : .memory)
    }
    static func percent(_ fraction: Double?) -> String { fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }
    static func fraction(_ part: UInt64, of whole: UInt64) -> Double? { whole > 0 ? Double(part) / Double(whole) : nil }
    static func facts(_ item: Leftover, now: Date) -> String {
        [item.pid.map { "PID \($0)" }, "up \(LeftoverPolicy.duration(now.timeIntervalSince(item.started)))",
         item.cpuTime.map { "\(LeftoverPolicy.duration($0)) of CPU" }, item.cpuPercent.map { "\(Int($0.rounded()))% CPU now" },
         item.resident.map { bytes($0) }, item.children > 0 ? "\(item.children) child process\(item.children == 1 ? "" : "es")" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
struct HealthBar: View {
    var fraction: Double?
    var level: HealthLevel
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(AppAppearance.raised).frame(height: height)
                if let fraction {
                    Capsule().fill(level == .normal ? LinearGradient(colors: [AppAppearance.green, AppAppearance.lime], startPoint: .leading, endPoint: .trailing)
                                   : LinearGradient(colors: [level.color.opacity(0.8), level.color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * min(1, max(0, fraction)), height: height)
                }
            }.frame(height: height)
        }.frame(height: height).accessibilityHidden(true)
    }
}

struct MacHealthView: View {
    @Bindable var health: MacHealthStore
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Mac Health").font(AppAppearance.pageTitle)
                    Text("CPU, memory and storage, plus anything still running after its work ended.").font(.caption).foregroundStyle(AppAppearance.secondary)
                }
                Spacer()
                if health.sampling { ProgressView().controlSize(.small).accessibilityLabel("Sampling") }
                Button { Task { await health.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(health.sampling)
            }.padding(Layout.inset)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let message = health.message {
                        HStack { Label(message, systemImage: "info.circle"); Spacer(); Button { health.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                            .font(.callout).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let snapshot = health.snapshot {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                            metrics(snapshot)
                        }
                        notices(snapshot)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                            ForEach(0..<4) { _ in
                                VStack(alignment: .leading, spacing: 14) {
                                    RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 90, height: 14)
                                    RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 120, height: 22)
                                    RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(height: 6)
                                }.padding(16).modifier(AppCardSurface())
                            }
                        }.accessibilityLabel("Loading Mac health")
                    }
                    leftovers
                    busiest
                    Text("Sampled every 3 seconds while Mac Health or the notch Mac tab is open. Monitoring is read-only; Burro stops a process or simulator only after you confirm, and only if it is still the same one.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(Layout.inset).frame(maxWidth: 1060).frame(maxWidth: .infinity)
            }
        }
        .modifier(AppTheme())
        .task { await health.observe() }
        .confirmationDialog(health.pending.map(confirmTitle) ?? "", isPresented: Binding(get: { health.pending != nil }, set: { if !$0 { health.pending = nil } }),
                            titleVisibility: .visible, presenting: health.pending) { item in
            Button(confirmVerb(item), role: .destructive) { health.confirm(item) }
            Button("Cancel", role: .cancel) { health.pending = nil }
        } message: { item in Text(confirmMessage(item)) }
    }
    @ViewBuilder private func metrics(_ snapshot: MacHealthSnapshot) -> some View {
        metricCard("CPU", symbol: "cpu", value: HealthFormat.percent(snapshot.cpuBusy),
            detail: snapshot.load.isEmpty ? "\(snapshot.cores) cores" : "Load \(snapshot.load.map { $0.formatted(.number.precision(.fractionLength(1))) }.joined(separator: " · ")) on \(snapshot.cores) cores",
            fraction: snapshot.cpuBusy, level: snapshot.cpuLevel)
        if let memory = snapshot.memory {
            metricCard("Memory", symbol: "memorychip", value: "\(HealthFormat.bytes(memory.used)) of \(HealthFormat.bytes(memory.total))",
                detail: "Pressure \(memory.pressure.rawValue.lowercased()) · \(HealthFormat.bytes(memory.compressed)) compressed · \(HealthFormat.bytes(memory.cached)) cached",
                fraction: HealthFormat.fraction(memory.used, of: memory.total), level: snapshot.memoryLevel)
            metricCard("Swap", symbol: "arrow.left.arrow.right", value: memory.swapUsed == 0 ? "None" : HealthFormat.bytes(memory.swapUsed),
                detail: memory.swapTotal == 0 ? "No swap files in use" : "of \(HealthFormat.bytes(memory.swapTotal)) in swap files; macOS grows them as needed",
                fraction: HealthFormat.fraction(memory.swapUsed, of: memory.swapTotal), level: snapshot.swapLevel)
        }
        if let storage = snapshot.storage {
            metricCard("Storage", symbol: "internaldrive", value: "\(HealthFormat.bytes(storage.available, file: true)) free",
                detail: "of \(HealthFormat.bytes(storage.total, file: true)) on the startup disk, including purgeable space",
                fraction: HealthFormat.fraction(storage.total - min(storage.total, storage.available), of: storage.total), level: snapshot.storageLevel)
        }
    }
    private func metricCard(_ title: String, symbol: String, value: String, detail: String, fraction: Double?, level: HealthLevel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: symbol).font(AppAppearance.sectionTitle)
                Spacer()
                if level != .normal { Text(level.title).font(.caption.weight(.semibold)).foregroundStyle(level.color) }
            }
            Text(value).font(AppAppearance.metric).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            HealthBar(fraction: fraction, level: level)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).modifier(AppCardSurface())
            .accessibilityElement(children: .combine)
    }
    @ViewBuilder private func notices(_ snapshot: MacHealthSnapshot) -> some View {
        if snapshot.thermal != .nominal {
            Label("Thermal state is \(snapshot.thermal.rawValue.lowercased()). macOS may slow the CPU to cool down.", systemImage: "thermometer.high")
                .font(.callout).foregroundStyle(snapshot.thermalLevel.color)
        }
        if snapshot.restartSuggested(now: snapshot.sampledAt), let booted = snapshot.bootedAt, let memory = snapshot.memory {
            Label("Up \(LeftoverPolicy.duration(snapshot.sampledAt.timeIntervalSince(booted))) with \(HealthFormat.bytes(memory.swapUsed)) in swap. Restarting clears swap and stale memory.",
                  systemImage: "arrow.clockwise.circle").font(.callout).foregroundStyle(.secondary)
        }
    }
    private var leftovers: some View {
        let report = health.report
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Left running").font(AppAppearance.sectionTitle)
                if !report.leftovers.isEmpty {
                    Text("\(report.leftovers.count) · \(HealthFormat.bytes(report.reclaimable))").font(.caption.monospacedDigit()).foregroundStyle(AppAppearance.amber)
                }
                Spacer()
                if !health.ignored.isEmpty {
                    Button("Show \(health.ignored.count) ignored") { health.resetIgnored() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        .help("Stop ignoring them; anything still running reappears on the next sample")
                }
            }
            if report.leftovers.isEmpty {
                Label(report.complete ? "Nothing left running." : "Checking processes…", systemImage: report.complete ? "checkmark.circle" : "ellipsis")
                    .font(.callout).foregroundStyle(report.complete ? AppAppearance.green : .secondary)
            }
            ForEach(Array(report.leftovers.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider() }
                leftoverRow(item)
            }
        }.padding(16).modifier(AppCardSurface())
    }
    private func leftoverRow(_ item: Leftover) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ProviderBadge(symbol: item.kind.symbol, color: item.kind == .runaway ? .red : AppAppearance.raised, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(item.kind.title).font(.caption.weight(.semibold)).foregroundStyle(AppAppearance.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(AppAppearance.raised, in: Capsule())
                }
                Text(item.reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(HealthFormat.facts(item, now: context.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if !item.folder.isEmpty {
                    Text(item.folder).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled).help(item.folder)
                }
            }
            Spacer(minLength: 8)
            if health.acting.contains(item.id) {
                ProgressView().controlSize(.small).accessibilityLabel("Stopping \(item.name)")
            } else {
                Button(actionTitle(item), role: .destructive) { health.review(item) }
            }
            Menu {
                Button("Ignore") { health.ignore(item) }
                if item.pid != nil { Button("Copy PID") { health.copyPID(item) } }
                if item.folder.hasPrefix("/") || item.folder.hasPrefix("~") { Button("Show folder in Finder") { health.reveal(item) } }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("More actions for \(item.name)")
        }
    }
    private var busiest: some View {
        let report = health.report
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Busiest now").font(AppAppearance.sectionTitle)
                Spacer()
                Text("Your processes · CPU of one core").font(.caption).foregroundStyle(.secondary)
            }
            if report.busiest.isEmpty {
                Text("Measuring…").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(report.busiest) { line in
                HStack {
                    Text(line.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(line.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "—").monospacedDigit().frame(width: 60, alignment: .trailing)
                    Text(HealthFormat.bytes(line.resident)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                }.font(.callout)
            }
            if report.agentProcesses > 0 {
                Divider()
                Label("\(report.agentProcesses) Claude and Codex process\(report.agentProcesses == 1 ? " is" : "es are") using \(HealthFormat.bytes(report.agentMemory)). Closing or archiving idle chats in their apps frees it.",
                      systemImage: "person.2").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).modifier(AppCardSurface())
    }
    private func actionTitle(_ item: Leftover) -> String {
        if case .simulator = item.target { return "Shut Down…" }
        return health.stubborn.contains(item.id) ? "Force Quit…" : "Stop…"
    }
    private func confirmVerb(_ item: Leftover) -> String {
        if case .simulator = item.target { return "Shut Down" }
        return health.stubborn.contains(item.id) ? "Force Quit" : "Stop"
    }
    private func confirmTitle(_ item: Leftover) -> String {
        if case .simulator = item.target { return "Shut down \(item.name)?" }
        return "\(health.stubborn.contains(item.id) ? "Force quit" : "Stop") \(item.name)?"
    }
    private func confirmMessage(_ item: Leftover) -> String {
        switch item.target {
        case .simulator: return "Apps running in this simulator will quit. You can boot it again from Xcode."
        case .process(let pid, _, _):
            let children = item.children > 0 ? " Its \(item.children) child process\(item.children == 1 ? "" : "es") usually exit with it." : ""
            if health.stubborn.contains(item.id) {
                return "Force Quit stops PID \(pid) immediately without letting it clean up.\(children)"
            }
            return "Burro asks PID \(pid) to quit, after checking it is still the same process. Unsaved work in it may be lost.\(children)"
        }
    }
}
