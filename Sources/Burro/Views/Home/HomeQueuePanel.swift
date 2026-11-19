// Home's queue panel, the right of the main row: the attention queue (HomeQueue.swift) with three
// tabs, then Ask the Orchestrator under a hairline.
// - Waiting on you: the first card as the decision card with its draft and the usual Send / Edit /
//   Discard / Open / hand-off (HomeNeedsCard, built by HomeNeedsBuilder), then compact rows.
// - Working: compact rows (a dot, the title, "machine · state · turn time") each with what
//   `HomeBoard.stopOffer` allows: Stop (ChatReply.stop, run by the owner's click only), Open in
//   Claude, or "Stop it in its terminal"; a Stop result line under the row until the turn changes.
//   Stuck chats get a grey dot and the Brief's line; no red anywhere.
// - Ready to read: compact rows with the Brief's headline or the already-scanned preview, and Mark
//   all read (Burro's own "seen"; providers' unread markers are never written).
// Each tab ends in "Show all in Chats". Plain values in (HomeBoardData), so snapshots can draw it.
import SwiftUI
import BurroCore

struct HomeQueuePanel<Ask: View>: View {
    var data: HomeBoardData
    var actions: HomeBoardActions
    var editingID: String?
    var editor: (String) -> AnyView = { _ in AnyView(EmptyView()) }
    /// The tab picked by the owner; nil follows `HomeQueueTabs.initial`.
    @Binding var selection: String?
    @ViewBuilder var ask: () -> Ask

    var body: some View {
        let tabs = HomeQueueTabs.tabs(needsYou: data.needsTotal, working: data.workingTotal, toRead: data.toReadTotal)
        let initial = HomeQueueTabs.initial(needsYou: data.needsTotal, working: data.workingTotal, toRead: data.toReadTotal).rawValue
        PanelCell {
            VStack(alignment: .leading, spacing: 0) {
                AttentionQueue(tabs: tabs.map { AttentionQueueTab(id: $0.id, title: $0.title, short: $0.short, count: $0.count, needsYou: $0.kind == .waiting) },
                               selection: Binding(get: { selection ?? initial }, set: { selection = $0 })) { tab in
                    switch HomeQueueTab.Kind(rawValue: tab) ?? .waiting {
                    case .waiting:
                        NeedsQueueList(cards: data.needsYou, total: data.needsTotal, actions: actions, editingID: editingID,
                                       editor: editor, checking: data.checking)
                    case .working:
                        HomeWorkingList(cards: data.working, total: data.workingTotal, actions: actions, checking: data.checking)
                    case .toRead:
                        HomeReadList(rows: data.toRead, total: data.toReadTotal, actions: actions, checking: data.checking)
                    }
                }
                Button(action: actions.showAll) {
                    HStack(spacing: 4) {
                        Text("Show all in Chats")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                }
                .buttonStyle(.plain).help("Open Chats").padding(.top, 12)
                Spacer(minLength: 16)
                Rectangle().fill(AppAppearance.separator).frame(height: 1).padding(.horizontal, -20).padding(.bottom, 14)
                ask()
            }
        }
    }
}

/// A row's state dot.
private struct QueueDot: View {
    var color: Color
    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }.accessibilityHidden(true)
    }
}

private struct QueueEmpty: View {
    var text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
            Text(text)
        }
        .font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary).padding(.vertical, 4)
    }
}

/// The Working tab.
struct HomeWorkingList: View {
    var cards: [HomeWorkingCardData]
    var total: Int
    var actions: HomeBoardActions
    var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if cards.isEmpty {
                QueueEmpty(text: checking ? "Checking on your agents…" : "No agents are working.")
            }
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                if index > 0 { Rectangle().fill(AppAppearance.separator).frame(height: 1) }
                HomeWorkingRow(card: card, actions: actions)
            }
            if total > cards.count {
                Text("\(total - cards.count) more working").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).padding(.top, 8)
            }
        }
    }
}

