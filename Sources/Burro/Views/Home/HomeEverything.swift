// Home's cover (greeting, live chips and the plain-language summary), the flat project and machine
// cards whose only colour is their live counts, and the notes and scratchpad cards.
import AppKit
import ImageIO
import SwiftUI
import BurroCore

// MARK: Cover

/// Home's backdrop, fixed behind the page while it scrolls. The aquarium fills the whole page; the
/// glyph and pixel fields and a photo sit across the top and fade into it. Part of the page, not a card.
struct CoverBackdrop: View {
    var running: Int
    var waiting: Int
    var fish: [AquariumFish]
    var hover: AquariumHover
    /// Home is on screen; the field only animates then.
    var animate: Bool
    @AppStorage("home.cover") private var coverPath = ""
    @AppStorage("home.coverStyle") private var styleRaw = CoverField.Style.aquarium.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: NSImage?

    private var style: CoverField.Style { CoverField.Style(rawValue: styleRaw) ?? .aquarium }

    var body: some View {
        Group {
            if style == .aquarium {
                CoverField(style: .aquarium, running: running, waiting: waiting, fish: fish, hover: hover, animate: animate && !reduceMotion)
            } else {
                Group {
                    if style != .photo {
                        CoverField(style: style, running: running, waiting: waiting, animate: animate && !reduceMotion)
                    } else if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 380).clipped()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.42),
                                             .init(color: .black.opacity(0.45), location: 0.68), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .allowsHitTesting(false)
        .task(id: coverPath + styleRaw) { image = style == .photo ? await CoverImage.load(path: coverPath) : nil }
    }
}

/// The cover's content: the butter, a greeting, live chips and the summary sentence, sitting on the
/// backdrop. "Need you" (amber) and "to read" (neutral) chips show only when there is something.
struct HomeCover: View {
    var store: AppStore
    var summary: HomeSummary
    @AppStorage("home.cover") private var coverPath = ""
    @AppStorage("home.coverStyle") private var styleRaw = CoverField.Style.aquarium.rawValue

    private var style: CoverField.Style { CoverField.Style(rawValue: styleRaw) ?? .aquarium }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear.frame(maxWidth: .infinity).frame(height: 230)
            HStack(alignment: .bottom, spacing: 16) {
                BurroMark(active: true, working: summary.counts.running > 0, tint: HomeStyle.butter)
                    .frame(width: 64, height: 64)
                    .shadow(color: HomeStyle.butter.opacity(0.35), radius: 14)
                VStack(alignment: .leading, spacing: 12) {
                    Text(greeting).font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(AppAppearance.text)
                        .shadow(color: AppAppearance.background.opacity(0.9), radius: 12)
                    HStack(spacing: 8) {
                        CoverChip(symbol: "waveform.path", text: "\(summary.counts.running)", help: "Agents running: open Chats") { store.page = .remote }
                        if summary.counts.waiting > 0 {
                            CoverChip(symbol: "hand.raised", text: "\(summary.counts.waiting) need\(summary.counts.waiting == 1 ? "s" : "") you",
                                      color: AppAppearance.amber, help: "Chats that need you: open Chats") { store.page = .remote }
                        }
                        if summary.counts.done > 0 {
                            CoverChip(symbol: "tray", text: "\(summary.counts.done) to read", help: "Results ready to read: open Chats") { store.page = .remote }
                        }
                        CoverChip(symbol: "server.rack", text: "\(summary.machines.count) machine\(summary.machines.count == 1 ? "" : "s")", help: "Machines") { store.page = .machines }
                        if let line = usageLine { CoverChip(symbol: "gauge.with.dots.needle.33percent", text: line, help: "Usage") { store.page = .usage } }
                        if let activity = store.projectActivity, activity.tokens > 0 {
                            CoverChip(symbol: "chart.bar", text: HomeFormat.tokens(activity.tokens) + " today", help: "Tokens today on this Mac") { store.page = .usage }
                        }
                    }
                    summaryLine
                }
            }
            .padding(.bottom, 6)
        }
        .overlay(alignment: .topTrailing) {
            Menu {
                Picker("Cover", selection: $styleRaw) {
                    Label("Aquarium", systemImage: "fish").tag(CoverField.Style.aquarium.rawValue)
                    Label("Glyphs", systemImage: "character.textbox").tag(CoverField.Style.glyphs.rawValue)
                    Label("Pixels", systemImage: "square.grid.3x3.fill").tag(CoverField.Style.pixels.rawValue)
                    Label("Photo", systemImage: "photo").tag(CoverField.Style.photo.rawValue)
                }
                .pickerStyle(.inline)
                Divider()
                Button("Choose Image…") { choose() }
                Button("Use Desktop Picture") { coverPath = ""; styleRaw = CoverField.Style.photo.rawValue }
                    .disabled(coverPath.isEmpty && style == .photo)
            } label: {
                Image(systemName: "photo.on.rectangle").font(.system(size: 13, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                    .frame(width: 32, height: 32).background(.thinMaterial, in: Circle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.top, 4).help("Change the cover")
        }
    }
    /// The plain-language summary, with when the agents were last checked and a way to check now.
    private var summaryLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.didCheckAgents ? summary.sentence : "Checking on your agents…")
                .font(.system(size: 15)).lineSpacing(3).foregroundStyle(AppAppearance.secondary)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 680, alignment: .leading)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Image(systemName: "clock")
                Text(store.agentActivity.sampledAt == .distantPast ? "Waiting for the first check" : "Updated \(HomeFormat.ago(store.agentActivity.sampledAt))")
                Button { Task { await store.refreshAgents() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Check agents now").accessibilityLabel("Check agents now")
            }.font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
        }
    }
    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"; case 12..<18: "Good afternoon"; case 18..<23: "Good evening"; default: "Working late"
        }
    }
    private var usageLine: String? {
        let rows = store.providerUsage.providers.compactMap { provider -> (String, Double)? in
            guard provider.issue == nil, let remaining = provider.windows.compactMap(\.remainingPercent).min() else { return nil }
            return (provider.title, remaining)
        }
        guard let tightest = rows.min(by: { $0.1 < $1.1 }) else { return nil }
        return "\(tightest.0) \(Int(tightest.1.rounded()))% left"
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.canChooseDirectories = false; panel.prompt = "Use Image"
        if panel.runModal() == .OK, let url = panel.url { coverPath = url.path; styleRaw = CoverField.Style.photo.rawValue }
    }
}

