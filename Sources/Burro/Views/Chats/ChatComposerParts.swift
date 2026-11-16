// Pieces of the reply composer: the reason line shown above the field when a reply can be typed
// but not sent plainly (with its one action, whose title the unavailable bar shares), the queued-message chip with Edit and Cancel, the queue's last notice, and the
// attachment chips. Layout and wording only; decisions come from `ComposerPlan` in BurroCore.
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BurroCore

/// "Why not" plus the single right action.
struct ComposerReasonLine: View {
    var reason: String
    var action: ComposerPlan.Action?
    var agent: String
    var machine: String?
    var perform: (ComposerPlan.Action) -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(reason, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if let action {
                Button(Self.title(action, agent: agent, machine: machine)) { perform(action) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppAppearance.blue).fixedSize()
            }
        }
    }
    static func title(_ action: ComposerPlan.Action, agent: String, machine: String?) -> String {
        switch action {
        case .openInProvider: "Open in \(agent)"
        case .attachInTerminal: "Attach in Terminal"
        case .attachOnMachine: "Attach on \(machine ?? "that machine")"
        case .queue: "Queue for when it's done"
        }
    }
}

/// The message waiting for the chat to finish, with Edit and Cancel until it goes.
struct QueuedReplyChip: View {
    var item: QueuedReply
    var sending: Bool
    var edit: () -> Void
    var cancel: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: sending ? "arrow.up.circle" : "clock").font(.system(size: 11, weight: .semibold)).foregroundStyle(AppAppearance.secondary)
            Text(sending ? "Sending queued message…" : "Queued for when it's done:").font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
            Text(item.text).font(.system(size: 12)).foregroundStyle(AppAppearance.text).lineLimit(1).truncationMode(.tail)
            if !item.attachments.isEmpty {
                Text("+\(item.attachments.count) file\(item.attachments.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
            }
            Spacer(minLength: 6)
            if !sending {
                Button("Edit", action: edit).buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppAppearance.blue)
                Button("Cancel", action: cancel).buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppAppearance.secondary)
            }
        }
        .padding(.horizontal, 12).frame(height: 30)
        .background(AppAppearance.surface, in: Capsule()).overlay(Capsule().strokeBorder(AppAppearance.separator))
    }
}

/// What happened to the last queued message.
struct QueueNoticeLine: View {
    var notice: ReplyQueueNotice
    var edit: () -> Void
    var dismiss: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Label(notice.message, systemImage: notice.sent ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(notice.sent ? AppAppearance.green : AppAppearance.amber).lineLimit(2)
            Spacer(minLength: 6)
            if !notice.sent {
                Button("Edit", action: edit).buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppAppearance.blue)
            }
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(AppAppearance.tertiary).help("Dismiss").accessibilityLabel("Dismiss")
        }
    }
}

/// Files waiting to go with the message.
struct AttachmentChips: View {
    var paths: [String]
    var remove: (String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(paths, id: \.self) { path in
                    HStack(spacing: 5) {
                        Image(systemName: ChatAttachments.isImage(path) ? "photo" : "doc").font(.system(size: 10.5))
                        Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                        Button { remove(path) } label: { Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)) }
                            .buttonStyle(.plain).accessibilityLabel("Remove \(URL(fileURLWithPath: path).lastPathComponent)")
                    }
                    .foregroundStyle(AppAppearance.secondary)
                    .padding(.horizontal, 8).frame(height: 24).frame(maxWidth: 220)
                    .background(AppAppearance.raised.opacity(0.6), in: Capsule())
                    .help(path)
                }
            }
        }
    }
}

/// Choosing, pasting and dropping files for the composer (chats on this Mac).
enum ComposerFiles {
    @MainActor static func choose() -> [String] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.prompt = "Attach"
        return panel.runModal() == .OK ? panel.urls.map(\.path) : []
    }
    /// File URLs on the pasteboard, else image data written owner-only into Burro's paste folder.
    @MainActor static func paste() throws -> [String] {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map(\.path)
        }
        if let png = board.data(forType: .png) { return [try ChatAttachments.savePasted(png, extension: "png", folder: ChatAttachments.pasteFolder)] }
        if let tiff = board.data(forType: .tiff), let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return [try ChatAttachments.savePasted(png, extension: "png", folder: ChatAttachments.pasteFolder)]
        }
        throw LaunchError.failed("There's no file or image to paste.")
    }
    /// Paths from dropped file URLs.
    static func dropped(_ providers: [NSItemProvider], completion: @escaping @MainActor ([String]) -> Void) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        let collected = PathCollector()
        let group = DispatchGroup()
        for provider in files {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { collected.add(url.path) }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { completion(collected.paths) } }
        return true
    }
    private final class PathCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ path: String) { lock.lock(); values.append(path); lock.unlock() }
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
}
