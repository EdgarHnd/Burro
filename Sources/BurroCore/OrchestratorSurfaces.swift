// Where the Orchestrator's drafts and Brief show up outside its own page, as small pure decisions:
// - `BriefDrafts`: a draft is a reply proposal still waiting for your Send (triage drafts them;
//   the Orchestrator proposes them when you ask). One per chat is shown: triage's own draft for an
//   open Brief item first, else the newest waiting reply. The menu bar counts chats that have one,
//   the Chats page shows it above the composer, and the Brief shows it inline on the chat's row.
// - `ComposerInsertion`: "Use" on a draft puts its text into the chat's composer for you to edit
//   and send yourself; it never sends.
// - `ChatAlertText`: a needs-you banner's body, with triage's headline once there is one.
// - `OrchestratorMachines`: which machine a proposed new chat runs on, and the folders known there.
// None of these send, start or read anything.
import Foundation

public enum BriefDrafts {
    /// The `conversation` triage's drafts are recorded with.
    public static let triageConversation = "triage"

    /// The newest reply proposal for a chat still waiting for Send (not sent, not expired).
    public static func waitingReply(chatID: String?, actions: [OrchestratorAction], now: Date) -> OrchestratorAction? {
        guard let chatID = chatID?.lowercased(), !chatID.isEmpty else { return nil }
        return actions.filter { $0.kind == .reply && $0.isWaiting(now: now) && $0.chatID?.lowercased() == chatID }
            .max { $0.createdAt < $1.createdAt }
    }

    /// The draft shown for a chat: its open Brief item's own draft when that still waits, else the
    /// newest waiting reply for it.
    public static func draft(chatID: String, file: BriefFile, actions: [OrchestratorAction], now: Date) -> OrchestratorAction? {
        let linked = file.open.filter { $0.chatID?.lowercased() == chatID.lowercased() }.compactMap(\.proposalID)
        if let own = actions.first(where: { linked.contains($0.id) && $0.kind == .reply && $0.isWaiting(now: now) }) { return own }
        return waitingReply(chatID: chatID, actions: actions, now: now)
    }

    /// Chats with a draft waiting, one each (the draft shown for it).
    public static func ready(file: BriefFile, actions: [OrchestratorAction], now: Date) -> [OrchestratorAction] {
        let chats = Set(actions.filter { $0.kind == .reply && $0.isWaiting(now: now) }.compactMap { $0.chatID?.lowercased() })
        return chats.sorted().compactMap { draft(chatID: $0, file: file, actions: actions, now: now) }
    }

    /// The proposals the Brief shows inline on its Needs-you rows (so it doesn't count them again).
    public static func shownInline(file: BriefFile, actions: [OrchestratorAction], now: Date) -> Set<String> {
        var ids = Set(file.open.compactMap(\.proposalID))
        for item in file.open where item.kind.needsYou {
            if let chat = item.chatID, let draft = draft(chatID: chat, file: file, actions: actions, now: now) { ids.insert(draft.id) }
        }
        return ids
    }

    /// "3 drafts ready", nil for none.
    public static func menuTitle(_ count: Int) -> String? {
        count <= 0 ? nil : count == 1 ? "1 draft ready" : "\(count) drafts ready"
    }

    /// The first line of a draft, for one-line surfaces.
    public static func firstLine(_ text: String, limit: Int = 90) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count <= limit ? line : String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// A one-shot request to put text into one chat's composer.
public struct ComposerInsertion: Sendable, Equatable {
    public var chatID: String
    public var text: String
    /// Distinguishes two requests with the same text.
    public var token: UUID
    public init(chatID: String, text: String, token: UUID = UUID()) { self.chatID = chatID; self.text = text; self.token = token }

    /// The composer's text after inserting into it, or nil when this request is for another chat.
    /// An empty composer takes the text as is; anything already typed is kept above it.
    public func merged(into existing: String, chatID current: String) -> String? {
        guard current.lowercased() == chatID.lowercased() else { return nil }
        let typed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty { return text }
        if typed.contains(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return existing }
        return typed + "\n\n" + text
    }
}

public enum ChatAlertText {
    /// A banner's body: "Needs you: <title>", or with triage's headline once there is one
    /// ("<title>: <headline>").
    public static func body(needsYou: Bool, title: String, headline: String? = nil) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = needsYou ? "Needs you" : "Finished"
        if let headline = headline?.trimmingCharacters(in: .whitespacesAndNewlines), !headline.isEmpty {
            return title.isEmpty ? "\(lead): \(headline)" : "\(title): \(headline)"
        }
        return title.isEmpty ? lead : "\(lead): \(title)"
    }
}

public enum OrchestratorMachines {
    public static let thisMac = "This Mac"
    /// Folders per machine in the snapshot.
    public static let folderLimit = 40

    /// The machine a `start_chat` names: nil for this Mac (no name, or "This Mac"), the host for a
    /// configured, enabled machine by name (any case), or the names to choose from.
    public static func resolve(_ name: String?, hosts: [RemoteHost]) -> Result<RemoteHost?, Refusal> {
        let wanted = (name ?? "").trimmingCharacters(in: .whitespaces)
        if wanted.isEmpty || wanted.caseInsensitiveCompare(thisMac) == .orderedSame || wanted.lowercased() == "local" { return .success(nil) }
        let enabled = hosts.filter(\.enabled)
        if let host = enabled.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) { return .success(host) }
        return .failure(Refusal(names: [thisMac] + enabled.map(\.name)))
    }

    public struct Refusal: Error, Equatable {
        public var names: [String]
        public var message: String { "No machine named like that. Use one of: " + names.joined(separator: ", ") + "." }
    }

    /// A folder on another machine: an absolute path as given, or the known folder whose name or
    /// path matches. Nil when neither works (nothing is checked on the machine here).
    public static func folder(_ requested: String, known: [String]) -> String? {
        let text = requested.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("/") {
            let clean = (text as NSString).standardizingPath
            return clean.split(separator: "/").contains("..") ? nil : clean
        }
        let lower = text.lowercased()
        return known.first { URL(fileURLWithPath: $0).lastPathComponent.lowercased() == lower }
            ?? known.first { $0.lowercased().hasSuffix("/" + lower) }
    }

    /// The folders worth offering from a machine's remembered list: ones that exist, most recently
    /// used first, at most `folderLimit`.
    public static func offered(_ list: RemoteFolderList?) -> [String] {
        guard let list else { return [] }
        return list.folders.filter(\.exists).sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
            .prefix(folderLimit).map(\.path)
    }
}
