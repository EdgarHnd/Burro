// Images and videos agents put in their replies (`![caption](/absolute/path.png)`). Files on this
// Mac are read in place; files on another machine are copied once over SSH by a fixed read-only
// script into Burro's private cache. Only image and video files, within a size limit.
import CryptoKit
import Foundation

public enum ChatMedia {
    public enum Kind: Sendable, Equatable { case image, video }
    static let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]
    static let videos: Set<String> = ["mp4", "mov", "m4v", "webm"]
    public static let maxImage = 40 * 1024 * 1024
    public static let maxVideo = 300 * 1024 * 1024

    /// The kind of media at `path`, judged by extension; nil for anything else.
    public static func kind(of path: String) -> Kind? {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if images.contains(ext) { return .image }
        if videos.contains(ext) { return .video }
        return nil
    }

    /// A readable media file on this Mac (after resolving links), or an error saying why not.
    public static func local(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else { throw LaunchError.failed("Not a file on this Mac.") }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let kind = kind(of: url.path) else { throw LaunchError.failed("Only images and videos are shown.") }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let size = values?.fileSize else { throw LaunchError.failed("This file isn't there any more.") }
        guard size <= (kind == .image ? maxImage : maxVideo) else { throw LaunchError.failed("This file is too large to show.") }
        return url
    }

    public static var cacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Burro/Media", isDirectory: true)
    }

    /// Copies a media file from another machine into the cache (once per app run) and returns it.
    public static func remote(_ path: String, host: RemoteHost) throws -> URL {
        guard path.hasPrefix("/"), let kind = kind(of: path) else { throw LaunchError.failed("Only images and videos are shown.") }
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = SHA256.hash(data: Data("\(host.id.uuidString)\n\(path)".utf8)).map { String(format: "%02x", $0) }.joined()
        let target = cacheFolder.appendingPathComponent(String(key.prefix(32))).appendingPathExtension(URL(fileURLWithPath: path).pathExtension.lowercased())
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let partial = target.appendingPathExtension("part")
        defer { try? FileManager.default.removeItem(at: partial) }
        let limit = kind == .image ? maxImage : maxVideo
        _ = try RemoteScript.run("remote_media", request: ["path": path, "max": limit], host: host,
                                 timeout: kind == .image ? 60 : 300, output: partial)
        let size = (try? partial.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0, size <= limit else { throw LaunchError.failed("\(host.name) sent an empty or oversized file.") }
        try FileManager.default.moveItem(at: partial, to: target)
        return target
    }

    /// Clears copies from earlier runs; remote files may have changed since.
    public static func clearCache() {
        try? FileManager.default.removeItem(at: cacheFolder)
    }
}
