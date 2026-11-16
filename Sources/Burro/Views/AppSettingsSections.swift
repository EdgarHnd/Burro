// Settings → Notifications and Settings → Activity. Notifications: "Notify when a chat needs you"
// and "Also when a chat finishes" (both off by default); turning one on asks macOS for permission,
// and the pane says when System Settings has turned Burro's notifications off. Activity: recording
// on or off (the same switch as Today's Turn on / Turn off), when you count as away, whether Arc
// and Chromium browsers are asked for the site, and whether Shipped asks Claude to write summaries.
// Each control stores the same Burro preference it always did.
import SwiftUI
import BurroCore

/// The two chat notification switches and macOS's permission state.
struct SettingsNotificationsPane: View {
    @Bindable var notifier: ChatNotifier
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsPaneHeader(title: "Notifications", summary: summary)
            SettingsGroup(title: "Notify when a chat needs you",
                          note: "One banner when a chat on any machine starts waiting for an answer or an approval, removed once it stops waiting. Click it to open the chat. Chats already waiting when Burro opens don't notify.",
                          isOn: $notifier.needsYou) {
                SettingsRow(title: "Also when a chat finishes") {
                    SettingsSwitch(label: "Also when a chat finishes", isOn: $notifier.finished)
                        .disabled(!notifier.needsYou && !notifier.finished)
                }
                switch notifier.permission {
                case .denied:
                    SettingsNote("Notifications for Burro are turned off in System Settings.", color: AppAppearance.amber)
                    HStack { Button("Open Notification Settings…") { notifier.openSystemSettings() }; Spacer() }
                case .unavailable:
                    SettingsNote("Notifications need the bundled Burro app.")
                default:
                    EmptyView()
                }
            }
            .disabled(notifier.permission == .unavailable)
        }
        .onAppear { if notifier.needsYou || notifier.finished { notifier.refreshPermission() } }
    }

    private var summary: String {
        if notifier.permission == .denied && (notifier.needsYou || notifier.finished) { return "Turned on here, but macOS is blocking Burro's banners." }
        switch (notifier.needsYou, notifier.finished) {
        case (true, true): return "A banner when a chat needs you and when one finishes."
        case (true, false): return "A banner when a chat needs you."
        case (false, true): return "A banner when a chat finishes."
        case (false, false): return "Off. Burro shows what needs you in the notch and on Home without banners."
        }
    }
}

/// Recording, away time, browser sites and Shipped's summaries.
struct SettingsActivityPane: View {
    var tracker: ActivityTracker
    @AppStorage("activity.browserPages") private var browserPages = true
    @AppStorage(ShippedStore.summariesKey) private var summaries = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsPaneHeader(title: "Activity", summary: tracker.enabled
                ? (tracker.paused ? "Recording is paused. Tracked activity stays on this Mac and is never sent anywhere."
                                  : "Recording what you work on. Tracked activity stays on this Mac and is never sent anywhere.")
                : "Not recording. When on, tracked activity stays on this Mac and is never sent anywhere.")
            SettingsGroup(title: "Record activity",
                          note: "Records the frontmost app, window title and site host on this Mac while Burro is open, for the Today page. Delete it under Privacy and data.",
                          isOn: Binding(get: { tracker.enabled }, set: { on in
                              if on { tracker.paused = false }
                              tracker.enabled = on
                          })) {
                if tracker.enabled && tracker.paused {
                    SettingsRow(title: "Paused") { Button("Resume") { tracker.paused = false } }
                }
                SettingsRow(title: "Count me as away after",
                            note: "Without keyboard or mouse input for this long, you count as away. Reading agent output without touching the Mac counts as here until then.") {
                    SettingsMenuPicker(label: "Away after", selection: Binding(get: { tracker.idleAfter }, set: { tracker.idleAfter = $0 }),
                                       options: ActivityPresence.idleChoices.map { ($0, "\(Int($0 / 60)) min") })
                }
                SettingsRow(title: "Read the site in Arc and Chromium browsers",
                            note: "Asks these browsers to build their accessibility tree so the site you're on can be recorded, which costs the browser some CPU. Off, they're recorded by window title.") {
                    SettingsSwitch(label: "Read the site in Arc and Chromium browsers", isOn: $browserPages)
                        .onChange(of: browserPages) { tracker.browserPagesChanged() }
                }
            }
            SettingsGroup(title: "Write Shipped summaries with Claude",
                          note: "Sends the pull request titles, authors and branch names Shipped shows to \(ShippedSummary.modelTitle) through your Claude Code sign-in. Summaries already written stay shown.",
                          isOn: $summaries)
        }
    }
}
