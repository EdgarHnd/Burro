// The Machines page body and its cards. Each machine is a card you can act on: name and OS, the
// existing status line with its working / needs-you counts, the chats working or waiting for you
// there (a row opens the chat in Chats; a Claude chat on another machine also offers Attach), the
// agent tools installed there with Update where the tool has an updater, Burro's cache for that
// machine with Clear, and New chat here plus Open in Terminal (this Mac) or Open SSH (another
// machine). A machine that stopped answering is a quieter dashed card: since when, when Burro
// retries, how many of its chats can still be read from the local copy, its address and last
// error, Retry now and Forget machine. Below the cards, "Add a machine" takes an SSH address and
// opens the existing editor prefilled, and Tailscale devices that aren't set up yet offer Add over
// SSH. Cards share a row height and wrap to fewer columns in a narrow window.
import SwiftUI
import BurroCore

/// The header: title, the one-line headline and Check all now.
struct MachinesHeader: View {
    var model: MachinesPageModel
    var actions: MachinesActions
    var body: some View {
        PageHeader(title: "Machines", subtitle: model.headline) {
            if model.checking { ProgressView().controlSize(.small).accessibilityLabel("Checking machines") }
            PillButton(title: "Check all now", symbol: "arrow.clockwise", action: actions.checkAll)
                .help("Check every machine's chats and tools now")
        }
    }
}

struct MachinesPage: View {
    var model: MachinesPageModel
    var actions: MachinesActions

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let message = model.message {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(AppAppearance.tertiary)
                    Text(message).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button(action: actions.dismissMessage) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(AppAppearance.tertiary)
                        .accessibilityLabel("Dismiss message").help("Dismiss")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .modifier(AppCardSurface(radius: 10))
            }
            MachinesCardGrid(spacing: 16) {
                ForEach(model.cards) { card in
                    if card.reach == .unreachable {
                        UnreachableMachineCard(card: card, actions: actions).layoutValue(key: MachineCardFlex.self, value: (260, 3))
                    } else {
                        MachineCardView(card: card, attaching: model.attaching, actions: actions)
                    }
                }
            }
            AddMachineRow(add: actions.add)
            if !model.tailnet.isEmpty { TailnetDevices(peers: model.tailnet, add: actions.addTailnet) }
            VStack(alignment: .leading, spacing: 4) {
                if !model.tailscaleInstalled {
                    Text("Install Tailscale to see every device on your tailnet here.")
                }
                Text("Versions are read on each machine with the tool's own --version; latest releases come from npm. Update runs the tool's own updater after you confirm.")
            }
            .font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Layout

/// How wide a card wants to be: its narrowest width and its share of spare room in its row.
struct MachineCardFlex: LayoutValueKey {
    static let defaultValue: (basis: CGFloat, grow: CGFloat) = (440, 5)
}

/// Cards wrap like CSS flex-wrap: as many fit on a row as their narrowest widths allow, the row's
/// spare width is shared by each card's grow factor, and every card in a row gets the row's height.
struct MachinesCardGrid: SwiftUI.Layout {
    var spacing: CGFloat

    private struct Row { var indices: [Int]; var widths: [CGFloat]; var height: CGFloat }
    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var groups: [[Int]] = [], current: [Int] = [], used: CGFloat = 0
        for index in subviews.indices {
            let basis = subviews[index][MachineCardFlex.self].basis
            let needed = current.isEmpty ? basis : used + spacing + basis
            if !current.isEmpty && needed > width { groups.append(current); current = [index]; used = basis }
            else { current.append(index); used = needed }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.map { indices in
            let flex = indices.map { subviews[$0][MachineCardFlex.self] }
            let free = width - flex.map(\.basis).reduce(0, +) - spacing * CGFloat(indices.count - 1)
            let grow = max(1, flex.map(\.grow).reduce(0, +))
            let widths = flex.map { max(0, indices.count == 1 ? width : $0.basis + free * $0.grow / grow) }
            let height = zip(indices, widths).map { subviews[$0.0].sizeThatFits(ProposedViewSize(width: $0.1, height: nil)).height }.max() ?? 0
            return Row(indices: indices, widths: widths, height: height)
        }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 1000
        let rows = rows(subviews, width: width)
        return CGSize(width: width, height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for (index, width) in zip(row.indices, row.widths) {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: row.height))
                x += width + spacing
            }
            y += row.height + spacing
        }
    }
}

// MARK: Machine card

