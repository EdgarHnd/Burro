// Chats you just started, shown on the Chats page until the real session appears: a "Starting"
// group at the top of the list and, when one is selected, a detail pane saying what is happening.
// A starting row lines up with the chat rows below it: the agent's mark (dimmed) in the same
// leading column, a small spinner or the amber failure mark on its corner, then title and status.
// While Claude's start check runs the row says "Starting… checking it got going"; a failure shows
// the reason with Retry (the New chat sheet again, prefilled with the same request) and Dismiss;
// a chat that started but hasn't appeared after a while offers its provider's own view instead.
// Dismiss on a row that is still starting cancels the start where it still can: before the
// worktree is made or the provider is called nothing happens, and a worktree already made for it
// is undone (AppStore+Launch).
// A chat starting on another machine names it ("Starting on Studio…"); once it starts, its row
// gives way to the chat itself (its placeholder in that machine's list) and is no longer shown.
import SwiftUI
import BurroCore

/// The "Starting" group above the chat list's sections. Draws nothing when there is no pending launch.
struct PendingLaunchRows: View {
    @Bindable var store: AppStore
    var body: some View {
        let launches = store.pendingLaunches.visible
        // Hidden rows (remote chats handed over to their placeholder) still need the hand-over check.
        if !store.pendingLaunches.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if !launches.isEmpty {
                    ChatsSectionHeader(title: "Starting", count: launches.count, color: AppAppearance.tertiary)
                    ForEach(launches) { launch in
                        PendingLaunchRow(store: store, launch: launch, selected: store.remoteSelection == launch.rowID)
                    }
                }
            }
            // A session can also appear through the regular refresh; hand over as soon as it does.
            .onChange(of: store.notchChatSessions.map(\.id)) { _, _ in store.reconcileLaunches() }
        }
    }
}

private struct PendingLaunchRow: View {
    var store: AppStore
    var launch: PendingLaunch
    var selected: Bool
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let status = launch.status(now: context.date)
            Button { store.remoteSelection = launch.rowID } label: {
                HStack(alignment: .center, spacing: ChatListRowView.gap) {
                    // The list's leading column: the agent's mark, with a spinner or the failure on its corner.
                    ProviderAvatar(provider: launch.request.provider == .codex ? .codex : .claude, id: launch.rowID,
                                   active: false, size: ChatListRowView.column)
                        .opacity(0.6)
                        .overlay(alignment: .bottomTrailing) {
                            Group {
                                if launch.isFailed {
                                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(AppAppearance.amber)
                                } else {
                                    ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 9, height: 9)
                                }
                            }
                            .padding(1).background(selected ? AppAppearance.raised : AppAppearance.background, in: Circle())
                            .offset(x: 3, y: 2)
                        }
                        .frame(width: ChatListRowView.column, height: ChatListRowView.column)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(launch.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).foregroundStyle(AppAppearance.text)
                        Text([launch.request.provider.title, launch.isRemote ? launch.place : nil,
                              URL(fileURLWithPath: launch.request.folder).lastPathComponent, status].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11)).lineLimit(1)
                            .foregroundStyle(launch.isFailed ? AppAppearance.amber : AppAppearance.tertiary)
                    }
                    Spacer(minLength: 6)
                    if launch.isFailed {
                        Button("Retry") { store.retryLaunch(launch) }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppAppearance.text)
                            .accessibilityHint("Opens the New chat sheet with the same request")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(selected ? AppAppearance.raised : (hovering ? AppAppearance.hover : .clear),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(launch.title), \(launch.request.provider.title), \(launch.place), \(status)")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .contextMenu {
                if launch.isFailed { Button("Retry…") { store.retryLaunch(launch) } }
                Button("Dismiss") { store.dismissLaunch(launch) }
            }
        }
    }
}

/// The detail pane while a selected chat is starting or failed to start.
struct PendingLaunchDetail: View {
    var store: AppStore
    var launch: PendingLaunch

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(launch.title).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                    Text("\(launch.request.provider.title) · \(launch.place) · \(URL(fileURLWithPath: launch.request.folder).lastPathComponent) · \(launch.request.access.title)")
                        .font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
                }
                Text(launch.request.trimmedPrompt)
                    .font(.system(size: 13)).foregroundStyle(AppAppearance.text).lineLimit(12)
                    .textSelection(.enabled)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppAppearance.separator))
                state(now: context.date)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32).padding(.vertical, 26)
            .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var startingText: String {
        let place = launch.isRemote ? " on \(launch.place)" : ""
        return launch.request.provider == .claude
            ? "Starting Claude Code\(place). Burro waits until the session writes its first line (up to 20 seconds), so one stuck at a prompt is never shown as started."
            : "Starting Codex\(place)…"
    }

    @ViewBuilder private func state(now: Date) -> some View {
        switch launch.phase {
        case .starting:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ProgressView().controlSize(.small)
                Text(startingText)
                    .font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .started:
            if launch.isOverdue(now: now), launch.isRemote {
                VStack(alignment: .leading, spacing: 10) {
                    Text("It started on \(launch.place), but it isn't in Burro's list yet. It appears at the next check of \(launch.place).")
                        .font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).fixedSize(horizontal: false, vertical: true)
                    PillButton(title: "Dismiss", symbol: "xmark") { store.dismissLaunch(launch) }
                }
            } else if launch.isOverdue(now: now) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("It started, but it isn't in Burro's list yet. It usually shows up within a minute.")
                        .font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        PillButton(title: launch.request.provider == .codex ? "Open in Codex" : "Attach in Terminal", symbol: "arrow.up.right") {
                            store.openStartedLaunch(launch)
                        }
                        PillButton(title: "Dismiss", symbol: "xmark") { store.dismissLaunch(launch) }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Started. Opening the conversation…").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label { Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.system(size: 12)).foregroundStyle(AppAppearance.amber)
                HStack(spacing: 8) {
                    PillButton(title: "Retry…", symbol: "arrow.clockwise") { store.retryLaunch(launch) }
                    PillButton(title: "Dismiss", symbol: "xmark") { store.dismissLaunch(launch) }
                }
            }
        }
    }
}