private struct HomeWorkingRow: View {
    var card: HomeWorkingCardData
    var actions: HomeBoardActions
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                QueueDot(color: card.stuck ? AppAppearance.tertiary : AppAppearance.green)
                Button { actions.open(card.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.title).font(.system(size: 13)).foregroundStyle(AppAppearance.text).lineLimit(1)
                        Text([card.machine, card.state, card.time].joined(separator: " · ")).font(.system(size: 11.5)).monospacedDigit()
                            .foregroundStyle(AppAppearance.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("\(card.title)\n\(card.state) · \(card.time)\nClick to open the chat")
                HomeStopControl(card: card, actions: actions).fixedSize()
            }
            if let note = card.note {
                Text(note).font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 16)
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 6)
        .background(hovering ? AppAppearance.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open") { actions.open(card.id) }
            if let handOff = card.handOff { Button(handOff) { actions.handOff(card.id) } }
            if card.stop == .stop { Button("Stop") { actions.stop(card.id) }.disabled(card.stopping) }
        }
    }
}

/// What a working chat offers, by `HomeBoard.stopOffer`: Stop, the hand-off to the app that owns
/// it, "Stop it in its terminal", or nothing until Burro knows.
struct HomeStopControl: View {
    var card: HomeWorkingCardData
    var actions: HomeBoardActions

    var body: some View {
        switch card.stop {
        case .stop:
            Button { actions.stop(card.id) } label: {
                HStack(spacing: 4) {
                    if card.stopping { ProgressView().controlSize(.mini) }
                    Text(card.stopping ? "Stopping…" : "Stop")
                }
            }
            .buttonStyle(HomeButtonStyle(weight: .ghost, compact: true)).disabled(card.stopping)
            .help("Stop this turn. The conversation is kept.").accessibilityLabel("Stop \(card.title)")
        case .openInProvider:
            if let handOff = card.handOff {
                Button(handOff) { actions.handOff(card.id) }.buttonStyle(HomeButtonStyle(weight: .ghost, compact: true))
                    .help("This chat runs in the Claude app or a terminal; only it can stop the chat")
            }
        case .elsewhere:
            Text("Stop it in its terminal").font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                .help("This chat runs interactively in a terminal; only it can stop the chat")
        case .none:
            EmptyView()
        }
    }
}

/// The Ready to read tab.
struct HomeReadList: View {
    var rows: [HomeReadRowData]
    var total: Int
    var actions: HomeBoardActions
    var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                QueueEmpty(text: checking ? "Checking on your agents…" : "Nothing to read.")
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Rectangle().fill(AppAppearance.separator).frame(height: 1) }
                HomeReadRow(row: row) { actions.open(row.id) }
            }
            if !rows.isEmpty {
                HStack(spacing: 10) {
                    Button("Mark all read", action: actions.markAllRead)
                        .buttonStyle(HomeButtonStyle(weight: .ghost, compact: true)).padding(.leading, -8)
                        .help("Mark these results read in Burro (the providers' own unread markers are left alone)")
                    if total > rows.count {
                        Text("\(total - rows.count) more to read").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                    }
                }
                .padding(.top, 8)
            }
        }
    }
}

private struct HomeReadRow: View {
    var row: HomeReadRowData
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                QueueDot(color: AppAppearance.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.system(size: 13)).foregroundStyle(AppAppearance.text).lineLimit(1)
                    Text(row.outcome ?? "Finished").font(.system(size: 11.5))
                        .foregroundStyle(row.outcome == nil ? AppAppearance.tertiary : AppAppearance.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(row.time).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(AppAppearance.tertiary).lineLimit(1).fixedSize()
            }
            .padding(.vertical, 9).padding(.horizontal, 6).contentShape(Rectangle())
            .background(hovering ? AppAppearance.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, -6)
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .help(row.outcome.map { "\(row.title)\n\($0)" } ?? "Open this chat")
        .accessibilityLabel("\(row.title), ready to read. \(row.outcome ?? "")")
    }
}
