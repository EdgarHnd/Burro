// Home's cover, bench cards, notes and scratchpad.
import AppKit
import ImageIO
import SwiftUI
import BurroCore

// MARK: Cover

/// The cover photo: an image you pick, otherwise your current desktop picture (read at runtime,
/// nothing bundled), otherwise a soft gradient.
struct HomeCover: View {
    var store: AppStore
    var summary: HomeSummary
    @AppStorage("home.cover") private var coverPath = ""
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                else {
                    LinearGradient(colors: [AppAppearance.blue.opacity(0.55), HomeStyle.butter.opacity(0.6), AppAppearance.green.opacity(0.35)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 250).clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.08), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 18) {
                BurroMark(active: true, working: summary.counts.running > 0, tint: HomeStyle.butter)
                    .frame(width: 44, height: 44).frame(width: 82, height: 82)
                    .background {
                        RoundedRectangle(cornerRadius: 22, style: .continuous).fill(HomeStyle.charcoal.opacity(0.92))
                            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.18)))
                VStack(alignment: .leading, spacing: 12) {
                    Text(greeting).font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                    HStack(spacing: 8) {
                        CoverChip(symbol: "waveform.path", text: "\(summary.counts.running)", help: "Agents running") {
                            store.filter = .working; store.page = .worktrees
                        }
                        CoverChip(symbol: "tray", text: "\(summary.counts.waiting + summary.counts.done)", help: "Need you or ready to read") { store.page = .today }
                        CoverChip(symbol: "server.rack", text: "\(summary.machines.count) machine\(summary.machines.count == 1 ? "" : "s")", help: "Machines") { store.page = .machines }
                        if let line = usageLine { CoverChip(symbol: "gauge.with.dots.needle.33percent", text: line, help: "Usage") { store.page = .usage } }
                        if let activity = store.projectActivity, activity.tokens > 0 {
                            CoverChip(symbol: "chart.bar", text: HomeFormat.tokens(activity.tokens) + " today", help: "Tokens today on this Mac") { store.page = .usage }
                        }
                    }
                }
            }.padding(28)
        }
        .overlay(alignment: .topTrailing) {
            Menu {
                Button("Choose Image…") { choose() }
                Button("Use Desktop Picture") { coverPath = "" }.disabled(coverPath.isEmpty)
            } label: {
                Image(systemName: "photo").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(.black.opacity(0.25), in: Circle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(18).help("Change the cover image")
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .background { RoundedRectangle(cornerRadius: 26, style: .continuous).fill(AppAppearance.surface).shadow(color: AppAppearance.shadow, radius: 18, y: 6) }
        .task(id: coverPath) { image = await CoverImage.load(path: coverPath) }
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
        if panel.runModal() == .OK, let url = panel.url { coverPath = url.path }
    }
}

private struct CoverChip: View {
    var symbol: String
    var text: String
    var help: String
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(text).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
            .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6)
            .background(.white.opacity(hovering ? 0.32 : 0.2), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
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

/// A project or machine as a card: a glossy gradient tile, the name, and live counts or "Quiet".
struct BenchCard: View {
    var title: String
    var symbol: String?
    var tint: Color
    var counts: HomeCounts
    var quiet: String
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                GradientTile(initial: symbol == nil ? String(title.prefix(1)).uppercased() : nil, symbol: symbol, tint: tint, size: 58)
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
            .padding(.horizontal, 22).padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(AppAppearance.surface)
                    .shadow(color: AppAppearance.shadow, radius: hovering ? 18 : 12, y: hovering ? 7 : 4)
            }
            .background(alignment: .top) {
                // A second card peeking out behind, like a stack.
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(AppAppearance.surface.opacity(0.7))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(AppAppearance.separator))
                    .padding(.horizontal, 18).offset(y: -7).frame(height: 40)
            }
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(hovering ? AppAppearance.hairline : AppAppearance.separator))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(PressableStyle()).onHover { hovering = $0 }.help(help)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

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

enum NoteStyle {
    static let header = AppAppearance.adaptive(light: (0.98, 0.88, 0.45, 1), dark: (0.42, 0.35, 0.10, 1))
    static let headerText = AppAppearance.adaptive(light: (0.40, 0.30, 0.02, 1), dark: (0.98, 0.88, 0.55, 1))
    static let wash = AppAppearance.adaptive(light: (1, 0.98, 0.90, 1), dark: (0.20, 0.19, 0.15, 1))
}

private struct NoteCardShell<Content: View>: View {
    var title: String
    var symbol: String
    var count: Int?
    var add: (() -> Void)?
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title.uppercased()).font(.system(size: 12, weight: .bold)).tracking(1)
                Spacer()
                if let count, count > 0 { Text("\(count)").font(.system(size: 12, weight: .semibold)).monospacedDigit().opacity(0.7) }
                if let add {
                    Button(action: add) { Image(systemName: "plus").font(.system(size: 12, weight: .bold)) }
                        .buttonStyle(.plain).help("New note").padding(.leading, 6)
                }
            }
            .foregroundStyle(NoteStyle.headerText).padding(.horizontal, 16).padding(.vertical, 11)
            .background(NoteStyle.header)
            content().frame(maxWidth: .infinity, alignment: .leading).background(NoteStyle.wash)
        }
        .clipShape(RoundedRectangle(cornerRadius: HomeStyle.cardRadius, style: .continuous))
        .modifier(SoftSurface(radius: HomeStyle.cardRadius))
    }
}

struct HomeNotesCard: View {
    var notes: NotesStore
    @State private var editing: HomeNote?
    var body: some View {
        NoteCardShell(title: "Notes", symbol: "square.and.pencil", count: notes.notes.count,
                      add: { editing = HomeNote(id: UUID(), title: "", body: "", updatedAt: Date()) }) {
            VStack(alignment: .leading, spacing: 0) {
                if notes.notes.isEmpty {
                    Text("Keep the context agents and future you will need.").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                        .padding(16)
                } else {
                    ForEach(Array(notes.sorted.prefix(4).enumerated()), id: \.element.id) { index, note in
                        if index > 0 { Divider().overlay(AppAppearance.separator) }
                        Button { editing = note } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary).padding(.top, 1)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    if !note.body.isEmpty {
                                        Text(note.body.split(whereSeparator: \.isNewline).joined(separator: " "))
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
        .sheet(item: $editing) { note in NoteEditor(note: note, notes: notes) }
    }
}

private struct NoteEditor: View {
    @State var note: HomeNote
    var notes: NotesStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Title", text: $note.title).textFieldStyle(.plain).font(.system(size: 20, weight: .semibold))
            TextEditor(text: $note.body).font(.system(size: 14)).scrollContentBackground(.hidden)
                .frame(minHeight: 260).padding(8)
                .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AppAppearance.separator))
            HStack {
                if notes.notes.contains(where: { $0.id == note.id }) {
                    Button("Delete", role: .destructive) { notes.remove(note); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { notes.save(note); dismiss() }.keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(22).frame(width: 520).modifier(AppTheme())
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
