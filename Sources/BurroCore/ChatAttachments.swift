// Files and images dropped or pasted into the reply composer. Only for chats on this Mac: a file
// must be a regular file (links are judged by what they point at) of at most 20 MB, outside the
// usual credential folders, and at most eight go with one message. Codex receives images as
// `localImage {path}` input items (confirmed in its app-server schema) and other files as paths in
// the text; Claude receives every path in the text and reads the files itself. Pasted image data
// is written owner-only into Burro's own temporary folder first.
import Foundation

public enum ChatAttachments {
    public static let maxBytes = 20 * 1024 * 1024
    public static let maxCount = 8
    public static let localOnly = "Attachments work for chats on this Mac for now."
    static let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    /// Folders under your home whose files never go to an agent from here.
    static let privateFolders = [".ssh", ".gnupg", ".aws", ".config/gh", "Library/Keychains", ".codex/auth.json", ".claude/.credentials.json"]

    public static func isImage(_ path: String) -> Bool { images.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }

    /// The checked absolute path to attach, or an error you can read.
    public static func validate(_ path: String, home: String = NSHomeDirectory()) throws -> String {
        guard path.hasPrefix("/") else { throw LaunchError.failed("Attach a file from this Mac.") }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let name = URL(fileURLWithPath: path).lastPathComponent
        for folder in privateFolders {
            let blocked = (home as NSString).appendingPathComponent(folder)
            if resolved == blocked || resolved.hasPrefix(blocked + "/") { throw LaunchError.failed("\(name) is in a private folder, so Burro won't attach it.") }
        }
        var info = stat()
        guard stat(resolved, &info) == 0 else { throw LaunchError.failed("\(name) isn't there any more.") }
        guard info.st_mode & S_IFMT == S_IFREG else { throw LaunchError.failed("\(name) isn't a file Burro can attach.") }
        guard info.st_size <= maxBytes else { throw LaunchError.failed("\(name) is larger than 20 MB.") }
        return resolved
    }

    /// Adds files to a list: duplicates skipped, at most `maxCount`. Returns the new list and the
    /// first problem, if any file was refused.
    public static func adding(_ paths: [String], to current: [String], home: String = NSHomeDirectory()) -> (paths: [String], problem: String?) {
        var result = current, problem: String?
        for path in paths {
            do {
                let checked = try validate(path, home: home)
                guard !result.contains(checked) else { continue }
                guard result.count < maxCount else { problem = "At most \(maxCount) files go with one message."; break }
                result.append(checked)
            } catch { problem = problem ?? (error as? LocalizedError)?.errorDescription }
        }
        return (result, problem)
    }

    /// Codex input items: the text (with any non-image paths), then each image as `localImage`.
    public static func codexInput(text: String, paths: [String]) -> [[String: Any]] {
        let files = paths.filter { !isImage($0) }
        var items: [[String: Any]] = [["type": "text", "text": withPaths(text, files)]]
        items += paths.filter(isImage).map { ["type": "localImage", "path": $0] }
        return items
    }

    /// Claude's prompt: the text, then every attached path on its own line.
    public static func claudeText(text: String, paths: [String]) -> String { withPaths(text, paths) }

    static func withPaths(_ text: String, _ paths: [String]) -> String {
        guard !paths.isEmpty else { return text }
        return text + "\n\nAttached file\(paths.count == 1 ? "" : "s"):\n" + paths.joined(separator: "\n")
    }

    /// Writes pasted image data to `folder` (created 0700) as a new 0600 file, never following a link.
    public static func savePasted(_ data: Data, extension ext: String, folder: URL) throws -> String {
        guard data.count <= maxBytes else { throw LaunchError.failed("That image is larger than 20 MB.") }
        guard images.contains(ext.lowercased()) else { throw LaunchError.failed("Burro can paste PNG, JPEG, GIF or WebP images.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw LaunchError.failed("Burro's attachment folder isn't safe to use.")
        }
        let url = folder.appendingPathComponent("pasted-\(UUID().uuidString.prefix(8).lowercased()).\(ext.lowercased())")
        try OwnerOnlyFile.write(data, to: url)
        return url.path
    }

    /// Burro's folder for pasted images.
    public static var pasteFolder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("burro-attachments", isDirectory: true) }
}
