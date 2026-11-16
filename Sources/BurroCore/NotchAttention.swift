// The expanded notch's Agents list drawn as two sections, the way the owner's mockup lays it out:
// "Needs you" (a card per chat waiting on you, with a quick reply or the one hand-off that works)
// and "Working" (one compact line per chat: state, machine · folder, how long its turn has run).
// Chats that only have a result to read are left out of the list and counted in the footer's
// "N ready to read". Everything here is pure: which section a group goes in, how many of
// NotchGeometry's fixed 56-point row slots the list needs so the panel fits it exactly (the
// geometry itself is unchanged), what a needs-you card offers (never a reply field for a
// sub-agent), how its reply field follows the Brief's draft and refuses one sent or changed
// elsewhere (and any draft Burro couldn't mark as going out), and
// which reply ids may keep the panel open (turn times come from HomeBoard's TurnClock).
import Foundation
import CoreGraphics

public enum NotchSection: Equatable, Sendable { case needsYou, working }

public enum NotchAttentionList {
    /// The section for a group, or nil when it only holds a result to read (counted, not listed).
    /// A group needs you when any of its chats still present and answering is waiting.
    public static func section(_ group: NotchGroup) -> NotchSection? {
        let live = group.members.filter { !group.unavailableIDs.contains($0.id) && $0.remote?.stale != true }
        if live.contains(where: { $0.state == .waiting }) { return .needsYou }
        if let root = group.root, root.isDone, !live.contains(where: { $0.state == .working || $0.state == .waiting }) { return nil }
        return .working
    }
    /// The chat a needs-you card answers: the parent when it waits, else the first waiting worker.
    public static func target(_ group: NotchGroup) -> AgentSession? {
        let live = group.members.filter { !group.unavailableIDs.contains($0.id) }
        return live.first { $0.state == .waiting } ?? group.root ?? group.workers.first
    }
    /// The quick-reply ids worth remembering (focused / edited fields): only chats some listed
    /// group still targets. A card whose target moved on, or whose chat left the list, can't
    /// keep the panel open.
    public static func liveReplyIDs(_ ids: Set<String>, groups: [NotchGroup]) -> Set<String> {
        ids.intersection(groups.compactMap { target($0)?.id })
    }
}

/// A needs-you card's reply field: the text in it and exactly what Burro prefilled from the
/// Brief's draft. Only text the owner typed or changed counts as edited: that holds the panel
/// open and is the only thing Return sends; an untouched draft follows the Brief (replaced when
/// the draft changes, cleared when it's discarded, used or sent elsewhere) and goes only by Send.
/// Text that came from a draft goes only while that draft is still the current one: once it was
/// sent or changed elsewhere, Send refuses ("Nothing was sent") and the draft link is cleared; the
/// text stays for the owner to read, but neither Send nor Return sends it until he changes it, so
/// the same answer never reaches the chat twice on a second click.
public struct NotchReplyField: Equatable, Sendable {
    public private(set) var text = ""
    /// The text Burro put in the field ("" when nothing was prefilled).
    public private(set) var prefilled = ""
    /// The last draft the field followed (kept after a send so it isn't prefilled again).
    public private(set) var draftID: String?
    /// Whether the text in the field came from `draftID` (as prefilled or as the owner's edit of it).
    public private(set) var fromDraft = false
    /// Text a Send refused as a stale draft: it can't go again until it is changed.
    public private(set) var refused: String?
    public init() {}

    public static let staleDraft = "That draft was sent or changed elsewhere. Nothing was sent."
    public static let notMarked = "Burro couldn't mark that drafted reply as going out. Nothing was sent."
    public static let alreadySending = "That drafted reply is already on its way."

    /// The owner typed or changed something (an untouched or emptied draft doesn't count).
    public var edited: Bool { text != prefilled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Return sends only the owner's own text; an untouched draft needs a click on Send.
    public var returnSends: Bool { edited && text != refused }
    /// Whether Send is enabled: something to send that isn't the refused stale text.
    public var sendable: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text != refused }
    /// The draft a Send of this text uses: only when the field still holds that draft's text
    /// (as prefilled or as the owner's edit of it) and that draft is the current one.
    public func draftForSend(currentDraftID: String?) -> String? {
        guard fromDraft, let draftID, draftID == currentDraftID else { return nil }
        return draftID
    }

    /// What a Send click may do with this text.
    public enum SendDecision: Equatable, Sendable {
        /// The owner's own text, not tied to any draft.
        case fresh
        /// The current draft (possibly edited): mark it as going out first; `began` false means
        /// it couldn't be marked, and then nothing is sent.
        case draft(String)
        /// Text from a draft that was sent or changed elsewhere: refuse, send nothing.
        case stale
    }
    public func sendDecision(currentDraftID: String?) -> SendDecision {
        if text == refused { return .stale }
        guard fromDraft, let draftID else { return .fresh }
        return draftID == currentDraftID ? .draft(draftID) : .stale
    }
    /// Whether a send of this decision may go, and the error to show when not. `began`: the
    /// Orchestrator store's `beginSending` result for the draft; `alreadySending`: it is going now.
    public static func gate(_ decision: SendDecision, began: Bool, alreadySending: Bool) -> String? {
        switch decision {
        case .fresh: return nil
        case .stale: return staleDraft
        case .draft: return began ? nil : (alreadySending ? Self.alreadySending : notMarked)
        }
    }

