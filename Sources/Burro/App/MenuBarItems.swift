// The menu-bar item's label. The label is the Burro icon alone when nothing runs, the icon and a
// count while agents work, and a speech-bubble-with-exclamation glyph and the number waiting while
// a chat needs you (the label doesn't count drafts). Clicking it opens MenuBarPopover. The label
// exists from launch, so it is what hands AppLaunch the way to open the main window when no window
// was created this run.
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
