// The Machines page in the dashboard layout (Today's). The shared page header with the
// `MachinesOverview` headline as its sentence ("2 need you" amber) and Check all now trailing; the
// store's message line; a strip of four numbers (`MachinesComposition`: Reachable, Working, Waiting
// on you, Tools out of date); then one joined surface: the machines as cells of equal height in
// rows of up to three (`MachineGridLayout`: at least 360 points a cell, a short last row shares the
// width), a machine that stopped answering as a quieter hatched cell; and a bottom row 1:1:1
// (stacked below 690 points, Today's breakpoint) with Add a machine, Also on your tailnet and Local
// copies (Burro's cache for each machine and its transcript copies, with Clear). The two footnotes
// stay under the surface. It only reads `MachinesPageModel`; every action is a closure that
// `MachinesView` wires to the existing store functions, so snapshot tests can draw it.
import SwiftUI
import BurroCore

struct MachinesPage: View {
    var model: MachinesPageModel
    var actions: MachinesActions
    nonisolated static var bottomStackBelow: CGFloat { 690 }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Machines", inset: 0, eyebrow: "Where your agents run", sentence: sentence, top: 0, bottom: 0) {
                HStack(spacing: 10) {
                    if model.checking { ProgressView().controlSize(.small).accessibilityLabel("Checking machines") }
                    PillButton(title: "Check all now", symbol: "arrow.clockwise", action: actions.checkAll)
                        .help("Check every machine's chats and tools now")
                }
            }
            if let message = model.message { messageLine(message) }
            StatStrip(cells: MachinesComposition.stats(composition).map { StatCellData($0) })
            JoinedPanels {
                MachineGridLayout {
                    ForEach(model.cards) { card in
                        if card.reach == .unreachable {
                            UnreachableMachineCard(card: card, actions: actions)
                        } else {
                            MachineCardView(card: card, attaching: model.attaching, actions: actions)
                        }
                    }
                    JoinedHairlines(count: model.cards.count * 2)
                }
                JoinedRow(weights: [1, 1, 1], stackBelow: Self.bottomStackBelow) {
                    AddMachinePanel(add: actions.add)
                    TailnetPanel(peers: model.tailnet, installed: model.tailscaleInstalled, add: actions.addTailnet)
                    LocalCopiesPanel(cards: model.cards.filter { $0.host != nil }, clear: actions.clearCache)
                }
            }
            Text("Versions are read on each machine with the tool's own --version; latest releases come from npm. Update runs the tool's own updater after you confirm.")
                .font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Each card as the strip and sentence count it.
    private var composition: [MachinesComposition.Machine] {
        model.cards.map { card in
            let reach: MachinesComposition.Machine.Reach
            switch card.reach {
            case .local, .online: reach = .reachable
            case .connecting, .stale: reach = .checking
            case .unreachable: reach = .unreachable
            case .paused: reach = .paused
            }
            return MachinesComposition.Machine(name: card.name, reach: reach, counts: card.counts,
                                               outdated: card.harnesses.filter(\.outdated).map(\.harness.title),
                                               versionsKnown: !card.harnesses.isEmpty, probing: card.probing)
        }
    }

    private var sentence: [TextRun] {
        let machines = composition
        let reach = MachinesComposition.reach(machines)
        let counts = MachinesOverview.Counts(working: machines.reduce(0) { $0 + $1.counts.working },
                                             needYou: machines.reduce(0) { $0 + $1.counts.needYou })
        return MachinesComposition.sentence(reachable: reach.reachable, total: reach.total, counts: counts)
    }

    private func messageLine(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(AppAppearance.tertiary)
            Text(message).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).textSelection(.enabled)
            Spacer(minLength: 8)
            Button(action: actions.dismissMessage) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(AppAppearance.tertiary)
                .accessibilityLabel("Dismiss message").help("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(AppAppearance.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: Grid

/// The machine cells: as many columns as fit at `minCell` points (at most three), every cell in a row
/// as tall as the tallest, a short last row sharing the full width, and hairlines from the joined
/// pool in the 1-point gaps. Columns follow the proposed width only, never a measured one.
struct MachineGridLayout: SwiftUI.Layout {
    var minCell: CGFloat = 360
    static let gap: CGFloat = 1

    nonisolated static func columns(count: Int, width: CGFloat, minCell: CGFloat = 360) -> Int {
        guard count > 0 else { return 1 }
        return max(1, min(count, 3, Int((width + gap) / (minCell + gap))))
    }

    private func frames(_ cells: [LayoutSubview], width: CGFloat) -> (cells: [CGRect], lines: [CGRect]) {
        let cols = Self.columns(count: cells.count, width: width, minCell: minCell)
        var frames: [CGRect] = [], lines: [CGRect] = [], y: CGFloat = 0
        for rowStart in stride(from: 0, to: cells.count, by: cols) {
            let row = rowStart..<min(cells.count, rowStart + cols)
            let cellWidth = (width - CGFloat(row.count - 1) * Self.gap) / CGFloat(row.count)
            let height = row.map { cells[$0].sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height }.max() ?? 0
            if rowStart > 0 { lines.append(CGRect(x: 0, y: y - Self.gap, width: width, height: Self.gap)) }
            for column in 0..<row.count {
                let x = CGFloat(column) * (cellWidth + Self.gap)
                frames.append(CGRect(x: x, y: y, width: cellWidth, height: height))
                if column > 0 { lines.append(CGRect(x: x - Self.gap, y: y, width: Self.gap, height: height)) }
            }
            y += height + Self.gap
        }
        return (frames, lines)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        return CGSize(width: width, height: frames(joinedParts(subviews).cells, width: width).cells.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let parts = joinedParts(subviews)
        let layout = frames(parts.cells, width: bounds.width)
        for (cell, frame) in zip(parts.cells, layout.cells) {
            cell.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
        placeHairlines(parts.lines, frames: layout.lines, in: bounds)
    }
}

// MARK: Bottom row

struct AddMachinePanel: View {
    var add: (String) -> Void
    @State private var destination = ""
    private var trimmed: String { destination.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Panel(title: "Add a machine",
              subtitle: [TextRun("Needs an SSH login from this Mac with a key, Python 3, and Claude Code or Codex there. Burro installs nothing.")]) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("ssh").foregroundStyle(AppAppearance.tertiary)
                    TextField("", text: $destination, prompt: Text("user@host or Tailscale name").foregroundStyle(AppAppearance.tertiary))
                        .textFieldStyle(.plain).onSubmit(submit)
                        .accessibilityLabel("SSH address")
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppAppearance.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(AppAppearance.separator))
                MachineButton(title: "Connect…", action: submit).disabled(trimmed.isEmpty)
                    .help("Opens the machine editor with this address, where you confirm the name and port")
            }
        }
    }
    private func submit() {
        guard !trimmed.isEmpty else { return }
        add(trimmed)
        destination = ""
    }
}

