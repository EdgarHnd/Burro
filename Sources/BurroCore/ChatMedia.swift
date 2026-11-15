// Images and videos agents put in their replies (`![caption](/absolute/path.png)`). Files on this
// Mac are read in place. Files on another machine are copied over SSH by a fixed read-only script
// into that machine's folder in Burro's remote cache, with an index of each copy's remote size and
// modification time: shown again, a copy is re-checked against the remote file and fetched again
// only if it changed; with the machine unreachable, the last copy is shown. Images up to about 8 MB
// load on their own, larger ones and videos on a click. Copies are kept up to 1 GB in total and 30
// days since last opened. Only image and video files, within a size limit. A fetched copy is moved
// into place and recorded in the index in one step under the cache's lock.
import CryptoKit
import Foundation

public enum ChatMedia {
    public enum Kind: Sendable, Equatable { case image, video }
    static let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]
    static let videos: Set<String> = ["mp4", "mov", "m4v", "webm"]
    public static let maxImage = 40 * 1024 * 1024
    public static let maxVideo = 300 * 1024 * 1024
    /// Remote images larger than this wait for a click.
    public static let automaticImageLimit = 8 * 1024 * 1024

    /// A remote file that is fine to show but too large to fetch without asking.
    public struct NeedsClick: Error, Equatable, LocalizedError {
        public var size: Int
        public var errorDescription: String? { "Large file (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))." }
    }

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

    /// The index key for a remote file: a hash of the machine and the path.
    static func key(host: RemoteHost, path: String) -> String {
        String(SHA256.hash(data: Data("\(host.id.uuidString)\n\(path)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    /// What the remote file looks like now.
    struct RemoteStat: Equatable { var size: Int64; var mtime: Double }

    /// What to do with a remote file given the cached copy and the remote stat (nil when unreachable).
    enum Plan: Equatable { case useCached, fetch, needsClick(Int), unavailable }
    static func plan(cached: RemoteCacheEntry?, remote: RemoteStat?, kind: Kind, automatic: Bool) -> Plan {
        guard let remote else { return cached == nil ? .unavailable : .useCached }
        if let cached, cached.size == remote.size, cached.remoteMTime == remote.mtime { return .useCached }
        if automatic && (kind == .video || remote.size > Int64(automaticImageLimit)) { return .needsClick(Int(remote.size)) }
        return .fetch
    }

    /// The local copy of a media file on another machine, fetching it when missing or changed.
    /// `automatic` (shown without a click) refuses videos and images over `automaticImageLimit`
    /// with `NeedsClick`, unless a current copy is already cached.
    public static func remote(_ path: String, host: RemoteHost, automatic: Bool = false, cache: RemoteCache = .shared) throws -> URL {
        guard path.hasPrefix("/"), let kind = kind(of: path) else { throw LaunchError.failed("Only images and videos are shown.") }
        let limit = kind == .image ? maxImage : maxVideo
        let key = key(host: host, path: path)
        let cached = cache.entry(.media, hostID: host.id, key: key)
        var reachError: Error?
        var current: RemoteStat?
        do {
            let data = try RemoteScript.run("remote_media", request: ["path": path, "max": limit, "op": "stat"], host: host, timeout: 30)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let size = (object["size"] as? NSNumber)?.int64Value, let mtime = (object["mtime"] as? NSNumber)?.doubleValue else {
                throw LaunchError.failed("\(host.name) didn't answer as expected.")
            }
            current = RemoteStat(size: size, mtime: mtime)
        } catch { reachError = error }
        switch plan(cached: cached?.entry, remote: current, kind: kind, automatic: automatic) {
        case .useCached:
            cache.touch(.media, hostID: host.id, key: key)
            return cached!.url
        case .unavailable:
            throw reachError ?? LaunchError.failed("This file isn't there any more.")
        case .needsClick(let size):
            throw NeedsClick(size: size)
        case .fetch:
            break
        }
        let folder = try cache.directory(.media, hostID: host.id)
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let file = key + "." + ext
        let target = folder.appendingPathComponent(file)
        let partial = folder.appendingPathComponent(file + "-\(UUID().uuidString.prefix(8).lowercased()).part")
        defer { try? FileManager.default.removeItem(at: partial) }
        _ = try RemoteScript.run("remote_media", request: ["path": path, "max": limit], host: host,
                                 timeout: kind == .image ? 60 : 300, output: partial)
        let size = (try? partial.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0, size <= limit else { throw LaunchError.failed("\(host.name) sent an empty or oversized file.") }
        let now = Date()
        // Moved into place and recorded under the cache lock, so a sweep never finds the copy
        // without its entry (and deletes it).
        // A copy whose index entry couldn't be saved is still shown this time.
        do {
            try cache.writing(.media, hostID: host.id) { _ in
                guard rename(partial.path, target.path) == 0 else { throw LaunchError.failed("Couldn't keep a copy of this file.") }
                return RemoteCacheEntry(key: key, file: file, remotePath: path, size: Int64(size),
                                        remoteMTime: current?.mtime ?? 0, fetchedAt: now, openedAt: now)
            }
        } catch let error as LaunchError { throw error } catch {
            guard FileManager.default.fileExists(atPath: target.path) else { throw LaunchError.failed("Couldn't keep a copy of this file.") }
        }
        cache.sweep(.media, now: now)
        return target
    }

    /// The pre-cache media folder (copies kept for one run); removed once.
    public static var legacyCacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Burro/Media", isDirectory: true)
    }
    public static func removeLegacyCache() {
        try? FileManager.default.removeItem(at: legacyCacheFolder)
    }
}
