// Settings sections for notifications, activity tracking's browser reading and Shipped's written
// summaries. Each toggle stores a Burro preference; notifications also ask macOS for permission and
// show when System Settings has turned them off.
import SwiftUI
import BurroCore

/// "Notify when a chat needs you" (off by default) and "Also when a chat finishes" (off).
struct NotificationSettingsSection: View {
    @Bindable var notifier: ChatNotifier
    var body: some View {
        Section("Notifications") {
            Toggle("Notify when a chat needs you", isOn: $notifier.needsYou)
            Toggle("Also when a chat finishes", isOn: $notifier.finished)
                .disabled(!notifier.needsYou && !notifier.finished)
            switch notifier.permission {
            case .denied:
                Text("Notifications for Burro are turned off in System Settings.")
                    .font(.caption).foregroundStyle(.orange)
                Button("Open Notification Settings…") { notifier.openSystemSettings() }
            case .unavailable:
                Text("Notifications need the bundled Burro app.").font(.caption).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
            Text("One banner when a chat on any machine starts waiting for an answer or an approval, removed once it stops waiting. Click it to open the chat. Chats already waiting when Burro opens don't notify.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(notifier.permission == .unavailable)
        .onAppear { if notifier.needsYou || notifier.finished { notifier.refreshPermission() } }
    }
}

/// Whether activity tracking asks Arc and other Chromium browsers for the page's address.
struct ActivityBrowserSettingsSection: View {
    var tracker: ActivityTracker
    @AppStorage("activity.browserPages") private var browserPages = true
    var body: some View {
        Section("Activity") {
            Toggle("Read the site in Arc and Chromium browsers", isOn: $browserPages)
                .onChange(of: browserPages) { tracker.browserPagesChanged() }
            Text("Asks these browsers to build their accessibility tree so the site you're on can be recorded, which costs the browser some CPU. Off, they're recorded by window title.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Whether Shipped asks Claude to write day, week and month summaries.
struct ShippedSummarySettingsSection: View {
    @AppStorage(ShippedStore.summariesKey) private var summaries = true
    var body: some View {
        Section("Shipped") {
            Toggle("Write summaries with Claude", isOn: $summaries)
            Text("Sends the pull request titles, authors and branch names Shipped shows to \(ShippedSummary.modelTitle) through your Claude Code sign-in. Summaries already written stay shown.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
