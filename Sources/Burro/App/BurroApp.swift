// The main dashboard, menu bar, and nonactivating agent notch share one app-owned store. AppLaunch
// starts everything once at launch, with or without a window; a login-item launch stays quiet.
import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppLaunch.shared.readLaunchEvent(finishing: false)
        AppLaunch.shared.installNotifications()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLaunch.shared.readLaunchEvent(finishing: true)
        NSApp.setActivationPolicy(.regular)
        // Native menus, toolbars and sheets follow the chosen theme (system by default).
        AppearancePreference.load().apply()
        // Set the running Dock image directly; Launch Services can retain an older bundle icon.
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let url = Bundle.main.url(forResource: name, withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        AppLaunch.shared.start()
        // A login-item launch stays in the background: the notch and menu bar are its presence.
        if AppLaunch.shared.kind == .normal { NSApp.activate(ignoringOtherApps: true) }
    }
    /// Dock click or `open` while running: the notch panel is always a visible window, so AppKit's
    /// default would do nothing; show the dashboard instead. Until Burro knows how to open a window,
    /// SwiftUI's own reopen handling runs too.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppLaunch.shared.showMainWindow()
        return !AppLaunch.shared.canOpenWindow
    }
    func applicationWillTerminate(_ notification: Notification) {
        let launch = AppLaunch.shared
        launch.notch.stop(); launch.store.notes.flush(); launch.store.stop()
    }
}
@main struct BurroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppLaunch.shared.store
    @State private var notch = AppLaunch.shared.notch
    @State private var notesPanel = AppLaunch.shared.notesPanel
    var body: some Scene {
        WindowGroup("Burro", id: "main") {
            DesktopRootView(store: store, notch: notch, notesPanel: notesPanel)
        }
        .defaultSize(width: 1240, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandPaletteCommands()
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
                    Button(page.title) { store.go(to: page); notch.openDashboardWindow() }.keyboardShortcut(page.shortcut)
                }
                Divider()
                Button("Back") { store.goBack() }.keyboardShortcut("[").disabled(!store.pageHistory.canGoBack)
                Button("Forward") { store.goForward() }.keyboardShortcut("]").disabled(!store.pageHistory.canGoForward)
            }
            // Reopens the main window after it was closed (the menu bar and notch keep running).
            CommandGroup(before: .windowList) {
                Button("Burro") { notch.openDashboardWindow() }.keyboardShortcut("0")
                Divider()
            }
        }
        // A window-style popover (MenuBarPopover); the label logic is MenuBarLabel's.
        MenuBarExtra {
            MenuBarPopover(store: store, notch: notch)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
        Settings { SettingsView(store: store).modifier(AppTheme()) }
    }
}
private struct DesktopRootView: View {
    var store: AppStore
    var notch: NotchController
    var notesPanel: NotesPanelController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let open = openWindow
        ContentView(store: store, notch: notch)
            .background(WindowProbe(onAttach: { window in
                notch.registerDashboard(window)
                AppLaunch.shared.windowAppeared(window) { open(id: "main") }
                // The top bar replaces the title bar; macOS 14 has no drag gesture, so drag by the background.
                if #unavailable(macOS 15.0) { window.isMovableByWindowBackground = true }
            }, onVisibilityChange: store.dashboardVisibilityChanged))
            // Normally started at launch already; this only covers a window that comes first.
            .task { AppLaunch.shared.start() }
    }
}
