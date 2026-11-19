// The Machines page's cells. Each machine is a cell of the joined surface you can act on: name and
// OS, the existing status line with its working / needs-you counts, the chats working or waiting for
// you there (a row opens the chat in Chats; a Claude chat on another machine also offers Attach),
// the agent tools installed there with Update where the tool has an updater, and New chat here plus
// Open in Terminal (this Mac) or Open SSH (another machine). Burro's cache for a machine and Clear
// live in the Local copies panel under the cells (MachinesPageContent.swift). A machine that
// stopped answering is a quieter hatched cell: since when, when Burro retries, how many of its chats
// can still be read from the local copy, its address and last error, Retry now and Forget machine.
// State is a dot and plain words; OS and model names are plain grey text, not filled tags.
import SwiftUI
import BurroCore

// MARK: Machine card

struct MachineCardView: View {
    var card: MachineCardModel
    var attaching: Set<String>
    var actions: MachinesActions
    @Environment(\.panelFill) private var fill

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: MachineSymbol.name(card)).font(.system(size: 17, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                    .frame(width: 22).accessibilityHidden(true)
                Text(card.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                if let os = card.os { MachineTextTag(text: os) }
                else if card.probing { MachineTextTag(text: "Checking…") }
                Spacer(minLength: 4)
                if card.host != nil { MachineEditButton(card: card, edit: actions.edit) }
            }
            statusRow
            VStack(alignment: .leading, spacing: 0) {
                MachinesSectionLabel(text: card.isLocal ? "Chats here" : "Chats there")
                if card.chats.isEmpty {
                    Text(card.reach == .paused ? "Paused: Burro isn't checking this machine." : "Nothing working or waiting for you.")
                        .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).padding(.vertical, 8)
                } else {
                    ForEach(Array(card.chats.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { MachineRule() }
                        MachineChatRow(session: session, host: card.host, attaching: attaching.contains(session.id), actions: actions)
                    }
                    if card.moreChats > 0 {
                        MachineRule()
                        Button(action: actions.showChats) {
                            Text("\(card.moreChats) more in Chats").font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                                .padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Show every chat on the Chats page")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                MachinesSectionLabel(text: "Harnesses")
                if card.harnesses.isEmpty {
                    Text(card.probing ? "Checking installed tools…" : (card.reach == .online || card.isLocal ? "No agent tools found." : "Checked when the machine answers."))
                        .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).padding(.vertical, 7)
                }
                ForEach(Array(card.harnesses.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { MachineRule() }
                    MachineHarnessLine(row: row) { actions.update(row.harness, card) }
                }
            }
            Spacer(minLength: 0)
            FlowLayout(spacing: 8) {
                if card.reach == .paused {
                    MachineButton(title: "Resume checks", symbol: "play") { actions.resume(card) }
                        .help("Start checking \(card.name) again")
                } else {
                    MachineButton(title: "New chat here", symbol: "plus") { actions.newChat(card) }
                        .help(card.isLocal ? "Start a chat on this Mac" : "Start a chat on \(card.name)")
                }
                if card.isLocal {
                    MachineButton(title: "Open in Terminal", symbol: "terminal") { actions.openTerminal(card) }
                        .help("Open Terminal in the main project folder")
                } else {
                    MachineButton(title: "Open SSH", symbol: "terminal") { actions.openTerminal(card) }
                        .help("Open Terminal logged in to \(card.name) over SSH, with the same strict options Burro uses")
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(fill)
        .accessibilityElement(children: .contain).accessibilityLabel(card.name)
    }

    /// Status, counts and the address on one line when they fit; the address moves under them when not.
    private var statusRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                statusText(withCounts: true).fixedSize()
                Spacer(minLength: 12)
                destinationText
            }
            VStack(alignment: .leading, spacing: 3) {
                statusText(withCounts: false).fixedSize(horizontal: false, vertical: true)
                if card.counts.working + card.counts.needYou > 0 {
                    // Drop the leading " · " so the counts start their own line.
                    countsText(lead: false).font(.system(size: 13)).padding(.leading, 16)
                }
                destinationText.padding(.leading, 16)
            }
        }
    }
    private func statusText(withCounts: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8).accessibilityHidden(true)
            (Text(card.isLocal ? "Online" : card.statusLine).foregroundStyle(AppAppearance.text) + (withCounts ? countsText(lead: true) : Text("")))
                .font(.system(size: 13))
        }
    }
    @ViewBuilder private var destinationText: some View {
        if let destination = card.host?.destination {
            Text(destination).font(.system(size: 12, design: .monospaced)).foregroundStyle(AppAppearance.tertiary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(destination)
        }
    }
    /// "· 2 working · 1 needs you": only the needs-you count in amber.
    private func countsText(lead: Bool) -> Text {
        var text = Text("")
        var first = !lead
        if card.counts.working > 0 {
            text = text + Text(first ? "" : "  ·  ").foregroundStyle(AppAppearance.tertiary) + Text("\(card.counts.working) working").foregroundStyle(AppAppearance.secondary)
            first = false
        }
        if card.counts.needYou > 0 {
            text = text + Text(first ? "" : "  ·  ").foregroundStyle(AppAppearance.tertiary)
                + Text("\(card.counts.needYou) need\(card.counts.needYou == 1 ? "s" : "") you").foregroundStyle(AppAppearance.amber)
        }
        return text
    }
    private var statusColor: Color {
        switch card.reach {
        case .local, .online: AppAppearance.green
        default: AppAppearance.tertiary
        }
    }
}

struct MachineChatRow: View {
    var session: AgentSession
    var host: RemoteHost?
    var attaching: Bool
    var actions: MachinesActions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button { actions.openChat(session) } label: {
                // The title keeps a column when the row is wide enough; in a narrow cell it gets less room.
                ViewThatFits(in: .horizontal) {
                    line(titleWidth: 170)
                    stacked
                }
                .padding(.vertical, 8).padding(.horizontal, 6)
                .background(hovering ? AppAppearance.hover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover { hovering = $0 }
            .help("Open \(session.title.isEmpty ? "this chat" : session.title) in Chats")
            .accessibilityLabel("\(session.title), \(MachinesOverview.detail(session))")
            if let host, session.provider == .claude {
                if attaching {
                    ProgressView().controlSize(.small).frame(width: 52).accessibilityLabel("Checking whether it can attach")
                } else {
                    MachineButton(title: "Attach", style: .ghost, small: true) { actions.attach(session, host) }
                        .help("Attach to this Claude background session on \(host.name) in Terminal (Burro checks it's a background session first)")
                }
            }
        }
        .padding(.horizontal, -6)
    }

    /// A narrow cell: the title and model on the first line, the state and folder under it.
    private var stacked: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(session.state == .waiting ? AppAppearance.amber : AppAppearance.green).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    title.frame(maxWidth: .infinity, alignment: .leading)
                    MachineTextTag(text: model)
                }
                Text(MachinesOverview.detail(session)).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
            }
        }
    }

    private var model: String { AquariumFish.modelName(session.model) ?? (session.provider == .codex ? "Codex" : "Claude Code") }

    private var title: some View {
        // Bold only for a chat that needs you.
        Text(session.title.isEmpty ? "Untitled chat" : session.title)
            .font(.system(size: 13, weight: session.state == .waiting ? .semibold : .regular)).lineLimit(1)
    }

    private func line(titleWidth: CGFloat) -> some View {
        HStack(spacing: 10) {
            Circle().fill(session.state == .waiting ? AppAppearance.amber : AppAppearance.green).frame(width: 8, height: 8)
            title.frame(width: titleWidth, alignment: .leading)
            // A small ideal width, so every row of a cell picks the same form and the detail truncates instead.
            Text(MachinesOverview.detail(session)).font(.system(size: 13)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
                .frame(minWidth: 40, idealWidth: 40, maxWidth: .infinity, alignment: .leading)
            MachineTextTag(text: model)
        }
    }
}

