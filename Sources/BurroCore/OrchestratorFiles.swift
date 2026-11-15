// The Orchestrator's only way to look at files: `read_file` and `search_files` in burro-mcp. Claude
// Code's own file tools are switched off for it (`--tools ToolSearch` leaves only the deferred-tool loader), so this policy is the whole boundary.
// A file is readable only when the path of the file actually opened (asked of the open descriptor,
// so symlinks, `..` and differently-cased spellings can't get around it) lies inside a project or
// worktree folder from Burro's snapshot (only projects that are git repositories, and worktrees: a
// chat's working folder outside a repository is never a root) and outside every private folder:
// the whole of ~/Library (Burro's own data with tracked activity, notes, the snapshot and the
// Orchestrator's memory; caches; keychains), Claude's and Codex's folders and their profiles, key and
// credential folders (.ssh, .gnupg, .aws, .config, .docker, .kube) and every hidden file or folder
// directly in the home folder (.netrc, .npmrc, …). Files shaped like secrets (.env, private keys)
// and git internals are refused too. The home folder itself, or anything above it, is never a root. Reads are capped; searches skip build and dependency folders.
import Foundation

public struct OrchestratorFileAccess: Sendable {
    /// Canonical paths of the folders it may read under.
    public let roots: [String]
    /// Lowercased paths it may never read under, whatever the root.
    public let denied: [String]
    /// The roots as given and as resolved, lowercased: a path outside all of them is refused unopened.
    let spellings: [String]
    /// The home folder as given and as resolved, lowercased: hidden entries directly in it are private.
    let homes: [String]

