// Managing a chat from the Chats page: the header's ⋯ menu (which also has Open in Codex/Claude and
// Refresh) and the same items as a list row's context menu (`chatRowMenu`). Rename (Codex: in Codex; Claude: a Burro-only title), Pin to top
// (Burro-only), Mark as read here, Archive in Codex (asks first; Codex can unarchive) or Hide in
// Burro for Claude. Provider calls run only on these clicks and report failures in an alert. The row's
// context menu also leads with "Ask the Orchestrator about this chat", which only prefills the
// Orchestrator's question and opens its page; the owner clicks Ask.
// Also here: `marksChatSeen` (a chat open on the Chats page marks it seen in Burro while Burro's
// window is key and Burro is the active app, and again when it becomes key) and
// `opensChatInBurro` (a worktree's agent row opens its chat on the Chats page).
import AppKit
import SwiftUI
import BurroCore

/// The ⋯ button in a chat's header.
struct ChatHeaderMenu: View {
    var store: AppStore
    var session: AgentSession
    /// Re-reads the conversation now ("Refresh").
    var refresh: (() -> Void)? = nil
    @State private var actions = ChatManageState()
    var body: some View {
        Menu { ChatManageItems(store: store, session: session, state: actions, includeOpen: true, refresh: refresh) } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Open, refresh, rename, pin, archive")
        .accessibilityLabel("More actions")
        .modifier(ChatManageDialogs(store: store, session: session, state: actions))
    }
}

extension View {
    /// The chat's manage items as a context menu, for a row in the Chats list.
    func chatRowMenu(_ session: AgentSession, store: AppStore) -> some View { modifier(ChatRowMenu(store: store, session: session)) }
    /// Marks the chat seen in Burro while this view is on screen, at each new activity time.
    func marksChatSeen(_ session: AgentSession, store: AppStore) -> some View { modifier(MarksChatSeen(store: store, session: session)) }
    /// Makes the view a button that opens the chat on Burro's Chats page.
    func opensChatInBurro(_ session: AgentSession, store: AppStore) -> some View {
        Button { store.selectAgent(session) } label: { self.contentShape(Rectangle()) }
            .buttonStyle(.plain).help("Open this chat in Burro").accessibilityHint("Opens the chat on the Chats page")
    }
}

private struct ChatRowMenu: ViewModifier {
    var store: AppStore
    var session: AgentSession
    @State private var actions = ChatManageState()
    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Ask the Orchestrator about this chat") {
                    store.prefillOrchestratorQuestion(chatTitle: session.title, machine: session.remote?.hostName)
                }
                Divider()
                ChatManageItems(store: store, session: session, state: actions, includeOpen: true)
            }
            .modifier(ChatManageDialogs(store: store, session: session, state: actions))
    }
}

@MainActor @Observable
final class ChatManageState {
    var renaming = false
    var name = ""
    var confirmArchive = false
    var error: String?
}

private struct ChatManageItems: View {
    var store: AppStore
    var session: AgentSession
    var state: ChatManageState
    var includeOpen = false
    var refresh: (() -> Void)? = nil
    private var local: ChatLocalStore { .shared }
    private var codex: Bool { ChatProviderManage.codexThread(session) != nil }
    var body: some View {
        Button("Rename…") { state.name = session.title; state.renaming = true }
        if local.manage.isPinned(session.id) {
            Button("Unpin") { local.setPinned(session.id, false) }
        } else {
            Button("Pin to Top") { local.setPinned(session.id, true) }
        }
        Button("Mark as Read Here") { markRead() }.disabled(!session.isDone)
        if includeOpen, let url = session.chatURL {
            Divider()
            Button("Open in \(session.provider == .codex ? "Codex" : "Claude")") { NSWorkspace.shared.open(url) }
        }
        if let refresh { Button("Refresh", action: refresh) }
        Divider()
        if codex {
            Button("Archive in Codex…") { state.confirmArchive = true }
        } else {
            Button("Hide in Burro") { local.hide(session) }
        }
    }
    private func markRead() {
        if local.markSeen(session) { Task { await store.refreshAgents() } }
    }
}

private struct ChatManageDialogs: ViewModifier {
    var store: AppStore
    var session: AgentSession
    @Bindable var state: ChatManageState
    private var host: RemoteHost? { store.remoteHosts.first { $0.id == session.remote?.hostID } }
    private var codex: Bool { ChatProviderManage.codexThread(session) != nil }

