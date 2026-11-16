// Owns the app's long-lived objects and starts them exactly once at launch, whether or not the main
// window ever appears: the app store (agent monitor, activity tracker, keep awake), the agent notch,
// the Notes panel and chat notifications. A login-item launch (read from the launch Apple event) is
// quiet: Burro doesn't activate, and the main window SwiftUI creates at launch is closed before it is
// used, so the notch and menu bar are the only presence. Asking for the window (notch, menu bar,
// Dock click, `open`, a notification for a chat Burro lists) brings it back; SwiftUI makes a new one when none is open.
// How to open one comes from the menu-bar item's label, which exists from launch even when no
// window was ever created this run (and again from the main window when it appears).
import AppKit
import BurroCore

@MainActor final class AppLaunch {
    static let shared = AppLaunch()

    let store = AppStore(todos: TodoStore(), notes: NotesStore())
    let notch = NotchController()
    let notesPanel = NotesPanelController()

    private(set) var kind: LaunchKind = .normal
    private var readAtWillFinish: LaunchKind?
    private var started = false
    /// True from a login launch until someone asks for the window: launch windows are closed meanwhile.
    private var quiet = false
    private var openWindow: (() -> Void)?

    /// Reads the launch event while AppKit is handling it (will- and did-finish launching).
    func readLaunchEvent(finishing: Bool) {
        let read = Self.currentLaunchKind()
        if !finishing { readAtWillFinish = read; return }
        kind = LaunchKind.combine(readAtWillFinish, read)
        decided = true
        quiet = kind == .loginItem
        // A window SwiftUI attached before the decision goes too.
        if quiet, let window = launchWindow { dismiss(window) }
    }
    private var decided = false
    private weak var launchWindow: NSWindow?

    /// Starts everything once; later calls (the window's task) do nothing.
    func start() {
        guard !started else { return }
        started = true
        store.start()
        notch.start(store: store) { [weak self] in self?.openNewWindow() }
        store.notchExpanded = { [weak self] in self?.notch.presentation.expanded ?? false }
        notesPanel.start(store: store) { [weak self] in self?.notch.openDashboardWindow() }
    }

    /// Installs the notification click handler; called before launching finishes.
    func installNotifications() {
        store.chatNotifier.install { chat in AppLaunch.shared.openChat(chat) }
    }

    /// A view that exists from launch (the menu-bar label) hands over how to open the main window.
    func registerWindowOpener(_ opener: @escaping () -> Void) {
        if openWindow == nil { openWindow = opener }
    }
    /// Whether Burro knows how to open the main window yet.
    var canOpenWindow: Bool { openWindow != nil }

    /// The main window's view hands over how to open a new window (SwiftUI's openWindow).
    func windowAppeared(_ window: NSWindow, opener: @escaping () -> Void) {
        openWindow = opener
        if !decided { launchWindow = window }
        if quiet { dismiss(window) }
    }

    /// A quiet launch: hide the window SwiftUI opened (or restored) at once, then close it.
    private func dismiss(_ window: NSWindow) {
        window.orderOut(nil)
        DispatchQueue.main.async { [weak window] in window?.close() }
    }

    /// Dock click, `open`, menu bar, notch: show the existing window or open a new one.
    func showMainWindow() {
        quiet = false
        notch.openDashboardWindow()
    }

    /// A notification click: the chat on the Chats page, or in the Claude app when it has left
    /// Burro's list but the Claude app still has it (`AppStore.openChat(id:)` decides; the window
    /// comes up only when the chat opens in Burro).
    func openChat(_ id: String) {
        Task {
            if case .openInClaude = await store.openChat(id: id) { return }
            showMainWindow()
        }
    }

    private func openNewWindow() {
        quiet = false
        openWindow?()
    }

    private static func currentLaunchKind() -> LaunchKind? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return nil }
        let propData = event.paramDescriptor(forKeyword: AEKeyword(LaunchKind.propData))?.enumCodeValue
        let loginParameter = event.paramDescriptor(forKeyword: AEKeyword(LaunchKind.launchedAsLoginItem)) != nil
        return LaunchKind.classify(eventClass: event.eventClass, eventID: event.eventID,
                                   propDataEnum: propData, hasLoginItemParameter: loginParameter)
    }
}
