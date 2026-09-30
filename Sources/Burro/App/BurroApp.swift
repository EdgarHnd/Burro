// The main dashboard, menu bar, and nonactivating agent notch share one app-owned store.
import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var notchController: NotchController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Set the running Dock image directly; Launch Services can retain an older bundle icon.
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let url = Bundle.main.url(forResource: name, withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) { notchController?.stop() }
}
@main struct BurroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore()
    @State private var notch = NotchController()
    var body: some Scene {
        WindowGroup("Burro", id: "main") {
            DesktopRootView(store: store, notch: notch)
                .onAppear { delegate.notchController = notch }
        }
        .defaultSize(width: 1240, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Repository…") { store.addRepository() }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button(store.filter == .usage ? "Refresh Usage" : "Refresh Worktrees") { Task { if store.filter == .usage { await store.refreshUsage(force: true) } else { await store.refresh() } } }.keyboardShortcut("r").disabled(store.filter == .usage ? store.checkingUsage : store.scanning)
                Button("Show Agent Notch") { notch.show() }.keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }
        MenuBarExtra {
            MonitorMenu(store: store, notch: notch)
        } label: {
            Label {
                Text(store.activeAgents.isEmpty ? "Burro" : "\(store.activeAgents.count)")
            } icon: { Text("🧈") }
        }
        Settings { SettingsView(store: store) }
    }
}
private struct DesktopRootView: View {
    var store: AppStore
    var notch: NotchController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        ContentView(store: store, notch: notch)
            .background(WindowProbe(onAttach: notch.registerDashboard))
            .task {
                store.start()
                notch.start(store: store) { openWindow(id: "main") }
            }
    }
}
struct MonitorMenu: View {
    @Bindable var store: AppStore
    var notch: NotchController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("\(store.activeAgents.count) agents working")
        Text("\(store.agentActivity.waitingCount) need input")
        if store.agentActivity.scheduledCount > 0 { Text("\(store.agentActivity.scheduledCount) scheduled") }
        Divider()
        Button("Show Agent Notch") { notch.show() }
        Toggle("Enable Notch", isOn: $store.notchEnabled)
        Button("Open Usage") { store.filter = .usage; notch.openDashboardWindow() }
        Button("Open Burro") { notch.openDashboardWindow() }
        Button("Refresh") { Task { await store.refreshAgents(); await store.refreshRemotes(); await store.refresh() } }.disabled(store.scanning)
        SettingsLink()
        Divider()
        Button("Quit Burro") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
