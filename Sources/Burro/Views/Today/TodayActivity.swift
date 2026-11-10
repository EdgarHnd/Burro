// The Today page's Activity card: Burro's own on-device tracker (frontmost app, window title, a
// browser's host; never the screen). Off until you turn it on here. Pause sits in the card; delete
// this day and delete everything are in its menu, each behind a confirmation. Right-click an app
// or site to change its category, or mark a site private.
import SwiftUI
import BurroCore

struct TodayActivityCard: View {
    var today: TodayStore
    @State private var confirm: Confirm?
    private enum Confirm { case day, all }
    private var tracker: ActivityTracker { today.tracker }

    var body: some View {
        TodayCard(title: "Activity", symbol: "waveform.path.ecg", color: AppAppearance.secondary) {
            controls
            if !tracker.enabled {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Notes the app you're in, its window title and a browser's site (host only).")
                    Text("Never the screen. Stays on this Mac for 30 days.")
                }
                .font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !tracker.accessibilityTrusted {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "lock").font(.system(size: 10))
                    Text("Window titles and sites need Accessibility.").fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Allow…") { tracker.requestAccessibility() }.buttonStyle(.plain).foregroundStyle(AppAppearance.blue)
                        .help("Asks macOS for Accessibility and opens its settings pane. Without it, Burro records app time only.")
                }
                .font(.system(size: 11)).foregroundStyle(AppAppearance.secondary)
            }
            if let day = today.tracked, day.total > 0 {
                summary(day)
            } else if tracker.enabled {
                Text(today.tracked == nil ? "Reading…" : today.isToday ? "Nothing recorded yet today." : "Nothing recorded that day.")
                    .font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
            }
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

    @ViewBuilder private var controls: some View {
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
    }

    private func pill(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).frame(height: 26)
                .background(AppAppearance.raised, in: Capsule())
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func summary(_ day: ActivityDay) -> some View {
        BigPair(left: TodaySummary.duration(day.focused), leftLabel: "focused", right: TodaySummary.duration(day.total), rightLabel: "tracked")
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(day.categories) { item in
                    Rectangle().fill(ActivityStyle.color(item.category))
                        .frame(width: max(2, (geometry.size.width - 2 * CGFloat(day.categories.count - 1)) * item.seconds / day.total))
                        .help("\(item.category.title): \(TodaySummary.duration(item.seconds))")
                }
            }
        }
        .frame(height: 6).clipShape(Capsule())
        Text(day.categories.prefix(3).map { "\($0.category.title) \(TodaySummary.duration($0.seconds))" }.joined(separator: " · "))
            .font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
        Divider().overlay(AppAppearance.separator)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(day.apps.prefix(4)) { item in row(item, site: false) }
            ForEach(day.sites.prefix(3)) { item in row(item, site: true) }
        }
        if !day.entries.isEmpty {
            Divider().overlay(AppAppearance.separator)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(day.entries.suffix(5).reversed()) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(ActivityStyle.color(entry.category)).frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text("\(entry.start.formatted(date: .omitted, time: .shortened))–\(entry.end.formatted(date: .omitted, time: .shortened)) · \(entry.app) · \(entry.category.title)")
                                .font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private func row(_ item: ActivityDay.Item, site: Bool) -> some View {
        HStack(spacing: 8) {
            Circle().fill(ActivityStyle.color(item.category)).frame(width: 6, height: 6)
            Image(systemName: site ? "globe" : "app").font(.system(size: 10)).foregroundStyle(AppAppearance.tertiary)
            Text(item.name).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 6)
            Text(TodaySummary.duration(item.seconds)).font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.secondary)
        }
        .contentShape(Rectangle())
        .help("\(item.category.title) · right-click to change")
        .contextMenu {
            if item.category != .private {
                let custom = site ? tracker.rules.hosts[item.id] : tracker.rules.apps[item.id]
                Menu("Categorise \(item.name) as") {
                    ForEach(ActivityCategory.assignable) { category in
                        Button { set(category, item, site) } label: {
                            if custom == category { Label(category.title, systemImage: "checkmark") } else { Text(category.title) }
                        }
                    }
                    if custom != nil {
                        Divider()
                        Button("Use the built-in category") { set(nil, item, site) }
                    }
                }
                if site {
                    Button("Treat \(item.name) as private") { tracker.makePrivate(host: item.id) }
                }
            }
        }
    }

    private func set(_ category: ActivityCategory?, _ item: ActivityDay.Item, _ site: Bool) {
        if site { tracker.setCategory(category, host: item.id) } else { tracker.setCategory(category, app: item.id) }
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
}