    public mutating func type(_ new: String) { text = new }
    /// Follows the Brief's current draft for this chat (nil when there is none) unless the owner
    /// edited the field.
    public mutating func follow(draftID id: String?, text draftText: String?) {
        guard !edited, id != draftID else { return }
        text = id == nil ? "" : (draftText ?? "")
        prefilled = text
        draftID = id
        fromDraft = id != nil
    }
    /// After a refused stale send: the draft link is cleared and this exact text is held back (a
    /// second click must not deliver it); once the owner changes it, it is a fresh message.
    public mutating func dropStaleDraft() { fromDraft = false; refused = text; prefilled = text }
    /// After a successful send (or one Burro couldn't confirm): empty, and the sent draft is not
    /// prefilled again.
    public mutating func clearAfterSend() { text = ""; prefilled = ""; fromDraft = false; refused = nil }
}

/// Heights in the expanded list, and how many of NotchGeometry's row slots they take.
public enum NotchListLayout {
    /// NotchGeometry's row and the gap between rows; the list has 8-point insets top and bottom.
    public static let slot: CGFloat = 56
    public static let gap: CGFloat = 6
    public static let inset: CGFloat = 8
    /// A needs-you card: title, one status line, the reply or hand-off row. Two cards, both
    /// headers and two working lines fill the panel's five-row maximum.
    public static let cardHeight: CGFloat = 92
    /// Two compact working lines fit in one slot.
    public static let lineHeight: CGFloat = 25
    public static let headerHeight: CGFloat = 16

    /// The row count to hand NotchGeometry: the fewest slots whose height holds this content
    /// (it reserves `2·inset + rows·slot + (rows−1)·gap` for the list). Zero for an empty list.
    public static func slots(cards: Int, lines: Int, headers: Int) -> Int {
        let items = max(0, cards) + max(0, lines) + max(0, headers)
        guard items > 0 else { return 0 }
        let height = 2 * inset + CGFloat(max(0, cards)) * cardHeight + CGFloat(max(0, lines)) * lineHeight
            + CGFloat(max(0, headers)) * headerHeight + CGFloat(items - 1) * gap
        return max(1, Int(((height - 2 * inset + gap) / (slot + gap)).rounded(.up)))
    }
}

/// What a needs-you card offers, from the same `ComposerPlan` the Chats composer uses.
public enum NotchReplyMode: Equatable, Sendable {
    /// A Claude chat whose open-session check hasn't answered yet: Send waits for it.
    case checking
    /// A reply can go now; `stopsFirst`: Send stops this chat's idle background session and
    /// continues it with the message (the composer's rule).
    case reply(stopsFirst: Bool)
    /// No reply from Burro: the one action that works, if any (else the card offers Open).
    case handOff(ComposerPlan.Action?)

    /// `checked`: the Claude open-session check has answered (always true for Codex).
    /// `subagent`: a sub-agent never gets a reply field from the notch, only Open.
    public static func decide(_ plan: ComposerPlan, provider: AgentProvider, checked: Bool, subagent: Bool = false) -> NotchReplyMode {
        if subagent { return .handOff(nil) }
        if plan.canSend {
            return provider == .claude && !checked ? .checking : .reply(stopsFirst: plan.sendStopsFirst)
        }
        // Queueing belongs to a working chat in the composer; a waiting chat never offers it here.
        if case .queue? = plan.action { return .handOff(nil) }
        return .handOff(plan.action)
    }

    /// The card's second line: the Brief's question or headline when triage wrote one, otherwise
    /// what Burro honestly knows (it can't tell a question from an approval request).
    public static func status(question: String?, mode: NotchReplyMode) -> String {
        if let question = question?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty { return question }
        switch mode {
        case .reply: return "Waiting for your reply"
        case .handOff: return "Waiting for your approval or answer"
        case .checking: return "Waiting for you"
        }
    }

    /// The note beside a hand-off: why there is no reply field.
    public static func handOffReason(_ plan: ComposerPlan, subagent: Bool) -> String? {
        subagent ? "A sub-agent: open it to answer." : plan.reason
    }

    /// The hand-off button's title, or nil when the card should offer Open (in Burro) instead.
    public static func handOffTitle(_ action: ComposerPlan.Action?, provider: AgentProvider, machine: String?) -> String? {
        switch action {
        case .openInProvider?: return provider == .codex ? "Open in Codex" : "Open in Claude"
        case .attachInTerminal?: return "Attach in Terminal"
        case .attachOnMachine?: return "Attach on \(machine ?? "its machine")"
        case .queue?, nil: return nil
        }
    }
}

/// The compact notch's two sides: the running (or scheduled) count on the left, and on the right
/// the chats waiting on you (amber) or, when none wait, unread results (blue). A zero side is empty.
public struct NotchCompactStatus: Equatable, Sendable {
    public enum Left: Equatable, Sendable { case none, working(Int), scheduled(Int) }
    public enum Right: Equatable, Sendable { case none, needsYou(Int), toRead(Int) }
    public var left: Left
    public var right: Right
    public init(working: Int, scheduled: Int, waiting: Int, done: Int) {
        left = working > 0 ? .working(working) : (scheduled > 0 ? .scheduled(scheduled) : .none)
        right = waiting > 0 ? .needsYou(waiting) : (done > 0 ? .toRead(done) : .none)
    }
}