    public static let readLimit = 256 * 1024
    public static let searchFileLimit = 1024 * 1024
    static let skippedFolders: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData", "target", "Pods", ".next",
                                              "dist", ".venv", "venv", "__pycache__", ".swiftpm"]

    public init(roots: [String], denied: [String], home: String = NSHomeDirectory()) {
        let denied = Self.expand(denied)
        self.denied = denied
        let given = (home as NSString).standardizingPath
        let home = Self.canonical(home) ?? given
        let homes = Array(Set([given.lowercased(), home.lowercased()])).sorted()
        self.homes = homes
        var kept: [String] = [], spellings = Set<String>()
        for given in roots {
            let standardized = (given as NSString).standardizingPath
            // Private folders are refused by name before anything there is opened.
            guard standardized.hasPrefix("/"), !Self.isPrivate(standardized, denied, homes), let root = Self.canonical(given) else { continue }
            // Never the whole disk, the home folder or anything above it, nor a root inside a private folder.
            guard root != "/", !Self.inside(home, root), !Self.isPrivate(root, denied, homes) else { continue }
            if !kept.contains(root) { kept.append(root) }
            spellings.insert(root.lowercased()); spellings.insert(standardized.lowercased())
        }
        self.roots = kept
        self.spellings = spellings.sorted()
    }

    /// The roots and private folders for this snapshot: local projects that are git repositories,
    /// and worktrees. A project that is only a chat's working folder is never a root.
    public static func standard(state: OrchestratorState?, home: String = NSHomeDirectory()) -> OrchestratorFileAccess {
        let roots = (state?.projects.filter(\.isRepository).map(\.path) ?? []) + (state?.worktrees.map(\.path) ?? [])
        return OrchestratorFileAccess(roots: roots, denied: deniedFolders(home: home, profiles: state?.usageProfiles ?? [:]), home: home)
    }

    /// Folders the Orchestrator can never read, even when a project sits above them.
    public static func deniedFolders(home: String, profiles: [UsageProvider: String] = [:]) -> [String] {
        let library = (home as NSString).appendingPathComponent("Library")
        var folders = [
            library,
            (library as NSString).appendingPathComponent("Application Support/Burro"),
            (library as NSString).appendingPathComponent("Caches/Burro"),
            (home as NSString).appendingPathComponent(".claude"),
            (home as NSString).appendingPathComponent(".codex"),
            (home as NSString).appendingPathComponent(".ssh"),
            (home as NSString).appendingPathComponent(".gnupg"),
            (home as NSString).appendingPathComponent(".aws"),
            (home as NSString).appendingPathComponent(".config"),
            (home as NSString).appendingPathComponent(".docker"),
            (home as NSString).appendingPathComponent(".kube"),
            (library as NSString).appendingPathComponent("Keychains"),
        ]
        folders += profiles.values.filter { $0.hasPrefix("/") }
        return folders
    }

    // MARK: Policy

    /// Whether a canonical path (as the open descriptor reports it) may be read.
    public func allows(canonical path: String) -> Bool {
        guard roots.contains(where: { Self.inside(path, $0) }), !Self.isPrivate(path, denied, homes) else { return false }
        let components = path.split(separator: "/").map { $0.lowercased() }
        if components.contains(".git") { return false }
        return !Self.looksSecret(components.last ?? "")
    }

    static func looksSecret(_ name: String) -> Bool {
        if [".env", ".netrc", ".npmrc", ".pypirc", ".pgpass", "credentials", "credentials.json"].contains(name) { return true }
        if name.hasPrefix(".env.") || name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") || name.hasPrefix("id_ecdsa") { return true }
        return [".pem", ".key", ".p12", ".pfx", ".keychain", ".keychain-db"].contains { name.hasSuffix($0) }
    }

    static func inside(_ path: String, _ folder: String) -> Bool {
        folder == "/" || path == folder || path.hasPrefix(folder + "/")
    }

    static func isDenied(_ path: String, _ denied: [String]) -> Bool {
        let lower = path.lowercased()
        return denied.contains { inside(lower, $0) }
    }

    /// A denied folder, or a hidden file or folder directly in the home folder (or anything in one).
    static func isPrivate(_ path: String, _ denied: [String], _ homes: [String]) -> Bool {
        if isDenied(path, denied) { return true }
        let lower = path.lowercased()
        return homes.contains { home in
            guard home != "/", lower.hasPrefix(home + "/") else { return false }
            return lower.dropFirst(home.count + 1).hasPrefix(".")
        }
    }

    /// Each private folder as written and as it resolves on disk, lowercased (APFS ignores case).
    static func expand(_ folders: [String]) -> [String] {
        var out = Set<String>()
        for folder in folders where folder.hasPrefix("/") {
            out.insert((folder as NSString).standardizingPath.lowercased())
            if let resolved = realpath(folder, nil) {
                out.insert(String(cString: resolved).lowercased())
                free(resolved)
            }
        }
        return out.sorted()
    }

    /// The real path of an existing file or folder, from the descriptor of the opened item.
    static func canonical(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return descriptorPath(fd)
    }

    static func descriptorPath(_ fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return String(cString: buffer)
    }

    // MARK: Reading

    public enum Refusal: Error, Equatable, LocalizedError {
        case notAbsolute, notFound, notAllowed, notAFile, unreadable
        public var errorDescription: String? {
            switch self {
            case .notAbsolute: "Pass an absolute path inside a project or worktree folder."
            case .notFound: "No such file."
            case .notAllowed: "That file is outside the project and worktree folders Burro lets you read (or is private)."
            case .notAFile: "That's a folder; use search_files to list it."
            case .unreadable: "Couldn't read that file."
            }
        }
    }

    /// Opens a path and returns its descriptor and canonical path, only when the policy allows it.
    func openAllowed(_ path: String, regularOnly: Bool = true) -> Result<(fd: Int32, path: String), Refusal> {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return .failure(.notAbsolute) }
        // Refused unopened: private folders, and anything not spelled as inside a root.
        let standardized = (expanded as NSString).standardizingPath
        if Self.isPrivate(standardized, denied, homes) || !spellings.contains(where: { Self.inside(standardized.lowercased(), $0) }) {
            return .failure(.notAllowed)
        }
        let fd = open(expanded, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return .failure(errno == EACCES ? .notAllowed : .notFound) }
        guard let real = Self.descriptorPath(fd), allows(canonical: real) else { close(fd); return .failure(.notAllowed) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { close(fd); return .failure(.unreadable) }
        if regularOnly && (info.st_mode & S_IFMT) != S_IFREG {
            close(fd)
            return .failure((info.st_mode & S_IFMT) == S_IFDIR ? .notAFile : .unreadable)
        }
        return .success((fd, real))
    }

    /// Lines `offset`… of a text file (1-based), at most `limit` lines and `readLimit` bytes, numbered.
    public func read(_ path: String, offset: Int = 1, limit: Int = 400) -> Result<String, Refusal> {
        switch openAllowed(path) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let opened):
            defer { close(opened.fd) }
            let handle = FileHandle(fileDescriptor: opened.fd, closeOnDealloc: false)
            let data = (try? handle.read(upToCount: Self.readLimit * 4)) ?? Data()
            if data.prefix(4096).contains(0) { return .success("\(opened.path) looks like a binary file; not shown.") }
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let start = max(1, offset), count = max(1, min(2000, limit))
            guard start <= lines.count else { return .success("\(opened.path) has \(lines.count) lines.") }
            var out = ["\(opened.path) (lines \(start)–\(min(lines.count, start + count - 1)) of \(lines.count))"]
            var bytes = 0
            for (index, line) in lines[(start - 1)..<min(lines.count, start - 1 + count)].enumerated() {
                let row = "\(start + index)\t" + String(line.prefix(2000))
                bytes += row.utf8.count
                if bytes > Self.readLimit { out.append("(cut here; pass offset \(start + index) to read on)"); break }
                out.append(row)
            }
            return .success(out.joined(separator: "\n"))
        }
    }

    /// Files whose name matches `name` (a shell pattern like `*.swift`) and, with `query`, lines
    /// containing it (case-insensitive), under one root or all of them.
    public func search(query: String?, name: String?, under folder: String? = nil, limit: Int = 80) -> String {
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard query != nil || name != nil else { return "Pass a query (text to find) or a name pattern." }
        var bases = roots
        if let folder {
            let standardized = ((folder as NSString).expandingTildeInPath as NSString).standardizingPath
            guard !Self.isPrivate(standardized, denied, homes), spellings.contains(where: { Self.inside(standardized.lowercased(), $0) }),
                  let real = Self.canonical(standardized), roots.contains(where: { Self.inside(real, $0) }),
                  !Self.isPrivate(real, denied, homes) else { return Refusal.notAllowed.errorDescription! }
            bases = [real]
        }
        guard !bases.isEmpty else { return "Burro's snapshot lists no project folders on this Mac." }
        var results: [String] = [], visited = 0, more = false
        let cap = max(1, min(300, limit))
        scan: for base in bases {
            guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: base, isDirectory: true),
                                                             includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey],
                                                             options: [.skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                visited += 1
                if visited > 50_000 { more = true; break scan }
                let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                if values?.isSymbolicLink == true { continue }
                let path = url.path
                if values?.isDirectory == true {
                    if Self.skippedFolders.contains(url.lastPathComponent) || Self.isPrivate(path, denied, homes) { walker.skipDescendants() }
                    continue
                }
                guard values?.isRegularFile == true else { continue }
                if let name, fnmatch(name, url.lastPathComponent, 0) != 0 { continue }
                guard let query else {
                    guard allows(canonical: path) else { continue }
                    results.append(path)
                    if results.count >= cap { more = true; break scan }
                    continue
                }
                guard case .success(let opened) = openAllowed(path) else { continue }
                let handle = FileHandle(fileDescriptor: opened.fd, closeOnDealloc: false)
                let data = (try? handle.read(upToCount: Self.searchFileLimit)) ?? Data()
                close(opened.fd)
                if data.prefix(4096).contains(0) { continue }
                for (index, line) in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where line.range(of: query, options: .caseInsensitive) != nil {
                    results.append("\(opened.path):\(index + 1): " + String(line.trimmingCharacters(in: .whitespaces).prefix(240)))
                    if results.count >= cap { more = true; break scan }
                }
            }
        }
        if results.isEmpty { return "No matches." }
        return results.joined(separator: "\n") + (more ? "\n(more not shown; narrow the search)" : "")
    }
}

fileprivate extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