struct MachineHarnessLine: View {
    var row: MachineHarnessRow
    var update: () -> Void
    var body: some View {
        MachineKeyValue(key: row.harness.title) {
            Text(row.installed).font(.system(size: 12, design: .monospaced))
            if row.outdated, let latest = row.latest {
                Text("\(latest) available").font(.system(size: 12)).foregroundStyle(AppAppearance.amber).lineLimit(1)
            } else if row.latest != nil {
                Text("latest").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
            }
            Spacer(minLength: 6)
            if row.updating { ProgressView().controlSize(.small).accessibilityLabel("Updating \(row.harness.title)") }
            else if row.canUpdate {
                MachineButton(title: "Update", small: true, action: update).help("Run \(row.harness.title)'s own updater (asks first)")
            }
        }
    }
}

// MARK: Unreachable card

struct UnreachableMachineCard: View {
    var card: MachineCardModel
    var actions: MachinesActions

    var body: some View {
        let status = card.statusParts
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "wifi.slash").font(.system(size: 16, weight: .medium)).foregroundStyle(AppAppearance.tertiary)
                    .frame(width: 22).accessibilityHidden(true)
                Text(card.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
                if let os = card.os { MachineTextTag(text: os) }
                Spacer(minLength: 4)
                MachineEditButton(card: card, edit: actions.edit)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(AppAppearance.tertiary).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(status.head).font(.system(size: 13)).foregroundStyle(AppAppearance.secondary)
                }
                if let rest = status.rest {
                    Text(rest).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).padding(.leading, 16)
                }
            }
            MachineRule()
            VStack(alignment: .leading, spacing: 6) {
                let copy = card.localCopy ?? MachinesOverview.LocalCopy(chats: 0, lastSynced: nil)
                Text(copy.text).font(.system(size: 13)).foregroundStyle(AppAppearance.secondary)
                if let synced = copy.lastSynced {
                    Text("Last synced \(RemoteStatusLine.clock(synced, now: Date(), timeZone: .current)) · read-only until it's back")
                        .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                if card.counts.working + card.counts.needYou == 0, card.moreChats == 0, copy.chats > 0 {
                    Button(action: actions.showChats) {
                        Text("Browse them in Chats").font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary).underline()
                    }.buttonStyle(.plain).help("Its chats show in Chats as last seen")
                }
            }
            MachineRule()
            VStack(alignment: .leading, spacing: 2) {
                if let destination = card.host?.destination {
                    MachineKeyValue(key: "Address", compact: true) {
                        Text(destination).font(.system(size: 12, design: .monospaced)).foregroundStyle(AppAppearance.tertiary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
                if let error = card.lastError {
                    MachineKeyValue(key: "Last error", compact: true) {
                        Text(error).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(3).textSelection(.enabled)
                    }
                }
            }
            Spacer(minLength: 0)
            FlowLayout(spacing: 8) {
                MachineButton(title: "Retry now", symbol: "arrow.clockwise") { actions.retry(card) }.help("Check \(card.name) now")
                MachineButton(title: "Forget machine…", style: .ghost) { actions.forget(card) }
                    .help("Remove \(card.name) from Burro and delete what Burro copied from it (asks first)")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MachineHatch())
        .accessibilityElement(children: .contain).accessibilityLabel("\(card.name), unreachable")
    }
}

// MARK: Small pieces

/// An OS or model name as plain grey text (no filled pill).
struct MachineTextTag: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(1).fixedSize()
    }
}

