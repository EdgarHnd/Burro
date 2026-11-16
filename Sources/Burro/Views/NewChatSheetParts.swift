// Pieces of the New chat sheet: the labelled choice chips (Project, Agent, Access, machine), the
// Recent and Templates rows under the prompt (a click puts the prompt in the field; the owner's own
// templates have a delete button on hover and in their context menu; "Save as template" saves the
// current prompt), the "Start in a new worktree" switch with the branch it will create and the
// provider's quota line, and the footer's key hints and buttons. Plain values in, actions out;
// the sheet owns the state.
import SwiftUI
import BurroCore

enum NewChatStyle {
    /// Ink on the amber Start button, readable in both appearances.
    static let onAmber = Color(red: 0.12, green: 0.10, blue: 0.06)
    static let chipRadius: CGFloat = 8
}

/// A choice chip: a quiet label, the value and a chevron, opening a menu.
struct NewChatChip<Content: View>: View {
    var label: String?
    var symbol: String? = nil
    var dot: Color? = nil
    var title: String
    var busy = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        Menu { content() } label: {
            HStack(spacing: 5) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else if let dot {
                    Circle().fill(dot).frame(width: 6, height: 6)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(AppAppearance.tertiary)
                }
                if let label { Text(label).foregroundStyle(AppAppearance.tertiary) }
                Text(title).foregroundStyle(AppAppearance.text).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(AppAppearance.tertiary)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8).frame(height: 28)
            .background(AppAppearance.raised, in: RoundedRectangle(cornerRadius: NewChatStyle.chipRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: NewChatStyle.chipRadius, style: .continuous).strokeBorder(AppAppearance.hairline))
            .contentShape(RoundedRectangle(cornerRadius: NewChatStyle.chipRadius, style: .continuous))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// A small uppercase section label ("RECENT", "TEMPLATES").
struct NewChatSectionLabel: View {
    var title: String
    var body: some View {
        Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.9).foregroundStyle(AppAppearance.tertiary)
    }
}

/// A key cap in hints and buttons.
struct NewChatKeyCap: View {
    var keys: String
    var onAmber = false
    var body: some View {
        Text(keys).font(.system(size: 11, design: .monospaced))
            .foregroundStyle(onAmber ? NewChatStyle.onAmber : AppAppearance.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(onAmber ? NewChatStyle.onAmber.opacity(0.12) : AppAppearance.raised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(onAmber ? NewChatStyle.onAmber.opacity(0.18) : AppAppearance.hairline))
    }
}

/// One tappable prompt chip (a recent prompt or a template), with an optional delete button on hover.
struct NewChatPromptChip: View {
    var title: String
    var symbol: String? = nil
    var help: String
    var maxWidth: CGFloat = 300
    var onDelete: (() -> Void)? = nil
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 4) {
            Button(action: action) {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .medium)).foregroundStyle(AppAppearance.secondary) }
                    Text(title).lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.text)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            if let onDelete, hovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(AppAppearance.tertiary)
                        .frame(width: 14, height: 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete template")
                .accessibilityLabel("Delete template \(title)")
            }
        }
        .padding(.horizontal, 10).frame(height: 28)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .background(AppAppearance.raised, in: RoundedRectangle(cornerRadius: NewChatStyle.chipRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: NewChatStyle.chipRadius, style: .continuous)
            .strokeBorder(hovering ? AppAppearance.hairline : AppAppearance.separator))
        .fixedSize(horizontal: true, vertical: false)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Use this prompt", action: action)
            if let onDelete { Button("Delete template", role: .destructive, action: onDelete) }
        }
    }
}

