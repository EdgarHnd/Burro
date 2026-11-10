// What shipped on GitHub per day for the main project, for the Today page. Read through the GitHub
// CLI only while the page is on screen: today at most every five minutes, yesterday again until
// half an hour after midnight (late merges), older days once. Kept in memory only.
import Foundation
import Observation
import BurroCore

@MainActor @Observable final class ShippedStore {
    enum State: Equatable {
        case loading
        case loaded(ShippedDay)
        case failed(ShippedReader.Failure)
    }

    private(set) var states: [Date: State] = [:]
    /// The main project's checkout, set by the app store.
    @ObservationIgnored var project: () -> String? = { nil }
    @ObservationIgnored private var fetchedAt: [Date: Date] = [:]
    @ObservationIgnored private var running: Set<Date> = []
    @ObservationIgnored private var repositories: [String: String?] = [:]
    @ObservationIgnored private var currentPath: String?
    @ObservationIgnored private let calendar = Calendar.current

    func state(_ day: Date) -> State? { states[calendar.startOfDay(for: day)] }
    func shipped(_ day: Date) -> ShippedDay? {
        if case .loaded(let value) = state(day) { return value }
        return nil
    }

    func refresh(_ date: Date, force: Bool = false) {
        let day = calendar.startOfDay(for: date), now = Date()
        guard let path = project() else { return }
        // Another main project: what was read belongs to the old one.
        if path != currentPath { currentPath = path; states = [:]; fetchedAt = [:]; running = [] }
        guard !running.contains(day), force || due(day, now: now) else { return }
        running.insert(day)
        if states[day] == nil || { if case .failed = states[day] { return true }; return false }() { states[day] = .loading }
        let known = repositories[path]
        Task { [weak self] in
            let repository: String?
            if let known { repository = known } else {
                repository = await Task.detached(priority: .utility) { ShippedReader.repository(at: path) }.value
            }
            let result: Result<ShippedDay, ShippedReader.Failure> = if let repository {
                await ShippedReader.load(day: day, repository: repository)
            } else { .failure(.noRepository) }
            guard let self, self.currentPath == path else { return }
            self.repositories[path] = repository
            self.running.remove(day)
            self.fetchedAt[day] = Date()
            switch result {
            case .success(let shipped): self.states[day] = .loaded(shipped)
            case .failure(let failure):
                // Keep what was shown when a later refresh fails; say so only when there's nothing.
                if case .loaded = self.states[day] { return }
                self.states[day] = .failed(failure)
            }
        }
    }

    private func due(_ day: Date, now: Date) -> Bool {
        guard let last = fetchedAt[day] else { return true }
        if case .failed = states[day] { return now.timeIntervalSince(last) > 60 }
        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        if now < end { return now.timeIntervalSince(last) > 300 }
        return last < end.addingTimeInterval(1800) && now.timeIntervalSince(last) > 300
    }
}