struct MachineCardView: View {
    var card: MachineCardModel
    var attaching: Set<String>
    var actions: MachinesActions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: MachineSymbol.name(card)).font(.system(size: 17, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                    .frame(width: 22).accessibilityHidden(true)
                Text(card.name).font(.system(size: 18, weight: .semibold)).lineLimit(1)
                if let os = card.os { AppTag(text: os).fixedSize() }
                else if card.probing { AppTag(text: "Checking…").fixedSize() }
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
                if let bytes = card.cacheBytes, bytes > 0 {
                    if !card.harnesses.isEmpty { MachineRule() }
                    MachineKeyValue(key: "Cache") {
                        Text(MachineFormat.size(bytes)).font(.system(size: 12, design: .monospaced))
                        Text("chats, transcripts and media copied here").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                        Spacer(minLength: 6)
                        MachineButton(title: "Clear", style: .ghost, small: true) { actions.clearCache(card) }
                            .help("Removes what Burro copied from \(card.name): last-seen chats, transcript copies, images and videos")
                    }
                }
            }
            Spacer(minLength: 0)
            FlowLayout(spacing: 8) {
                if card.reach == .paused {
                    MachineButton(title: "Resume checks", symbol: "play") { actions.resume(card) }
                        .help("Start checking \(card.name) again")
                } else {
                    MachineButton(title: "New chat here", symbol: "plus", style: card.isLocal ? .primary : .normal) { actions.newChat(card) }
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
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(AppCardSurface())
        .accessibilityElement(children: .contain).accessibilityLabel(card.name)
    }

    /// Status, counts and the address on one line when they fit; the address moves under them when not.
    private var statusRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                statusText.fixedSize()
                Spacer(minLength: 12)
                destinationText
            }
            VStack(alignment: .leading, spacing: 3) {
                statusText.fixedSize(horizontal: false, vertical: true)
                destinationText.padding(.leading, 16)
            }
        }
    }
    private var statusText: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8).accessibilityHidden(true)
            (Text(card.isLocal ? "Online" : card.statusLine).foregroundStyle(AppAppearance.text) + countsText).font(.system(size: 13))
        }
    }
    @ViewBuilder private var destinationText: some View {
        if let destination = card.host?.destination {
            Text(destination).font(.system(size: 12, design: .monospaced)).foregroundStyle(AppAppearance.tertiary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(destination)
        }
    }
    private var countsText: Text {
        var text = Text("")
        if card.counts.working > 0 {
            text = text + Text("  ·  ").foregroundStyle(AppAppearance.tertiary) + Text("\(card.counts.working) working").foregroundStyle(AppAppearance.green)
        }
        if card.counts.needYou > 0 {
            text = text + Text("  ·  ").foregroundStyle(AppAppearance.tertiary)
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
                HStack(spacing: 10) {
                    Circle().fill(session.state == .waiting ? AppAppearance.amber : AppAppearance.green).frame(width: 8, height: 8)
                    Text(session.title.isEmpty ? "Untitled chat" : session.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .frame(width: 170, alignment: .leading)
                    Text(MachinesOverview.detail(session)).font(.system(size: 13)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AppTag(text: AquariumFish.modelName(session.model) ?? (session.provider == .codex ? "Codex" : "Claude Code")).fixedSize()
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
                Text(card.name).font(.system(size: 18, weight: .semibold)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
                if let os = card.os { AppTag(text: os).fixedSize() }
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
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppAppearance.background.opacity(0.6), in: RoundedRectangle(cornerRadius: AppAppearance.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AppAppearance.cardRadius, style: .continuous)
            .strokeBorder(AppAppearance.hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .accessibilityElement(children: .contain).accessibilityLabel("\(card.name), unreachable")
    }
}

// MARK: Add a machine, tailnet devices

struct AddMachineRow: View {
    var add: (String) -> Void
    @State private var destination = ""
    private var trimmed: String { destination.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        FlowLayout(spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "plus").font(.system(size: 13, weight: .bold)).foregroundStyle(AppAppearance.secondary)
                    .frame(width: 30, height: 30).background(AppAppearance.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a machine").font(.system(size: 13, weight: .semibold))
                    Text("Needs an SSH login from this Mac with a key, Python 3, and Claude Code or Codex there. Burro installs nothing.")
                        .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: 520, alignment: .leading)
            }
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("ssh").foregroundStyle(AppAppearance.tertiary)
                    TextField("", text: $destination, prompt: Text("user@host or Tailscale name").foregroundStyle(AppAppearance.tertiary))
                        .textFieldStyle(.plain).onSubmit(submit)
                        .accessibilityLabel("SSH address")
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 7).frame(width: 280)
                .background(AppAppearance.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(AppAppearance.separator))
                MachineButton(title: "Connect…", action: submit).disabled(trimmed.isEmpty)
                    .help("Opens the machine editor with this address, where you confirm the name and port")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: AppAppearance.cardRadius, style: .continuous)
            .strokeBorder(AppAppearance.hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
    private func submit() {
        add(trimmed)
        destination = ""
    }
}

struct TailnetDevices: View {
    var peers: [TailscalePeer]
    var add: (TailscalePeer) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MachinesSectionLabel(text: "Also on your tailnet")
            VStack(spacing: 0) {
                ForEach(Array(peers.enumerated()), id: \.element.id) { index, peer in
                    if index > 0 { MachineRule() }
                    HStack(spacing: 10) {
                        Circle().fill(peer.online ? AppAppearance.green : AppAppearance.tertiary).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(peer.hostName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text([peer.os.isEmpty ? nil : peer.os, peer.online ? "Online" : peer.lastSeen.map { "Seen \(RemoteStatusLine.ago($0, now: Date()))" } ?? "Offline"]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                        Spacer(minLength: 8)
                        MachineButton(title: "Add over SSH", style: .ghost, small: true) { add(peer) }
                            .help("Monitor this device's Codex and Claude chats over SSH (needs an SSH login from this Mac)")
                    }.padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 4)
            .modifier(AppCardSurface())
        }
    }
}

// MARK: Small pieces

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