/// Recent prompts for the chosen project and the templates, under the prompt.
struct NewChatPromptShortcuts: View {
    var recent: [String]
    var templates: [LaunchTemplate]
    var canSave: Bool
    var use: (String) -> Void
    var save: () -> Void
    var delete: (String) -> Void
    /// Recent prompts shown as chips; the rest are in "More".
    static let shownRecent = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !recent.isEmpty {
                NewChatSectionLabel(title: "Recent")
                FlowLayout(spacing: 6) {
                    ForEach(Array(recent.prefix(Self.shownRecent).enumerated()), id: \.offset) { _, prompt in
                        NewChatPromptChip(title: LaunchPromptMemory.firstLine(prompt), help: "Put this prompt in the field") { use(prompt) }
                    }
                    if recent.count > Self.shownRecent {
                        Menu {
                            ForEach(Array(recent.dropFirst(Self.shownRecent).enumerated()), id: \.offset) { _, prompt in
                                Button(LaunchPromptMemory.firstLine(prompt, limit: 70)) { use(prompt) }
                            }
                        } label: {
                            Text("\(recent.count - Self.shownRecent) more").font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                                .padding(.horizontal, 8).frame(height: 28)
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .help("Older prompts started in this project")
                    }
                }
            }
            NewChatSectionLabel(title: "Templates").padding(.top, recent.isEmpty ? 0 : 4)
            FlowLayout(spacing: 6) {
                ForEach(templates) { template in
                    NewChatPromptChip(title: template.title, symbol: template.symbol, help: "Put this template in the field",
                                      onDelete: template.builtIn ? nil : { delete(template.id) }) { use(template.prompt) }
                }
                if canSave {
                    Button(action: save) {
                        Label("Save as template", systemImage: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                            .padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).fixedSize()
                    .help("Keep the current prompt as a template")
                }
            }
        }
    }
}

/// "Start in a new worktree" with the branch it will create, and the provider's quota on the right.
struct NewChatWorktreeRow: View {
    /// nil hides the switch (another machine, or not a git project).
    var worktree: Binding<Bool>?
    var branch: String
    var quota: String?
    var body: some View {
        HStack(spacing: 10) {
            if let worktree {
                NewChatSwitch(title: "Start in a new worktree", isOn: worktree)
                    .help("Burro makes a git worktree on a new branch and starts the chat there")
                Text(branch).font(.system(size: 11, design: .monospaced)).foregroundStyle(AppAppearance.tertiary)
                    .lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                    .opacity(worktree.wrappedValue ? 1 : 0.7)
                    .help(worktree.wrappedValue ? "The branch Burro will create (with -2 if that name is taken)" : "The branch it would create")
            }
            Spacer(minLength: 8)
            if let quota {
                Text(quota).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(1).fixedSize()
            }
        }
        .frame(minHeight: 22)
    }
}

/// An on/off switch drawn in Burro's style: green track when on, the label beside it; the whole row toggles.
struct NewChatSwitch: View {
    var title: String
    @Binding var isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button {
            if reduceMotion { isOn.toggle() } else { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } }
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? AppAppearance.green : AppAppearance.raised)
                        .overlay(Capsule().strokeBorder(isOn ? Color.clear : AppAppearance.hairline))
                    Circle().fill(isOn ? NewChatStyle.onAmber : AppAppearance.secondary).frame(width: 14, height: 14).padding(2)
                }
                .frame(width: 32, height: 18)
                Text(title).font(.system(size: 13)).foregroundStyle(AppAppearance.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// The footer: key hints on the left, Cancel and Start on the right.
struct NewChatFooter: View {
    var canStart: Bool
    var cancel: () -> Void
    var start: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                hint("⌘↩", "start")
                hint("⇧⌘↩", "start and stay")
                hint("⌘1–9", "project")
            }
            .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
            Spacer(minLength: 8)
            Button(action: cancel) {
                HStack(spacing: 6) { Text("Cancel"); NewChatKeyCap(keys: "esc") }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(AppAppearance.text)
                    .padding(.horizontal, 12).frame(height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AppAppearance.hairline))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).keyboardShortcut(.cancelAction)
            Button(action: start) {
                HStack(spacing: 6) { Text("Start chat"); NewChatKeyCap(keys: "⌘↩", onAmber: true) }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(NewChatStyle.onAmber)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(AppAppearance.amber, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .opacity(canStart ? 1 : 0.4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canStart)
        }
    }

    private func hint(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 5) { NewChatKeyCap(keys: keys); Text(text) }.fixedSize()
    }
}
