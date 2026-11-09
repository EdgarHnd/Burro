// An image or video from a chat reply, shown inline like the Codex and Claude apps do. Local
// files load in place; remote images copy over SSH automatically and remote videos on request.
import AVKit
import ImageIO
import SwiftUI
import BurroCore

/// AppKit's player (the one QuickTime uses). SwiftUI's VideoPlayer bridge fails to load in
/// release builds of a SwiftPM app, so Burro hosts AVPlayerView directly.
private struct PlayerView: NSViewRepresentable {
    var player: AVPlayer?
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Where a transcript's files live. Unset means: don't load media (show its name only).
enum ChatMediaSource: Equatable { case local, remote(RemoteHost) }

private struct ChatMediaSourceKey: EnvironmentKey { static let defaultValue: ChatMediaSource? = nil }
extension EnvironmentValues {
    var chatMediaSource: ChatMediaSource? {
        get { self[ChatMediaSourceKey.self] }
        set { self[ChatMediaSourceKey.self] = newValue }
    }
}

struct ChatMediaView: View {
    var caption: String
    var path: String
    @Environment(\.chatMediaSource) private var source
    @State private var state: Load = .idle
    @State private var player: AVPlayer?
    @State private var aspect: CGFloat = 16 / 9

    enum Load: Equatable { case idle, loading, image(NSImage, URL), video(URL), failed(String) }

    private var kind: ChatMedia.Kind? { ChatMedia.kind(of: path) }
    private var name: String { URL(fileURLWithPath: path).lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
            if !caption.isEmpty {
                Text(caption).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(2)
            }
        }
        .task(id: path) {
            guard state == .idle, let source else { return }
            // Remote videos can be large: wait for a click. Everything else loads now.
            if kind == .video, case .remote = source { return }
            await load(source)
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .image(let image, let url):
            Image(nsImage: image).resizable().scaledToFit()
                .frame(maxWidth: min(image.size.width, 760), maxHeight: 480, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppAppearance.separator))
                .onTapGesture { NSWorkspace.shared.open(url) }
                .help("Open \(name)")
        case .video:
            PlayerView(player: player)
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxWidth: 760, maxHeight: 480, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppAppearance.separator))
        case .loading:
            placeholder(symbol: nil, text: "Loading \(name)…")
        case .failed(let reason):
            placeholder(symbol: "exclamationmark.triangle", text: "\(name): \(reason)")
        case .idle:
            if let source, kind == .video, case .remote(let host) = source {
                Button { Task { await load(source) } } label: {
                    placeholder(symbol: "play.circle.fill", text: "Play \(name) from \(host.name)")
                }.buttonStyle(.plain)
            } else {
                placeholder(symbol: kind == .video ? "film" : "photo", text: name)
            }
        }
    }

    private func placeholder(symbol: String?, text: String) -> some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: symbol == "play.circle.fill" ? 26 : 16)).foregroundStyle(AppAppearance.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).font(.system(size: 12.5)).foregroundStyle(AppAppearance.secondary).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).frame(maxWidth: 520, minHeight: 64, alignment: .leading)
        .background(AppAppearance.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    private func load(_ source: ChatMediaSource) async {
        state = .loading
        let path = path, kind = kind
        let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
            Result {
                switch source {
                case .local: try ChatMedia.local(path)
                case .remote(let host): try ChatMedia.remote(path, host: host)
                }
            }
        }.value
        switch result {
        case .failure(let error):
            state = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't load it.")
        case .success(let url):
            if kind == .video {
                if let size = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first?.load(.naturalSize), size.height > 0 {
                    aspect = size.width / size.height
                }
                player = AVPlayer(url: url)
                state = .video(url)
            } else if let image = await Task.detached(priority: .userInitiated, operation: { Self.thumbnail(url) }).value {
                state = .image(image, url)
            } else {
                state = .failed("Couldn't read this image.")
            }
        }
    }

    /// A display-sized copy (big screenshots would otherwise be decoded at full size).
    nonisolated static func thumbnail(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1800] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }
}
