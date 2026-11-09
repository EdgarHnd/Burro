// The main dashboard, menu bar, and nonactivating agent notch share one app-owned store.
import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: AppStore?
    var notchController: NotchController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Native menus, toolbars and sheets follow the chosen theme (system by default).
        AppearancePreference.load().apply()
        // Set the running Dock image directly; Launch Services can retain an older bundle icon.
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let url = Bundle.main.url(forResource: name, withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) { notchController?.stop(); store?.stop() }
}
@main struct BurroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore(todos: TodoStore(), notes: NotesStore())
    @State private var notch = NotchController()
    var body: some Scene {
        WindowGroup("Burro", id: "main") {
            DesktopRootView(store: store, notch: notch)
                .onAppear { delegate.notchController = notch; delegate.store = store }
        }
        .defaultSize(width: 1240, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat…") { store.page = .home; store.newChatPresented = true; notch.openDashboardWindow() }
                    .keyboardShortcut("n")
                Button("Add Repository…") { store.addRepository() }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Refresh \(store.page.title)") { Task { await store.refreshCurrentPage() } }
                    .keyboardShortcut("r").disabled(store.refreshingCurrentPage)
                Button("Show Agent Notch") { notch.show() }.keyboardShortcut("b", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                ForEach(AppPage.navigable) { page in
                    Button(page.title) { store.page = page; notch.openDashboardWindow() }.keyboardShortcut(page.shortcut)
                }
            }
        }
        MenuBarExtra {
            MonitorMenu(store: store, notch: notch)
        } label: {
            Label {
                Text(store.activeAgents.isEmpty ? "Burro" : "\(store.activeAgents.count)")
            } icon: { Image(nsImage: BurroBrand.image) }
        }
        Settings { SettingsView(store: store).modifier(AppTheme()) }
    }
}
private struct DesktopRootView: View {
    var store: AppStore
    var notch: NotchController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        ContentView(store: store, notch: notch)
            .background(WindowProbe(onAttach: { window in
                notch.registerDashboard(window)
                // The top bar replaces the title bar; macOS 14 has no drag gesture, so drag by the background.
                if #unavailable(macOS 15.0) { window.isMovableByWindowBackground = true }
            }, onVisibilityChange: store.dashboardVisibilityChanged))
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
        Button("Open Burro") { store.page = .home; notch.openDashboardWindow() }
        Button("Open Usage") { store.page = .usage; notch.openDashboardWindow() }
        Button("Open Mac Health") { store.page = .health; notch.openDashboardWindow() }
        Button("Refresh") { Task { await store.refreshAgents(); await store.refreshRemotes(); await store.refresh() } }.disabled(store.scanning)
        SettingsLink()
        Divider()
        Button("Quit Burro") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
