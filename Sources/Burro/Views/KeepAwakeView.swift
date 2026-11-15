// Keep Awake controls: a card on Mac Health, a menu-bar submenu, a Settings section and a notch line.
import SwiftUI
import BurroCore

extension KeepAwakeStore {
    var symbol: String { awake ? "cup.and.saucer.fill" : "moon.zzz" }
}

/// The Mac Health card: what's keeping the Mac awake, the manual and agent controls, and the one-time permission.
struct KeepAwakeCard: View {
    @Bindable var keepAwake: KeepAwakeStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ProviderBadge(symbol: keepAwake.symbol, color: keepAwake.awake ? AppAppearance.green : AppAppearance.secondary, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Keep awake").font(AppAppearance.sectionTitle)
                        if keepAwake.lidClosedActive {
                            Text("Lid closed").font(.caption.weight(.semibold)).foregroundStyle(AppAppearance.secondary)
                                .padding(.horizontal, 7).padding(.vertical, 2).background(AppAppearance.raised, in: Capsule())
                                .help("pmset disablesleep is on; Burro's watchdog turns it back off")
                        }
                    }
                    Text(keepAwake.headline).font(.callout)
                    if let coverage = keepAwake.coverage { Text(coverage).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                if keepAwake.busy { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                if keepAwake.manualActive {
                    Button("Stop") { keepAwake.stopManual() }
                }
                Menu(keepAwake.manualActive ? "Change" : "Keep awake") { KeepAwakeDurations(keepAwake: keepAwake) }
                    .fixedSize().disabled(keepAwake.busy)
            }
            Divider()
            HStack(spacing: 12) {
                Toggle("While agents work on this Mac", isOn: $keepAwake.agentsMode).toggleStyle(.switch).controlSize(.small)
                Spacer(minLength: 8)
                if keepAwake.agentsMode {
                    Text("then stay").font(.caption).foregroundStyle(.secondary)
                    CapsulePicker(options: KeepAwakePolicy.lingerChoices.map { ($0, "\($0) min") },
                                  selection: $keepAwake.lingerMinutes)
                        .help("How long to stay awake after the last agent finishes, in case another turn starts")
                }
            }
            if keepAwake.canIncludeClosedLid {
                notice("lock", "A closed lid still sleeps. Cover it with one administrator prompt, or allow it once below so Burro never asks again.") {
                    Button("Include closed lid…") { keepAwake.includeClosedLid() }
                }
            }
            if !keepAwake.passwordless && keepAwake.ready && (keepAwake.agentsMode || keepAwake.manualActive) {
                notice("lock.open", keepAwake.agentsMode
                       ? "To keep a closed lid awake while agents work, Burro needs to turn lid-closed sleep off and back on without asking. Allow it once; it permits only “pmset -a disablesleep 0” and “… 1”."
                       : "Allow once so Burro can cover a closed lid without asking each time. It permits only “pmset -a disablesleep 0” and “… 1”.") {
                    Button("Allow…") { keepAwake.allowWithoutPassword() }.disabled(keepAwake.busy)
                }
            }
            if let leftover = keepAwake.leftover {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AppAppearance.amber)
                    Text(leftover == .burro
                         ? "Sleep is still turned off from an earlier keep-awake session that ended without undoing it."
                         : "Sleep is turned off outside Burro (pmset disablesleep), so the Mac won't sleep even with the lid closed.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Turn sleep back on") { keepAwake.turnSleepBackOn() }.disabled(keepAwake.busy)
                }
            }
            if let message = keepAwake.message {
                HStack(alignment: .firstTextBaseline) {
                    Label(message, systemImage: "info.circle").font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { keepAwake.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss")
                }
            }
            Text("Sleep comes back on when you stop, when the agents are done, 30 seconds after Burro quits, if Burro stops responding for 15 minutes, or below \(KeepAwakePolicy.lowBatteryPercent)% battery.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).modifier(AppCardSurface())
    }
    private func notice<Action: View>(_ symbol: String, _ text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action()
        }
    }
}

/// The duration choices, shared by the card's menu and the menu bar.
struct KeepAwakeDurations: View {
    var keepAwake: KeepAwakeStore
    var body: some View {
        ForEach(KeepAwakePolicy.durations, id: \.title) { choice in
            Button(choice.seconds == nil ? choice.title : "For \(choice.title)") { keepAwake.keepAwake(for: choice.seconds) }
        }
    }
}

/// The Burro menu-bar submenu.
struct KeepAwakeMenu: View {
    @Bindable var keepAwake: KeepAwakeStore
    var body: some View {
        Menu(keepAwake.awake ? "Keep Awake · On" : "Keep Awake") {
            Text(keepAwake.headline + (keepAwake.lidClosedActive ? " · lid closed" : ""))
            Divider()
            KeepAwakeDurations(keepAwake: keepAwake).disabled(keepAwake.busy)
            if keepAwake.manualActive { Button("Stop Keeping Awake") { keepAwake.stopManual() } }
            Divider()
            Toggle("While Agents Work", isOn: $keepAwake.agentsMode)
        }
    }
}

/// Settings: the agent mode, its linger and the lid-closed permission.
struct KeepAwakeSettingsSection: View {
    @Bindable var keepAwake: KeepAwakeStore
    var body: some View {
        Section("Keep awake") {
            Toggle("Keep the Mac awake while agents work on it", isOn: $keepAwake.agentsMode)
            Picker("Then stay awake for", selection: $keepAwake.lingerMinutes) {
                ForEach(KeepAwakePolicy.lingerChoices, id: \.self) { Text($0 == 0 ? "No extra time" : "\($0) minutes").tag($0) }
            }.disabled(!keepAwake.agentsMode)
            if keepAwake.passwordless {
                LabeledContent("Closed lid", value: "Allowed without a password")
                if keepAwake.ruleInstalled {
                    Button("Remove Permission…") { keepAwake.removePermission() }
                        .disabled(keepAwake.busy || keepAwake.lidClosedActive)
                        .help(keepAwake.lidClosedActive ? "Stop keeping awake first: the watchdog needs this permission to turn sleep back on." : "")
                }
            } else {
                LabeledContent("Closed lid", value: "Asks for an administrator password")
                Button("Allow Without a Password…") { keepAwake.allowWithoutPassword() }.disabled(keepAwake.busy)
            }
            Text("An open lid stays awake with no password. A closed lid needs “pmset -a disablesleep 1”; allowing it once adds a sudoers rule for exactly “pmset -a disablesleep 0” and “… 1” (\(KeepAwakeScript.rulePath)). Burro's watchdog turns sleep back on when you stop, when the agents are done, 30 seconds after Burro quits, after 15 minutes without word from Burro, or below \(KeepAwakePolicy.lowBatteryPercent)% battery.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One line in the notch's Mac tab while Keep Awake is on.
struct KeepAwakeNotchRow: View {
    var keepAwake: KeepAwakeStore
    var onOpen: () -> Void
    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: keepAwake.symbol).foregroundStyle(NotchStyle.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(keepAwake.headline).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(keepAwake.lidClosedActive ? "Lid closed included" : "While the lid is open")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
        }.buttonStyle(.plain).modifier(AppCardSurface(translucent: true))
            .help("Keep awake settings in Mac Health")
    }
}