    func body(content: Content) -> some View {
        content
            .alert("Rename chat", isPresented: $state.renaming) {
                TextField("Name", text: $state.name)
                Button("Rename") { rename() }
                if !codex && ChatLocalStore.shared.manage.title(for: session.id) != nil {
                    Button("Use Claude's Title") { ChatLocalStore.shared.rename(session.id, to: "") }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(codex ? "Codex shows the new name too." : "Claude has no way to rename a chat, so this name is kept in Burro only.")
            }
            .confirmationDialog("Archive this chat in Codex?", isPresented: $state.confirmArchive) {
                Button("Archive") { archive() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It leaves Codex's list and Burro's. You can unarchive it in Codex.")
            }
            .alert("Couldn't change this chat", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(state.error ?? "") }
    }

    private func rename() {
        let name = state.name
        guard codex else { ChatLocalStore.shared.rename(session.id, to: name); return }
        run { try ChatProviderManage.rename($0, to: name, host: $1) }
    }
    private func archive() { run { try ChatProviderManage.archive($0, host: $1) } }

    private func run(_ body: @escaping @Sendable (AgentSession, RemoteHost?) throws -> Void) {
        let session = session, host = host
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try body(session, host) } }.value
            if case .failure(let failure) = result { state.error = (failure as? LocalizedError)?.errorDescription ?? "Codex didn't accept the change." }
            if session.remote == nil { await store.refreshAgents() } else { await store.refreshRemotes() }
        }
    }
}

private struct MarksChatSeen: ViewModifier {
    var store: AppStore
    var session: AgentSession
    @State private var window = WindowAttention()
    func body(content: Content) -> some View {
        content
            .background(WindowAttentionReader { window = $0 })
            .onChange(of: window) { _, _ in mark() }
            .onChange(of: session.updatedAt) { _, _ in mark() }
            .onAppear { mark() }
    }
    /// Only while you are there: the Chats page in Burro's key, visible window, Burro active.
    private func mark() {
        guard ChatSeen.marks(onChatsPage: store.page == .remote, windowVisible: window.visible, windowKey: window.key,
                             appActive: window.appActive) else { return }
        let wasUnread = session.isDone
        if ChatLocalStore.shared.markSeen(session) && wasUnread { Task { await store.refreshAgents() } }
    }
}

/// Whether the view's window is visible and key, and Burro the active app.
struct WindowAttention: Equatable {
    var visible = false
    var key = false
    var appActive = false
}

/// Reports `WindowAttention` for the window it sits in whenever its occlusion or key state, or
/// the app's active state, changes.
private struct WindowAttentionReader: NSViewRepresentable {
    var onChange: (WindowAttention) -> Void
    func makeNSView(context: Context) -> ReaderView { ReaderView(onChange: onChange) }
    func updateNSView(_ view: ReaderView, context: Context) { view.onChange = onChange }
    final class ReaderView: NSView {
        var onChange: (WindowAttention) -> Void
        // Read again only in deinit, after every main-thread use has ended.
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
        private var reported: WindowAttention?
        init(onChange: @escaping (WindowAttention) -> Void) { self.onChange = onChange; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            let center = NotificationCenter.default
            func observe(_ name: Notification.Name, _ object: Any?) {
                observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            if let window {
                observe(NSWindow.didChangeOcclusionStateNotification, window)
                observe(NSWindow.didBecomeKeyNotification, window)
                observe(NSWindow.didResignKeyNotification, window)
            }
            observe(NSApplication.didBecomeActiveNotification, nil)
            observe(NSApplication.didResignActiveNotification, nil)
            report()
        }
        private func report() {
            let state = WindowAttention(visible: window?.occlusionState.contains(.visible) == true, key: window?.isKeyWindow == true,
                                        appActive: NSApp?.isActive == true)
            guard state != reported else { return }
            reported = state
            // Defer so SwiftUI state never changes inside its own view update.
            DispatchQueue.main.async { [onChange] in onChange(state) }
        }
    }
}

/// "Attach on <machine>": writes the fixed `.command` file and opens it in Terminal.
enum RemoteAttachOpener {
    @discardableResult
    static func open(host: RemoteHost, handle: String) -> String? {
        guard let body = RemoteAttach.script(host: host, handle: handle) else { return "Burro can't attach to that session safely." }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-attach")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let script = folder.appendingPathComponent("claude-\(handle)-\(host.id.uuidString.prefix(8)).command")
        try? FileManager.default.removeItem(at: script)
        guard FileManager.default.createFile(atPath: script.path, contents: Data(body.utf8), attributes: [.posixPermissions: 0o700]) else {
            return "Couldn't write the Terminal command."
        }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return "Terminal isn't available." }
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        return nil
    }
}