private struct CoverChip: View {
    var symbol: String
    var text: String
    var color: Color = AppAppearance.text
    var help: String
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(text).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
            .foregroundStyle(color).padding(.horizontal, 12).padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .background(AppAppearance.text.opacity(hovering ? 0.1 : 0), in: Capsule())
            .overlay(Capsule().strokeBorder(AppAppearance.separator))
        }.buttonStyle(.plain).onHover { hovering = $0 }.help(help)
    }
}

enum CoverImage {
    /// Loads and downsamples off the main thread so a 6K wallpaper doesn't stall scrolling.
    @MainActor static func load(path: String) async -> NSImage? {
        let url: URL? = path.isEmpty ? NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) } : URL(fileURLWithPath: path)
        guard let url else { return nil }
        let cgImage = await Task.detached(priority: .utility) { () -> CGImage? in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2600,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        return cgImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }
}

// MARK: Bench cards

/// A project or machine as a flat card: a quiet tile, the name, and live counts or "Quiet". Colour
/// comes only from the count pills.
struct BenchCard: View {
    var title: String
    var symbol: String?
    /// Greys the tile, for a machine that isn't reachable.
    var dimmed = false
    var counts: HomeCounts
    var quiet: String
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HomeStyle.cardRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: 16) {
                FlatTile(initial: symbol == nil ? String(title.prefix(1)).uppercased() : nil, symbol: symbol, size: 46, dimmed: dimmed)
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1).foregroundStyle(AppAppearance.text)
                    if counts.isQuiet {
                        Text(quiet).font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary).lineLimit(1)
                    } else {
                        HStack(spacing: 6) {
                            if counts.running > 0 { CountPill(symbol: "waveform.path", count: counts.running, color: AppAppearance.green) }
                            if counts.waiting > 0 { CountPill(symbol: "hand.raised", count: counts.waiting, color: AppAppearance.amber) }
                            if counts.done > 0 { CountPill(symbol: "tray", count: counts.done, color: AppAppearance.blue) }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppAppearance.surface, in: shape)
            .background(hovering ? AppAppearance.hover : .clear, in: shape)
            .overlay(shape.strokeBorder(hovering ? AppAppearance.hairline : AppAppearance.separator))
            .contentShape(shape)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(PressableStyle()).onHover { hovering = $0 }.help(help)
    }
}

