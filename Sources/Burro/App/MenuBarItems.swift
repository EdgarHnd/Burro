// The menu-bar item's label and its "needs you" rows. The label is the Burro icon alone when
// nothing runs, the icon and a count while agents work, and a speech-bubble-with-exclamation
// glyph and the number waiting while a chat needs you. The menu lists up to five chats waiting
// on you; choosing one opens it the way a notch row does (its provider app when it has a link,
// otherwise the chat in Burro). The label exists from launch, so it is what hands AppLaunch the
// way to open the main window when no window was created this run.
import SwiftUI
import BurroCore

struct MenuBarLabel: View {
    var store: AppStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let status = MenuBarStatus(store.agentActivity)
        Group {
            switch status {
            case .idle:
                Image(nsImage: BurroBrand.image)
            case .running(let running):
                Label { Text("\(running)") } icon: { Image(nsImage: BurroBrand.image) }
            case .needsYou(let waiting, _):
                Label { Text("\(waiting)") } icon: { Image(systemName: "exclamationmark.bubble.fill") }
            }
        }
        .accessibilityLabel(status.accessibilityLabel)
        .onAppear {
            let open = openWindow
            AppLaunch.shared.registerWindowOpener { open(id: "main") }
        }
    }
}

struct NeedsYouMenuItems: View {
    var store: AppStore
    var notch: NotchController
    var body: some View {
        let chats = MenuBarStatus.needsYou(store.agentActivity.sessions)
        if !chats.isEmpty {
            Divider()
            Text("Needs you")
            ForEach(chats) { chat in
                Button(label(chat)) { notch.select(chat) }
            }
        }
    }
    private func label(_ chat: AgentSession) -> String {
        let title = chat.title.count > 48 ? String(chat.title.prefix(47)) + "…" : chat.title
        return chat.remote.map { "\(title) · \($0.hostName)" } ?? title
    }
}
