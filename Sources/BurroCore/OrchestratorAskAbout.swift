// The question "Ask the Orchestrator about this chat" puts in the Orchestrator's field (a chat row's
// context menu, a Brief row's menu, the ⌘K palette). It is only a prefill: it never replaces a
// half-written question (it goes on a new line after it), and Return sends only text the owner
// typed or changed; an untouched prefill goes only when he clicks Ask.
import Foundation

public enum OrchestratorAskAbout {
    /// "What's the latest on “Fix the login bug” (This Mac)?"; a blank machine reads as this Mac.
    public static func question(title: String, machine: String?) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = machine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "What's the latest on “\(name.isEmpty ? "this chat" : name)” (\(host.isEmpty ? "This Mac" : host))?"
    }

    /// The field after the prefill: the question alone when the field is empty, else what was
    /// there, then the question on a new line.
    public static func prefilled(existing: String, question: String) -> String {
        let kept = existing.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        return kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? question : kept + "\n" + question
    }

    /// Whether Return sends: only text the owner typed or changed, never an untouched prefill.
    public static func returnSends(draft: String, prefilled: String?) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft != prefilled
    }
}