/// The unreachable cell's quiet fill: fine diagonal lines in the separator colour.
struct MachineHatch: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 9
            }
            context.stroke(path, with: .color(AppAppearance.separator.opacity(0.55)), lineWidth: 1)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct MachinesSectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
            .padding(.bottom, 4).accessibilityAddTraits(.isHeader)
    }
}

struct MachineRule: View {
    var body: some View { Rectangle().fill(AppAppearance.separator).frame(height: 1) }
}

struct MachineKeyValue<Content: View>: View {
    var key: String
    var compact = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: compact ? .firstTextBaseline : .center, spacing: 10) {
            Text(key).font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary).frame(width: compact ? 84 : 110, alignment: .leading)
            content()
        }
        .padding(.vertical, compact ? 2 : 7)
        .frame(maxWidth: .infinity, minHeight: compact ? 0 : 24, alignment: .leading)
    }
}

struct MachineEditButton: View {
    var card: MachineCardModel
    var edit: (MachineCardModel) -> Void
    var body: some View {
        Button { edit(card) } label: {
            Image(systemName: "pencil").font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.tertiary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Edit \(card.name)'s name and address").accessibilityLabel("Edit \(card.name)")
    }
}

/// The page's buttons: amber primary (one per card at most), plain, or ghost.
struct MachineButton: View {
    enum Style { case primary, normal, ghost }
    var title: String
    var symbol: String? = nil
    var style: Style = .normal
    var small = false
    var action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title)
            }
            .font(.system(size: small ? 12 : 13, weight: .semibold))
            .foregroundStyle(style == .primary ? Color.black.opacity(0.85) : AppAppearance.text)
            .padding(.horizontal, small ? 10 : 12).frame(height: small ? 24 : 28)
            .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(style == .primary ? .clear : AppAppearance.hairline.opacity(hovering ? 1 : 0.7)))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.fixedSize()
    }
    private var fill: Color {
        switch style {
        case .primary: AppAppearance.amber
        case .normal: hovering ? AppAppearance.hover : AppAppearance.raised
        case .ghost: hovering ? AppAppearance.hover : .clear
        }
    }
}

enum MachineSymbol {
    static func name(_ card: MachineCardModel) -> String {
        if card.isLocal { return "laptopcomputer" }
        let os = (card.os ?? "").lowercased()
        if os.contains("linux") || os.contains("ubuntu") || os.contains("debian") || os.contains("fedora") { return "server.rack" }
        return "desktopcomputer"
    }
}

enum MachineFormat {
    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
