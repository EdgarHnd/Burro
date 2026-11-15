// Back and Forward between pages. Every change of `page` is recorded, wherever it comes from;
// changes made through `go(to:)` (the top bar, ⌘1–⌘8, the menu bar) count as chosen directly,
// and anything else (opening a chat from Today, a Home tile) counts as a jump, so the top bar
// can offer a way back to where the jump started.
import BurroCore

extension AppStore {
    func pageChanged(from old: AppPage) {
        guard page != old else { return }
        pageHistory.visit(page, jump: !pageChosenDirectly)
    }
    /// Shows a page the user picked directly.
    func go(to target: AppPage) {
        pageChosenDirectly = true
        page = target
        pageChosenDirectly = false
    }
    func goBack() { if let target = pageHistory.back() { go(to: target) } }
    func goForward() { if let target = pageHistory.forward() { go(to: target) } }
    /// The page the top bar's back pill returns to: Today from the Timeline, otherwise where a jump started.
    var backPillTarget: AppPage? {
        if page == .timeline { return .today }
        return pageHistory.jumpOrigin
    }
    /// The back pill's action: a real step back when it leads to the previous page, otherwise a direct visit.
    func followBackPill() {
        guard let target = backPillTarget else { return }
        if target == pageHistory.previous { goBack() } else { go(to: target) }
    }
}
