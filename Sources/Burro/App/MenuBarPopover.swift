// The menu-bar item's window-style popover (`.menuBarExtraStyle(.window)`), replacing the plain
// menu. Top to bottom: a one-line "Start a chat…" field (Return opens the New chat sheet with the
// text as its prompt, in the current project; it never starts a chat by itself), the chats waiting
// on you (up to five, newest first; a click opens one the way a notch row does), "N drafts ready"
// when the Orchestrator has replies drafted for you (opens Home, where the Brief shows them), Keep
// awake (its status, including when a closed lid is covered; a clock menu to keep awake for 1, 2
// or 4 hours or until you stop; a switch for "While agents work"; and "Stop keeping awake" while
// a timed or open-ended request runs), then Open Burro, Today (with today's focused time when
// activity tracking is on, read once each time the popover opens), Chats (what is working or
// waiting), Notes (the Notes panel, as ⌥P does) and Show notch (as ⇧⌘B does), and a quiet last
// line with Settings… and Quit Burro. The label is MenuBarLabel.
import AppKit
import SwiftUI
import BurroCore

struct MenuBarPopover: View {
    @Bindable var store: AppStore
    var notch: NotchController
    /// Fixed only for snapshots; otherwise read from the tracker when the popover opens.
    var focusedToday: TimeInterval? = nil
    /// Fixed only for snapshots; otherwise counted from the Brief and the Orchestrator's proposals.
    var draftCount: Int? = nil
    @State private var prompt = ""
    @State private var focused: TimeInterval?
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let chats = MenuBarStatus.needsYou(store.agentActivity.sessions)
        let drafts = BriefDrafts.menuTitle(draftCount ?? BriefDrafts.ready(file: store.brief.file, actions: store.orchestrator.actions, now: Date()).count)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Start a chat…", text: $prompt)
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($fieldFocused)
                    .onSubmit(startChat)
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(AppAppearance.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(fieldFocused ? AppAppearance.hairline : AppAppearance.separator))
                    .accessibilityLabel("Start a chat")
                    .accessibilityHint("Return opens the New chat sheet with this prompt")
                MenuBarKey("↩").help("Return opens the New chat sheet with this prompt; nothing starts until you press Start there")
            }.padding(2)
            if !chats.isEmpty || drafts != nil {
                MenuBarRule()
                if !chats.isEmpty {
                    Text("Needs you · \(store.agentActivity.waitingCount)".uppercased())
                        .font(.system(size: 10.5, weight: .semibold)).tracking(0.7).foregroundStyle(AppAppearance.amber)
                        .padding(.horizontal, 8).padding(.top, 2)
                    ForEach(chats) { chat in
                        MenuBarRow(action: { open(chat) }) {
                            Circle().fill(AppAppearance.amber).frame(width: 7, height: 7)
                            Text(chat.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 6)
                            Text(chat.remote?.hostName ?? Self.age(Date().timeIntervalSince(chat.updatedAt)))
                                .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                        }
                        .help("Open \(chat.title)")
                    }
                }
                if let drafts {
                    MenuBarRow(action: { go(.home) }) {
                        Image(systemName: "pencil").font(.system(size: 11, weight: .semibold)).foregroundStyle(AppAppearance.secondary).frame(width: 7)
                        Text(drafts).foregroundStyle(AppAppearance.secondary)
                        Spacer(minLength: 6)
                        Text("Review").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                    }
                    .help("Open Home, where the Brief shows the drafted replies")
                }
            }
            MenuBarRule()
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep awake").font(.system(size: 13, weight: .semibold))
                    Text(Self.keepAwakeLine(agentsMode: store.keepAwake.agentsMode, awake: store.keepAwake.awake,
                                            headline: store.keepAwake.headline, working: store.localWorkingAgents,
                                            lidClosed: store.keepAwake.lidClosedActive))
                        .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Menu {
                    ForEach(KeepAwakePolicy.durations, id: \.title) { choice in
                        Button(choice.seconds == nil ? choice.title : "For \(choice.title)") { store.keepAwake.keepAwake(for: choice.seconds) }
                    }
                    if store.keepAwake.manualActive {
                        Divider()
                        Button("Stop keeping awake") { store.keepAwake.stopManual() }
                    }
                } label: {
                    Image(systemName: "clock").font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(store.keepAwake.busy)
                .help("Keep the Mac awake for a while").accessibilityLabel("Keep awake for")
                Toggle("While agents work", isOn: Bindable(store.keepAwake).agentsMode)
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .help("Keep the Mac awake while agents work on it")
                    .accessibilityLabel("Keep awake while agents work")
            }.padding(.horizontal, 8).padding(.vertical, 4)
            if store.keepAwake.manualActive {
                MenuBarRow(action: { store.keepAwake.stopManual() }) {
                    Text("Stop keeping awake").foregroundStyle(AppAppearance.secondary); Spacer()
                }
                .help("End the timed or open-ended keep-awake request")
            }
            MenuBarRule()
            MenuBarRow(action: { go(.home) }) { Text("Open Burro"); Spacer() }
            MenuBarRow(action: { go(.today) }) {
                Text("Today"); Spacer()
                if let focused = focusedToday ?? focused, focused > 0 {
                    Text("\(TodaySummary.duration(focused)) focused").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                }
            }
            MenuBarRow(action: { go(.remote) }) {
                Text("Chats"); Spacer()
                if let line = Self.chatsLine(working: store.agentActivity.workingCount, waiting: store.agentActivity.waitingCount) {
                    Text(line).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                }
            }
            MenuBarRow(action: { dismiss(); store.showNotes?(.last) }) {
                Text("Notes"); Spacer()
                if store.notesShortcut { MenuBarKey("⌥P") }
            }
            .help("Open the Notes panel")
            MenuBarRow(action: { dismiss(); notch.show() }) {
                Text("Show notch"); Spacer()
                MenuBarKey("⇧⌘B")
            }
            .help("Open the agent notch")
            MenuBarRule()
            HStack(spacing: 14) {
                SettingsLink { Text("Settings…") }.buttonStyle(.plain)
                Spacer()
                Button("Quit Burro") { NSApp.terminate(nil) }.buttonStyle(.plain).keyboardShortcut("q")
            }
            .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .padding(10)
        .frame(width: 320)
        .foregroundStyle(AppAppearance.text)
        .background(AppAppearance.surface)
        .task {
            guard focusedToday == nil, store.activityTracker.enabled else { focused = nil; return }
            focused = await store.activityTracker.day(Date()).focused
        }
    }

    /// Return: the New chat sheet, prefilled. Never starts anything.
    private func startChat() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { store.openNewChat() } else { store.startChat(withText: text) }
        prompt = ""
        dismiss()
        notch.openDashboardWindow()
    }
    private func open(_ chat: AgentSession) {
        dismiss()
        notch.select(chat)
    }
    private func go(_ page: AppPage) {
        dismiss()
        store.go(to: page)
        notch.openDashboardWindow()
    }

    /// "While agents work · 3 now" in agent mode, else what Keep awake is doing; " · lid closed"
    /// when a closed lid is covered too.
    nonisolated static func keepAwakeLine(agentsMode: Bool, awake: Bool, headline: String, working: Int, lidClosed: Bool = false) -> String {
        let line: String
        if agentsMode && working > 0 { line = "While agents work · \(working) now" }
        else if agentsMode && !awake { line = "While agents work · none now" }
        else { line = headline }
        return lidClosed ? line + " · lid closed" : line
    }
    /// "3 working · 2 need you", or nil when nothing is.
    nonisolated static func chatsLine(working: Int, waiting: Int) -> String? {
        let parts = [working > 0 ? "\(working) working" : nil, waiting > 0 ? "\(waiting) need\(waiting == 1 ? "s" : "") you" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    nonisolated static func age(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        return minutes < 1 ? "now" : minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h"
    }
}

/// A full-width row in the popover: a soft highlight on hover, the whole row clickable.
private struct MenuBarRow<Content: View>: View {
    var action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content }
                .font(.system(size: 13))
                .padding(.horizontal, 8).frame(height: 30)
                .background(hovering ? AppAppearance.hover : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct MenuBarRule: View {
    var body: some View { Rectangle().fill(AppAppearance.separator).frame(height: 1).padding(.vertical, 4) }
}

private struct MenuBarKey: View {
    var key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(key).font(.system(size: 11, design: .monospaced)).foregroundStyle(AppAppearance.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(AppAppearance.raised, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(AppAppearance.hairline))
    }
}