/// A flat, monochrome tile: an initial or glyph in secondary grey on the raised fill.
struct FlatTile: View {
    var initial: String?
    var symbol: String?
    var size: CGFloat
    var dimmed = false
    var body: some View {
        Group {
            if let symbol { Image(systemName: symbol).font(.system(size: size * 0.4, weight: .medium)) }
            else { Text(initial ?? "?").font(.system(size: size * 0.42, weight: .semibold, design: .rounded)) }
        }
        .foregroundStyle(dimmed ? AppAppearance.tertiary : AppAppearance.secondary)
        .frame(width: size, height: size)
        .background(AppAppearance.raised, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

/// A bench's chosen colour as a tile, used by the bench editor to preview the pick.
struct GradientTile: View {
    var initial: String?
    var symbol: String?
    var tint: Color
    var size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.78), tint], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center))
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: size * 0.4, weight: .medium)) }
                else { Text(initial ?? "?").font(.system(size: size * 0.42, weight: .semibold, design: .rounded)) }
            }.foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .background {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(tint).shadow(color: tint.opacity(0.35), radius: 8, y: 4)
        }
        .accessibilityHidden(true)
    }
}

private struct CountPill: View {
    var symbol: String
    var count: Int
    var color: Color
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            Text("\(count)").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(AppAppearance.secondary)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(AppAppearance.raised, in: Capsule())
        .fixedSize()
    }
}

// MARK: Notes and scratchpad

/// Notes and Scratchpad share a plain card with the quiet section-header treatment.
private struct NoteCardShell<Content: View>: View {
    var title: String
    var symbol: String
    var count: Int?
    var add: (() -> Void)?
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            HomeSectionHeader(title: title) {
                HStack(spacing: 10) {
                    if let count, count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(AppAppearance.tertiary) }
                    if let add {
                        Button(action: add) { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 18, height: 18).contentShape(Rectangle()) }
                            .help("New note").accessibilityLabel("New note")
                    }
                }
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(AppCardSurface(radius: HomeStyle.cardRadius))
    }
}

/// Notes open in the floating Notes window (⌥P from anywhere).
struct HomeNotesCard: View {
    var notes: NotesStore
    var open: (NotesTarget) -> Void
    var body: some View {
        NoteCardShell(title: "Notes", symbol: "square.and.pencil", count: notes.sorted.count, add: { open(.new) }) {
            VStack(alignment: .leading, spacing: 0) {
                if notes.sorted.isEmpty {
                    Text("Keep the context agents and future you will need. ⌥P opens Notes from any app.")
                        .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                        .padding(16)
                } else {
                    ForEach(Array(notes.sorted.prefix(4).enumerated()), id: \.element.id) { index, note in
                        if index > 0 { Divider().overlay(AppAppearance.separator) }
                        Button { open(.note(note.id)) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: note.isPinned ? "pin.fill" : "doc.text").font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary).padding(.top, 1)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    if !note.body.isEmpty {
                                        Text(NoteText.plain(note.body).split(whereSeparator: \.isNewline).joined(separator: " "))
                                            .font(.system(size: 12)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 4)
                                Text(HomeFormat.ago(note.updatedAt)).font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
                            }.padding(.horizontal, 16).padding(.vertical, 11).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct HomeScratchpadCard: View {
    @Bindable var notes: NotesStore
    var body: some View {
        NoteCardShell(title: "Scratchpad", symbol: "doc", count: nil, add: nil) {
            ZStack(alignment: .topLeading) {
                // Grows with the text (about 42 characters a line at this width), then scrolls.
                TextEditor(text: $notes.scratchpad).font(.system(size: 13)).scrollContentBackground(.hidden)
                    .padding(.horizontal, 11).padding(.vertical, 10).frame(height: height)
                if notes.scratchpad.isEmpty {
                    Text("Scratch pad. Anything that doesn't deserve a to-do yet.").font(.system(size: 13))
                        .foregroundStyle(AppAppearance.tertiary).padding(.horizontal, 16).padding(.vertical, 10).allowsHitTesting(false)
                }
            }
        }
    }
    private var height: CGFloat {
        let lines = notes.scratchpad.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, ($1.count + 41) / 42) }
        return min(320, max(120, CGFloat(lines) * 18 + 28))
    }
}
