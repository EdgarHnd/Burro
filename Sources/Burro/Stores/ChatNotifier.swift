// Opt-in macOS notifications when a chat on any machine needs you (and, separately, when one
// finishes). Off by default. Every chat sample goes through ChatAlertTracker, which decides when an
// episode starts and ends; a banner is posted only while the matching setting is on and macOS
// allows Burro to notify, and it is withdrawn when the chat stops waiting (or the finish is read).
// A chat on a machine that went stale keeps its banner until it is seen again. Banners left over
// from an earlier run are removed at launch (only this feature's, and only with a setting on).
// Clicking a banner opens that chat on the Chats page. A needs-you banner goes out at once; when
// the Orchestrator's triage later writes a headline for that chat, the banner still on screen is
// replaced in place with it, quietly (the first text stays if it was already withdrawn). Turning a setting on asks macOS for
// permission. The banner text includes the chat's title: it is shown by macOS only and never
// logged. This only reads chat state; it never messages an agent. Nothing touches the
// notification centre until a setting is on, and never outside the app bundle (tests, `swift run`).
import AppKit
import Observation
import UserNotifications
import BurroCore

@MainActor @Observable final class ChatNotifier {
    enum Permission: Equatable { case unknown, notDetermined, allowed, denied, unavailable }

    var needsYou: Bool { didSet { defaults.set(needsYou, forKey: Self.needsYouKey); if needsYou { requestPermission() } } }
    var finished: Bool { didSet { defaults.set(finished, forKey: Self.finishedKey); if finished { requestPermission() } } }
    private(set) var permission: Permission

    nonisolated static let needsYouKey = "notify.needsYou"
    nonisolated static let finishedKey = "notify.finished"
    nonisolated static let chatKey = "chat"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var tracker = ChatAlertTracker()
    @ObservationIgnored private var delivered: Set<String> = []
    /// Needs-you banners on screen, by chat: what they say, so triage's headline can replace the body.
    @ObservationIgnored private var needsYouBanners: [String: (title: String, chatTitle: String)] = [:]
    @ObservationIgnored private var activeObserver: NSObjectProtocol?

    /// Notifications need a real app bundle; a bare executable (tests, `swift run`) has none.
    nonisolated static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        needsYou = defaults.bool(forKey: Self.needsYouKey)
        finished = defaults.bool(forKey: Self.finishedKey)
        permission = Self.isAvailable ? .unknown : .unavailable
    }

    /// Feeds the latest chats (every machine). Cheap; called on every agent sample.
    func update(_ sessions: [AgentSession], now: Date = Date()) {
        let counted = sessions.filter(ChatAlertSample.counts)
        let unavailable = Set(sessions.filter(ChatAlertSample.unavailable).map(\.id))
        let events = tracker.update(counted.map(ChatAlertSample.init), unavailable: unavailable, at: now)
        guard !events.isEmpty else { return }
        let byID = Dictionary(counted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for event in events {
            switch event {
            case .post(let kind, let chat):
                guard kind == .needsYou ? needsYou : finished, permission == .allowed, let session = byID[chat] else { continue }
                post(kind, session)
            case .withdraw(let kind, let chat):
                let id = Self.identifier(kind, chat)
                if kind == .needsYou { needsYouBanners[chat] = nil }
                guard delivered.remove(id) != nil else { continue }
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
            }
        }
    }

    /// Installs the click handler and reads the permission. Called once at launch, before
    /// launching finishes, so a click that launched Burro still opens the chat.
    func install(open: @escaping @MainActor @Sendable (String) -> Void) {
        guard Self.isAvailable else { return }
        let delegate = ChatNotificationDelegate(open: open)
        self.delegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
        if needsYou || finished { refreshPermission(); removeEarlierBanners() }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.needsYou || self.finished else { return }; self.refreshPermission() }
        }
    }
    @ObservationIgnored private var delegate: ChatNotificationDelegate?

    /// Removes this feature's banners delivered by an earlier run (nothing remembers them now),
    /// keeping any this run has already posted and every other notification.
    private func removeEarlierBanners() {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let ids = notifications.map(\.request.identifier).filter(ChatAlertEvent.isChatAlert)
            guard !ids.isEmpty else { return }
            Task { @MainActor in
                let stale = ids.filter { !self.delivered.contains($0) }
                guard !stale.isEmpty else { return }
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: stale)
            }
        }
    }

    /// Reads whether macOS lets Burro notify (System Settings › Notifications can change it).
    func refreshPermission() {
        guard Self.isAvailable else { permission = .unavailable; return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in self.apply(status) }
        }
    }

    /// Opens System Settings › Notifications at Burro.
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestPermission() {
        guard Self.isAvailable else { permission = .unavailable; return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let status = settings.authorizationStatus
                Task { @MainActor in self.apply(status) }
            }
        }
    }

    private func apply(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional: permission = .allowed
        case .denied: permission = .denied
        case .notDetermined: permission = .notDetermined
        @unknown default: permission = .denied
        }
    }

    private func post(_ kind: ChatAlertKind, _ session: AgentSession) {
        let content = UNMutableNotificationContent()
        content.title = Self.title(session)
        content.body = Self.body(kind, session)
        content.userInfo = [Self.chatKey: session.id]
        content.threadIdentifier = session.id
        let id = Self.identifier(kind, session.id)
        delivered.insert(id)
        if kind == .needsYou { needsYouBanners[session.id] = (content.title, session.title) }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil), withCompletionHandler: nil)
    }

    /// Triage's headline for a chat whose needs-you banner is still on screen: the banner is
    /// replaced in place (same identifier, so macOS swaps it rather than adding another), quietly.
    /// The first banner never waits for this.
    func updateHeadline(chatID: String, headline: String) {
        guard needsYou, permission == .allowed, let banner = needsYouBanners[chatID] else { return }
        let id = Self.identifier(.needsYou, chatID)
        guard delivered.contains(id) else { return }
        let content = UNMutableNotificationContent()
        content.title = banner.title
        content.body = ChatAlertText.body(needsYou: true, title: banner.chatTitle, headline: headline)
        content.userInfo = [Self.chatKey: chatID]
        content.threadIdentifier = chatID
        content.interruptionLevel = .passive
        needsYouBanners[chatID] = nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil), withCompletionHandler: nil)
    }

    static func identifier(_ kind: ChatAlertKind, _ chat: String) -> String { ChatAlertEvent.identifier(kind, chat: chat) }

    /// "Claude Code · burro", with the machine for a remote chat.
    static func title(_ session: AgentSession) -> String {
        let project = URL(fileURLWithPath: session.cwd).lastPathComponent
        let place = session.remote.map { " on \($0.hostName)" } ?? ""
        return "\(session.provider.rawValue) · \(project.isEmpty ? "chat" : project)\(place)"
    }

    static func body(_ kind: ChatAlertKind, _ session: AgentSession) -> String {
        ChatAlertText.body(needsYou: kind == .needsYou, title: session.title)
    }
}

/// Banner clicks open the chat; banners also show while Burro is in front.
final class ChatNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let open: @MainActor @Sendable (String) -> Void
    init(open: @escaping @MainActor @Sendable (String) -> Void) { self.open = open }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let chat = response.notification.request.content.userInfo[ChatNotifier.chatKey] as? String
        let clicked = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let open = self.open
        if clicked, let chat { Task { @MainActor in open(chat) } }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
