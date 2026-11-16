// The desktop home for this Mac's CPU, memory, swap, storage and anything left running after its work ended.
// This file holds the shared formatting helpers, the on-screen reader, and the page's shell: it samples only while
// the window is actually visible, and every stop goes through the confirmation dialog here. The page itself is
// MacHealthPage (MacHealthPage.swift), built from plain store values so it can be rendered with sample data.
import AppKit
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
         item.memory.map { bytes($0) }, item.children > 0 ? "\(item.children) child process\(item.children == 1 ? "" : "es")" : nil]
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

/// Reports whether the hosting window is actually on screen: not covered, minimized, hidden, or on a sleeping or locked display.
struct WindowOcclusionReader: NSViewRepresentable {
    var onChange: (Bool) -> Void
    func makeNSView(context: Context) -> ReaderView { ReaderView(onChange: onChange) }
    func updateNSView(_ view: ReaderView, context: Context) { view.onChange = onChange }
    final class ReaderView: NSView {
        var onChange: (Bool) -> Void
        private var observer: NSObjectProtocol?
        private var reported: Bool?
        init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = window.map { window in
                NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
        }
        private func report() {
            let visible = window?.occlusionState.contains(.visible) == true
            guard visible != reported else { return }
            reported = visible
            // Defer so SwiftUI state never changes inside its own view update.
            DispatchQueue.main.async { [onChange] in onChange(visible) }
        }
    }
}

struct MacHealthView: View {
    @Bindable var health: MacHealthStore
    var keepAwake: KeepAwakeStore
    @State private var onScreen = false
    var body: some View {
        MacHealthPage(health: health, keepAwake: keepAwake)
            .background(WindowOcclusionReader { onScreen = $0 })
            .task(id: onScreen) { if onScreen { await health.observe() } }
            .confirmationDialog(health.pending.map(health.confirmTitle) ?? "", isPresented: Binding(get: { health.pending != nil }, set: { if !$0 { health.pending = nil } }),
                                titleVisibility: .visible, presenting: health.pending) { item in
                Button(health.confirmVerb(item), role: .destructive) { health.confirm(item) }
                Button("Cancel", role: .cancel) { health.pending = nil }
            } message: { item in Text(health.confirmMessage(item)) }
    }
}

/// The words for stopping a leftover, shared by its row and the confirmation dialog.
extension MacHealthStore {
    func actionTitle(_ item: Leftover) -> String {
        if case .simulator = item.target { return "Shut Down…" }
        return stubborn.contains(item.id) ? "Force Quit…" : "Stop…"
    }
    func confirmVerb(_ item: Leftover) -> String {
        if case .simulator = item.target { return "Shut Down" }
        return stubborn.contains(item.id) ? "Force Quit" : "Stop"
    }
    func confirmTitle(_ item: Leftover) -> String {
        if case .simulator = item.target { return "Shut down \(item.name)?" }
        return "\(stubborn.contains(item.id) ? "Force quit" : "Stop") \(item.name)?"
    }
    func confirmMessage(_ item: Leftover) -> String {
        switch item.target {
        case .simulator: return "Apps running in this simulator will quit. You can boot it again from Xcode."
        case .process(let pid, _, _):
            let children = item.children > 0 ? " Its \(item.children) child process\(item.children == 1 ? "" : "es") usually exit with it." : ""
            if stubborn.contains(item.id) {
                return "Force Quit stops PID \(pid) immediately without letting it clean up.\(children)"
            }
            return "Burro asks PID \(pid) to quit, after checking it is still the same process. Unsaved work in it may be lost.\(children)"
        }
    }
}