struct TailnetPanel: View {
    var peers: [TailscalePeer]
    var installed: Bool
    var add: (TailscalePeer) -> Void

    var body: some View {
        Panel(title: "Also on your tailnet", subtitle: [TextRun(subtitle)]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(peers.prefix(6).enumerated()), id: \.element.id) { index, peer in
                    if index > 0 { MachineRule() }
                    HStack(spacing: 10) {
                        Circle().fill(peer.online ? AppAppearance.green : AppAppearance.tertiary).frame(width: 7, height: 7).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(peer.hostName).font(.system(size: 13)).lineLimit(1)
                            Text([peer.os.isEmpty ? nil : peer.os, peer.online ? "Online" : peer.lastSeen.map { "Seen \(RemoteStatusLine.ago($0, now: Date()))" } ?? "Offline"]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        MachineButton(title: "Add over SSH", style: .ghost, small: true) { add(peer) }
                            .help("Monitor this device's Codex and Claude chats over SSH (needs an SSH login from this Mac)")
                    }.padding(.vertical, 7)
                }
                if peers.count > 6 {
                    MachineRule()
                    Text("and \(peers.count - 6) more").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).padding(.vertical, 7)
                }
            }
        }
    }

    private var subtitle: String {
        if !installed { return "Install Tailscale to see every device on your tailnet here." }
        if peers.isEmpty { return "Every device on your tailnet is already set up here." }
        return "\(peers.count) device\(peers.count == 1 ? "" : "s") not set up in Burro yet."
    }
}

/// What Burro copied from each other machine: its cache with Clear, and how many chats its
/// transcript copies let you read while it is away.
struct LocalCopiesPanel: View {
    var cards: [MachineCardModel]
    var clear: (MachineCardModel) -> Void

    var body: some View {
        Panel(title: "Local copies", subtitle: [TextRun(cards.isEmpty ? "Only this Mac: nothing is copied from elsewhere."
                                                         : "Chats, transcripts and media copied to this Mac from other machines.")]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    if index > 0 { MachineRule() }
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(card.name).font(.system(size: 13)).lineLimit(1)
                                if let bytes = card.cacheBytes, bytes > 0 {
                                    Text(MachineFormat.size(bytes)).font(.system(size: 12, design: .monospaced)).foregroundStyle(AppAppearance.secondary)
                                }
                            }
                            Text((card.localCopy ?? MachinesOverview.LocalCopy(chats: 0, lastSynced: nil)).text)
                                .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if let bytes = card.cacheBytes, bytes > 0 {
                            MachineButton(title: "Clear…", style: .ghost, small: true) { clear(card) }
                                .help("Removes what Burro copied from \(card.name): last-seen chats, transcript copies, images and videos (asks first)")
                        }
                    }.padding(.vertical, 7)
                }
            }
        }
    }
}
