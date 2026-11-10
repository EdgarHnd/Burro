// Burro's own on-device tracker on the Today page (frontmost app, window title, a browser's host;
// never the screen). Off, it is a small card in the side column that explains it and turns it on.
// On, the day view (TodayDayView.swift) takes its place in the main column. The pieces both share
// live here: the controls (Pause, Turn off, Delete this day…, Delete everything…, each delete
// behind a confirmation), the Accessibility prompt, app/site rows whose right-click changes the
// category or marks a site private, app icons and category colours.
import AppKit
import SwiftUI
import BurroCore

struct TodayActivityCard: View {
    var today: TodayStore

    var body: some View {
        TodayCard(title: "Activity", symbol: "waveform.path.ecg", color: AppAppearance.secondary) {
            ActivityControls(today: today)
            VStack(alignment: .leading, spacing: 3) {
                Text("Notes the app you're in, its window title and a browser's site (host only).")
                Text("Never the screen. Stays on this Mac for 30 days.")
            }
            .font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Recording/Paused, Pause or Turn on, and a menu with Turn off and the deletes.
struct ActivityControls: View {
    var today: TodayStore
    @State private var confirm: Confirm?
    private enum Confirm { case day, all }
    private var tracker: ActivityTracker { today.tracker }

    var body: some View {
        HStack(spacing: 8) {
            if tracker.enabled {
                Circle().fill(tracker.paused ? AppAppearance.amber : AppAppearance.green).frame(width: 7, height: 7)
                Text(tracker.paused ? "Paused" : "Recording").font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                Spacer()
                pill(tracker.paused ? "Resume" : "Pause", symbol: tracker.paused ? "play.fill" : "pause.fill") { tracker.paused.toggle() }
            } else {
                pill("Turn on", symbol: "record.circle") { tracker.paused = false; tracker.enabled = true }
                    .help("Starts recording the frontmost app, window title and site host on this Mac.")
                Spacer()
            }
            Menu {
                if tracker.enabled {
                    Button(tracker.paused ? "Resume" : "Pause") { tracker.paused.toggle() }
                    Button("Turn off") { tracker.enabled = false }
                    Divider()
                }
                Button("Delete this day…", role: .destructive) { confirm = .day }
                Button("Delete everything…", role: .destructive) { confirm = .all }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
                    .background(AppAppearance.raised, in: Circle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Pause, turn off or delete")
        }
        .confirmationDialog(confirm == .all ? "Delete all recorded activity?" : "Delete this day's activity?",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { which in
            Button("Delete", role: .destructive) {
                if which == .all { tracker.deleteAll() } else { tracker.deleteDay(today.day) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { which in
            Text(which == .all ? "Removes every day Burro recorded on this Mac. Your category rules stay."
                 : "Removes what Burro recorded on \(today.day.formatted(.dateTime.weekday(.wide).month().day())). This can't be undone.")
        }
    }

    private func pill(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).frame(height: 26)
                .background(AppAppearance.raised, in: Capsule())
        }.buttonStyle(.plain)
    }
}

/// Window titles and sites need Accessibility; asked only when you click Allow.
struct ActivityAccessPrompt: View {
    var tracker: ActivityTracker
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lock").font(.system(size: 10))
            Text("Window titles and sites need Accessibility.").fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Allow…") { tracker.requestAccessibility() }.buttonStyle(.plain).foregroundStyle(AppAppearance.blue)
                .help("Asks macOS for Accessibility and opens its settings pane. Without it, Burro records app time only.")
        }
        .font(.system(size: 11)).foregroundStyle(AppAppearance.secondary)
    }
}

/// Right-click actions for an app or a site: change its category, or treat the site as private.
struct ActivityCategoryMenu: View {
    var tracker: ActivityTracker
    var id: String
    var name: String
    var site: Bool
    var body: some View {
        let custom = site ? tracker.rules.hosts[id] : tracker.rules.apps[id]
        Menu("Categorise \(name) as") {
            ForEach(ActivityCategory.assignable) { category in
                Button { set(category) } label: {
                    if custom == category { Label(category.title, systemImage: "checkmark") } else { Text(category.title) }
                }
            }
            if custom != nil {
                Divider()
                Button("Use the built-in category") { set(nil) }
            }
        }
        if site {
            Button("Treat \(name) as private") { tracker.makePrivate(host: id) }
        }
    }
    private func set(_ category: ActivityCategory?) {
        if site { tracker.setCategory(category, host: id) } else { tracker.setCategory(category, app: id) }
    }
}

/// An app or site with its time; right-click to recategorise.
struct ActivityItemRow: View {
    var tracker: ActivityTracker
    var item: ActivityDay.Item
    var site: Bool
    var body: some View {
        HStack(spacing: 8) {
            Group {
                if site { Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary) }
                else { ActivityAppIcon(bundleID: item.id, size: 16) }
            }.frame(width: 16, height: 16)
            // Shown like timeline titles, without "www."; rules still use the stored host (`item.id`).
            Text(site && item.name.hasPrefix("www.") ? String(item.name.dropFirst(4)) : item.name)
                .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            Circle().fill(ActivityStyle.color(item.category)).frame(width: 5, height: 5)
            Spacer(minLength: 6)
            Text(TodaySummary.duration(item.seconds)).font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.secondary)
        }
        .contentShape(Rectangle())
        .help("\(item.category.title) · right-click to change")
        .contextMenu {
            if item.category != .private { ActivityCategoryMenu(tracker: tracker, id: item.id, name: item.name, site: site) }
        }
    }
}

/// The app's own icon from Launch Services, cached; a neutral symbol when it isn't installed or there's no single app.
struct ActivityAppIcon: View {
    var bundleID: String?
    var size: CGFloat
    var body: some View {
        if let bundleID, let image = ActivityAppIcons.image(bundleID) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: bundleID == nil ? "square.stack" : "app.dashed").font(.system(size: size * 0.75))
                .foregroundStyle(AppAppearance.tertiary).frame(width: size, height: size)
        }
    }
}

@MainActor enum ActivityAppIcons {
    private static var cache: [String: NSImage?] = [:]
    static func image(_ bundleID: String) -> NSImage? {
        if let hit = cache[bundleID] { return hit }
        if cache.count > 300 { cache.removeAll() }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { url -> NSImage in
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            return icon
        }
        cache[bundleID] = image
        return image
    }
}

enum ActivityStyle {
    static func color(_ category: ActivityCategory) -> Color {
        switch category {
        case .build: AppAppearance.blue
        case .agents: AppAppearance.claude
        case .design: .purple
        case .analytics: AppAppearance.green
        case .comms: .teal
        case .docs: .indigo
        case .browsing: .cyan
        case .break: .pink
        case .private: AppAppearance.tertiary
        case .other: AppAppearance.secondary
        }
    }

    /// A start–end range in the viewer's time format, e.g. "20:54 – 21:09".
    static func range(_ start: Date, _ end: Date) -> String {
        "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}
