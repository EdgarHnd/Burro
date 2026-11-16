// "Ask the Orchestrator about this chat" (and the ⌘K palette's "Ask the Orchestrator about “…”"):
// puts "What's the latest on “<chat>” (<machine>)?" in the Orchestrator's question field (after a
// half-written question, on a new line, never over it) and opens its page, where the composer
// takes focus. It never sends: asking costs tokens, so the owner clicks Ask; Return sends only
// once he has typed or changed something.
import BurroCore

extension AppStore {
    func prefillOrchestratorQuestion(chatTitle: String, machine: String?) {
        orchestrator.prefill(question: OrchestratorAskAbout.question(title: chatTitle, machine: machine))
        page = .orchestrator
    }
}
