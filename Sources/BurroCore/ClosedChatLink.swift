// Opening a chat Burro was asked about but no longer lists. Burro's list of chats on this Mac holds
// only chats that are still open (a live process), so a Claude app chat that asked a question,
// finished its turn and closed leaves the list while the Brief still names it.
// - `links(for:root:)` finds such a chat's record in the Claude app's own session folder
//   (`~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_*.json`)
//   by its `cliSessionId` and returns the same validated `claude://code/continue?session=local_…`
//   link a listed chat gets (`AgentSession.claudeDesktopURL`). Only local Claude ids
//   (`claude:<uuid>`) are looked up; Codex and `remote:` ids never get a link here. Archived records
//   give none. Bounded like ProviderReadState's walker: exactly two directory levels, `local_*.json`
//   files under 1 MB, symlinks never followed, nothing else read (never transcripts); each file's
//   raw bytes are checked for the UUID before any JSON is parsed. One walk serves many ids.
// - `openTarget` is the one decision every "open this chat" click uses (Home, the Brief queue, a
//   notification): show it in Burro, open it in the Claude app, or explain on the Chats page.
// Navigation only: nothing here sends, starts or stops anything.
import Foundation

public enum ClosedChatLink {
    /// The Claude app's session records under a home folder.
    public static func root(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    /// The lowercased Claude Code session UUID of a local Claude chat id (`claude:<uuid>`), else nil.
    public static func localClaudeUUID(_ chatID: String) -> String? {
        let prefix = "claude:"
        guard chatID.lowercased().hasPrefix(prefix) else { return nil }
        let uuid = String(chatID.dropFirst(prefix.count))
        guard uuid.count == 36, UUID(uuidString: uuid) != nil else { return nil }
        return uuid.lowercased()
    }

    /// Links by chat id (as given) for every id whose Claude app record exists and isn't archived.
    public static func links(for chatIDs: some Sequence<String>, root: URL) -> [String: URL] {
        var wanted: [String: [String]] = [:]   // uuid -> the chat ids asking for it
        for id in chatIDs { if let uuid = localClaudeUUID(id) { wanted[uuid, default: []].append(id) } }
        guard !wanted.isEmpty else { return [:] }
        let needles = wanted.keys.map { (uuid: $0, lower: Data($0.utf8), upper: Data($0.uppercased().utf8)) }
        // Files come in a stable order; the first record that gives a link wins, so two matching
        // records always give the same answer.
        var found: [String: URL] = [:]
        for file in recordFiles(root: root) {
            guard let data = try? Data(contentsOf: file) else { continue }
            let present = needles.filter { found[$0.uuid] == nil && (data.range(of: $0.lower) != nil || data.range(of: $0.upper) != nil) }
            guard !present.isEmpty, let record = try? JSONDecoder().decode(Record.self, from: data),
                  let cli = record.cliSessionId?.lowercased(), present.contains(where: { $0.uuid == cli }),
                  record.isArchived != true, let url = record.sessionId.flatMap(AgentSession.claudeDesktopURL) else { continue }
            found[cli] = url
            if found.count == wanted.count { break }
        }
        var result: [String: URL] = [:]
        for (uuid, ids) in wanted { if let url = found[uuid] { for id in ids { result[id] = url } } }
        return result
    }

    /// One chat's link, or nil.
    public static func link(for chatID: String, root: URL) -> URL? { links(for: [chatID], root: root)[chatID] }

    private struct Record: Decodable {
        var sessionId: String?
        var cliSessionId: String?
        var isArchived: Bool?
    }

    /// `<root>/<account>/<org>/local_*.json`, real directories and regular files only, each under 1 MB.
    private static func recordFiles(root: URL) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        func children(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        func isRealDirectory(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return values.isSymbolicLink != true && values.isDirectory == true
        }
        var files: [URL] = []
        for account in children(root) where isRealDirectory(account) {
            for org in children(account) where isRealDirectory(org) {
                for file in children(org) where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true,
                          values.isRegularFile == true, let size = values.fileSize, size < 1024 * 1024 else { continue }
                    files.append(file)
                }
            }
        }
        return files
    }

    // MARK: What Open does

    public enum OpenTarget: Equatable, Sendable {
        /// The chat is in Burro's list: show it on the Chats page.
        case showInBurro
        /// Not listed, but the Claude app still has it: open it there.
        case openInClaude(URL)
        /// Not listed and no link: the Chats page explains why it isn't there.
        case explain
    }

    /// `listed`: the chat is in Burro's list. `listLoaded`: Burro has checked its agents at least
    /// once (before that every chat looks unlisted, so Open keeps selecting it in Burro). `link`:
    /// the closed-chat link known for it, used only for a local Claude id.
    public static func openTarget(chatID: String, listed: Bool, listLoaded: Bool, link: URL?) -> OpenTarget {
        if listed || !listLoaded { return .showInBurro }
        if let link, localClaudeUUID(chatID) != nil, link.scheme == "claude" { return .openInClaude(link) }
        return .explain
    }
}
