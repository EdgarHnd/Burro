// The Settings window's building blocks: the eight areas in its sidebar, a pane's title and
// one-line summary, the card a group of controls sits in (title, explanation, an optional switch
// on the right, rows under a hairline), a labelled row, a switch, and the sidebar button.
import SwiftUI
import BurroCore

/// The areas in the Settings sidebar, in order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, chats, orchestrator, activity, machines, notifications, privacy, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .chats: "Chats"
        case .orchestrator: "Orchestrator"
        case .activity: "Activity"
        case .machines: "Machines"
        case .notifications: "Notifications"
        case .privacy: "Privacy and data"
        case .advanced: "Advanced"
        }
    }
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .chats: "bubble.left"
        case .orchestrator: "sparkle"
        case .activity: "calendar"
        case .machines: "desktopcomputer"
        case .notifications: "bell"
        case .privacy: "lock"
        case .advanced: "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// A pane's big title and the sentence under it.
struct SettingsPaneHeader: View {
    var title: String
    var summary: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(AppAppearance.text)
                .accessibilityAddTraits(.isHeader)
            Text(summary).font(.system(size: 14)).foregroundStyle(AppAppearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One card of related controls. The title row can carry the group's own switch; rows go under a hairline.
struct SettingsGroup<Content: View>: View {
    var title: String
    var note: String? = nil
    var isOn: Binding<Bool>? = nil
    var switchDisabled = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    if let note {
                        Text(note).foregroundStyle(AppAppearance.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let isOn { SettingsSwitch(label: title, isOn: isOn).disabled(switchDisabled) }
            }
            if Content.self != EmptyView.self {
                SettingsRule()
                content()
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(AppCardSurface())
    }
}

extension SettingsGroup where Content == EmptyView {
    init(title: String, note: String? = nil, isOn: Binding<Bool>? = nil, switchDisabled: Bool = false) {
        self.init(title: title, note: note, isOn: isOn, switchDisabled: switchDisabled) { EmptyView() }
    }
}

/// "Label ……… detail [control]" inside a group.
struct SettingsRow<Trailing: View>: View {
    var title: String
    var detail: String? = nil
    /// A small explanation under the label.
    var note: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let note { SettingsNote(note) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).monospacedDigit()
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
            trailing()
        }
        .frame(minHeight: 24)
    }
}

/// The on/off switch every group uses: green when on, labelled for VoiceOver.
struct SettingsSwitch: View {
    var label: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(label, isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(AppAppearance.green)
            .accessibilityLabel(label)
    }
}

/// A small secondary explanation under a row.
struct SettingsNote: View {
    var text: String
    var color: Color = AppAppearance.tertiary
    init(_ text: String, color: Color = AppAppearance.tertiary) { self.text = text; self.color = color }
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsRule: View {
    var body: some View { Rectangle().fill(AppAppearance.separator).frame(height: 1) }
}

/// A menu picker sized to its choice, with the label kept for VoiceOver.
struct SettingsMenuPicker<Value: Hashable>: View {
    var label: String
    @Binding var selection: Value
    var options: [(Value, String)]
    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize().accessibilityLabel(label)
    }
}

/// One area in the sidebar.
struct SettingsSidebarButton: View {
    var pane: SettingsPane
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: pane.symbol).font(.system(size: 13)).frame(width: 18)
                Text(pane.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? AppAppearance.text : AppAppearance.secondary)
            .padding(.horizontal, 10).frame(height: 32)
            .background(selected ? AppAppearance.raised : (hovering ? AppAppearance.hover : .clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
