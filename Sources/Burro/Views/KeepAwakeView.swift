// Keep Awake controls: a card on Mac Health (status, a segmented control of the options, linger and permission),
// a group in Settings → Machines and a notch line.
import SwiftUI
import BurroCore

extension KeepAwakeStore {
    var symbol: String { awake ? "cup.and.saucer.fill" : "moon.zzz" }
}

/// The Mac Health card: whether the Mac is kept awake and why, a segmented control for the existing options
/// (a duration, until you stop, or while agents work), the linger after agents, and the one-time permission.
struct KeepAwakeCard: View {
    @Bindable var keepAwake: KeepAwakeStore
    /// The last duration picked here and when, so its segment stays on only while that request is still the one running.
    @AppStorage("macHealth.keepAwakePick") private var picked: Double = 0
    @AppStorage("macHealth.keepAwakePickedAt") private var pickedAt: Double = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: keepAwake.symbol).foregroundStyle(keepAwake.awake ? AppAppearance.green : AppAppearance.tertiary)
                    .accessibilityHidden(true)
                MacHealthLabel("Keep awake")
                if keepAwake.lidClosedActive {
                    Text("Lid closed").font(.caption.weight(.semibold)).foregroundStyle(AppAppearance.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(AppAppearance.raised, in: Capsule())
                        .help("pmset disablesleep is on; Burro's watchdog turns it back off")
                }
                Spacer(minLength: 8)
                if keepAwake.busy { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                Text(keepAwake.awake ? "On" : "Off").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(keepAwake.awake ? AppAppearance.green : AppAppearance.tertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(keepAwake.awake || keepAwake.decision.reason != .off ? keepAwake.headline : "The Mac sleeps as usual").fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                    if let coverage = keepAwake.coverage {
                        Text(coverage).foregroundStyle(AppAppearance.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if keepAwake.manualActive {
                    Button("Stop") { keepAwake.stopManual() }
                        .help(keepAwake.agentsMode ? "Stop this request; “While agents work” stays on" : "Let the Mac sleep as usual")
                }
            }
            KeepAwakeSegments(selected: selected) { choose($0) }.disabled(keepAwake.busy)
            if keepAwake.agentsMode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("After the last chat finishes, stay awake for").font(.caption).foregroundStyle(AppAppearance.secondary)
                    CapsulePicker(options: KeepAwakePolicy.lingerChoices.map { ($0, $0 == 0 ? "None" : "\($0) min") },
                                  selection: $keepAwake.lingerMinutes)
                        .fixedSize()
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
                    Button { keepAwake.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        .accessibilityLabel("Dismiss").help("Dismiss")
                }
            }
            Text(footnote).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).fixedSize(horizontal: false, vertical: true)
                .help("Sleep comes back on when you stop, when the agents are done, 30 seconds after Burro quits, if Burro stops responding for 15 minutes, or below \(KeepAwakePolicy.lowBatteryPercent)% battery.")
        }
        .padding(.horizontal, 18).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading).modifier(AppCardSurface())
    }
    private var selected: KeepAwakeChoice? {
        KeepAwakeChoice.selected(manualUntil: keepAwake.manualUntil, agentsMode: keepAwake.agentsMode, picked: picked > 0 ? picked : nil,
                                 pickedAt: pickedAt > 0 ? Date(timeIntervalSince1970: pickedAt) : nil, now: Date())
    }
    private var footnote: String {
        if keepAwake.agentsMode && !keepAwake.manualActive {
            return keepAwake.lingerMinutes == 0 ? "Sleeps again as soon as the last chat finishes." : "Sleeps again \(keepAwake.lingerMinutes) min after the last chat finishes."
        }
        return "Sleep comes back on when you stop, Burro quits, or the battery drops below \(KeepAwakePolicy.lowBatteryPercent)%."
    }
    /// A duration starts a request (the standing agent mode is left as it is); "While agents work" turns that mode on
    /// and ends a running request, and turns the mode off when it is already the one on.
    private func choose(_ choice: KeepAwakeChoice) {
        switch choice {
        case .agents:
            if selected == .agents { keepAwake.agentsMode = false; return }
            if keepAwake.manualActive { keepAwake.stopManual() }
            keepAwake.agentsMode = true
        case .duration, .untilStopped:
            guard choice != selected else { return }
            picked = choice.seconds ?? 0; pickedAt = Date().timeIntervalSince1970
            keepAwake.keepAwake(for: choice.seconds)
        }
    }
    private func notice<Action: View>(_ symbol: String, _ text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(AppAppearance.secondary)
            Text(text).font(.callout).foregroundStyle(AppAppearance.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action()
        }
    }
}

/// The Keep awake choices as one segmented control that wraps onto a second line in a narrow column.
struct KeepAwakeSegments: View {
    var selected: KeepAwakeChoice?
    var choose: (KeepAwakeChoice) -> Void
    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(KeepAwakeChoice.all, id: \.self) { choice in
                let on = choice == selected
                Button { choose(choice) } label: {
                    Text(choice.title).font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? AppAppearance.text : AppAppearance.secondary)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(on ? AppAppearance.raised : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .help(choice == .agents ? (on ? "On: stays awake while a chat on this Mac works. Click to turn off." : "Stay awake whenever a chat on this Mac is working")
                      : (choice == .untilStopped ? "Stay awake until you click Stop" : "Stay awake for \(choice.title)"))
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppAppearance.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AppAppearance.separator))
        .accessibilityElement(children: .contain).accessibilityLabel("Keep awake for")
    }
}

/// Settings → Machines: the agent mode, its linger and the lid-closed permission.
struct KeepAwakeSettingsGroup: View {
    @Bindable var keepAwake: KeepAwakeStore
    var body: some View {
        SettingsGroup(title: "Keep this Mac awake while agents work on it",
                      note: "An open lid stays awake with no password. Burro's watchdog turns sleep back on when you stop, when the agents are done, 30 seconds after Burro quits, after 15 minutes without word from Burro, or below \(KeepAwakePolicy.lowBatteryPercent)% battery.",
                      isOn: $keepAwake.agentsMode) {
            SettingsRow(title: "Then stay awake for") {
                SettingsMenuPicker(label: "Then stay awake for", selection: $keepAwake.lingerMinutes,
                                   options: KeepAwakePolicy.lingerChoices.map { ($0, $0 == 0 ? "No extra time" : "\($0) minutes") })
                    .disabled(!keepAwake.agentsMode)
            }
            if keepAwake.passwordless {
                SettingsRow(title: "Closed lid", detail: "Allowed without a password") {
                    if keepAwake.ruleInstalled {
                        Button("Remove Permission…") { keepAwake.removePermission() }
                            .disabled(keepAwake.busy || keepAwake.lidClosedActive)
                            .help(keepAwake.lidClosedActive ? "Stop keeping awake first: the watchdog needs this permission to turn sleep back on." : "")
                    }
                }
            } else {
                SettingsRow(title: "Closed lid", detail: "Asks for an administrator password") {
                    Button("Allow Without a Password…") { keepAwake.allowWithoutPassword() }.disabled(keepAwake.busy)
                }
            }
            SettingsNote("A closed lid needs “pmset -a disablesleep 1”; allowing it once adds a sudoers rule for exactly “pmset -a disablesleep 0” and “… 1” (\(KeepAwakeScript.rulePath)).")
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
