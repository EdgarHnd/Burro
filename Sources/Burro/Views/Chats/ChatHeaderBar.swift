// The open chat's header on the Chats page: its title with a state chip (Needs you, Working,
// Ready to read, Idle), one quiet line "Claude · Opus 5.5 · This Mac · focustown · turn 18 min"
// (the turn clock only while it works), the offline line for a remote chat shown from Burro's
// copy, then Stop (⌘.) while it can be stopped from Burro or "Stop it in Claude" when only the
// Claude app or a terminal can, the ⋯ menu and the details-panel toggle. Layout only: the values
// and actions come from the chat detail (`ChatControl` decides Stop with the composer's plan).
import SwiftUI
import BurroCore

struct ChatHeaderBar<Offline: View, Trailing: View>: View {
    var title: String
    var status: ChatPageStatus
    /// "Claude · Opus 5.5", "This Mac · focustown".
    var agent: String
    var place: String
    /// When the current turn began, while it works.
    var turnStart: Date?
    var loading = false
    var stop: ChatStop?
    var stopping = false
    var canOpen = true
    var onStop: () -> Void = {}
    var showsInspector: Bool
    var toggleInspector: () -> Void
    @ViewBuilder var offline: Offline
    @ViewBuilder var menu: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    ChatStateChip(status: status)
                }
                HStack(spacing: 6) {
                    Text(agent).lineLimit(1)
                    Text("·")
                    Text(place).lineLimit(1).truncationMode(.middle)
                    if let turnStart {
                        Text("·")
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(ChatTurnClock.label(context.date.timeIntervalSince(turnStart))).monospacedDigit().lineLimit(1)
                        }
                    }
                }
                .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                offline
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if loading { ProgressView().controlSize(.small) }
            if let stop { ChatStopControl(stop: stop, stopping: stopping, canOpen: canOpen, action: onStop) }
            menu
            Button(action: toggleInspector) {
                Image(systemName: "sidebar.right").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(showsInspector ? AppAppearance.text : AppAppearance.secondary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showsInspector ? "Hide details" : "Show details")
            .accessibilityLabel(showsInspector ? "Hide details" : "Show details")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

/// "● Working" in the state's colour, on a faint tint of it.
struct ChatStateChip: View {
    var status: ChatPageStatus
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(status.title).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(status == .idle ? AppAppearance.secondary : color)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(color.opacity(status == .idle ? 0.12 : 0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
    var color: Color { ChatStatusColor.of(status) }
}

enum ChatStatusColor {
    static func of(_ status: ChatPageStatus) -> Color {
        switch status {
        case .needsYou: AppAppearance.amber
        case .working: AppAppearance.green
        case .readyToRead: AppAppearance.blue
        case .idle: AppAppearance.tertiary
        }
    }
}

/// "Stop ⌘." while Burro can stop the chat, or "Stop it in Claude ↗" when only Claude can.
struct ChatStopControl: View {
    var stop: ChatStop
    var stopping: Bool
    var canOpen: Bool
    var action: () -> Void
    var body: some View {
        if stop == .elsewhere {
            Button(action: action) {
                ChatButtonLabel(title: "Stop it in Claude", symbol: "arrow.up.right", enabled: canOpen)
            }
            .buttonStyle(.plain).disabled(!canOpen)
            .help("This chat runs in the Claude app or a terminal; only it can stop the chat")
        } else {
            Button(action: action) {
                HStack(spacing: 6) {
                    if stopping { ProgressView().controlSize(.mini) }
                    Text(stopping ? "Stopping…" : "Stop").font(.system(size: 12, weight: .semibold))
                    ChatKey("⌘.")
                }
                .foregroundStyle(AppAppearance.text)
                .padding(.horizontal, 10).frame(height: 28)
                .background(AppAppearance.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AppAppearance.hairline))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(stopping)
            .keyboardShortcut(".", modifiers: .command)
            .help("Stop (⌘.). The conversation is kept.")
            .accessibilityLabel("Stop")
        }
    }
}

/// A key cap such as "⌘." or "↩" beside a button's title.
struct ChatKey: View {
    var key: String
    var onAccent = false
    init(_ key: String, onAccent: Bool = false) { self.key = key; self.onAccent = onAccent }
    var body: some View {
        Text(key).font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(onAccent ? Color.black.opacity(0.7) : AppAppearance.secondary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(onAccent ? Color.black.opacity(0.1) : AppAppearance.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(onAccent ? Color.black.opacity(0.12) : AppAppearance.hairline))
            .accessibilityHidden(true)
    }
}

/// A bordered 28 pt button face: quiet by default, amber for the one primary action.
struct ChatButtonLabel: View {
    var title: String
    var symbol: String? = nil
    var key: String? = nil
    var primary = false
    var enabled = true
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            if let key { ChatKey(key, onAccent: primary && enabled) }
        }
        .foregroundStyle(primary && enabled ? Color.black.opacity(0.85) : (enabled ? AppAppearance.text : AppAppearance.tertiary))
        .padding(.horizontal, 10).frame(height: 28)
        .background(primary && enabled ? AppAppearance.amber : AppAppearance.raised.opacity(enabled ? 1 : 0.5),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(primary && enabled ? .clear : AppAppearance.hairline))
        .contentShape(Rectangle())
        .fixedSize()
    }
}
