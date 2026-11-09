// Benches: your own groups of projects (Work, Homelab, Personal…) with an icon and colour.
// Stored in Burro's preferences; a project can sit on more than one bench.
import Foundation
import Observation
import SwiftUI
import BurroCore

struct Bench: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var symbol: String
    var color: Int
    var projects: [String]

    static let symbols = ["square.stack.3d.up", "briefcase", "house", "person", "star", "leaf", "gamecontroller", "hammer",
                          "server.rack", "cpu", "paintbrush", "book", "heart", "globe", "bolt", "sparkles"]
    static let colors: [Color] = [.purple, AppAppearance.blue, .teal, AppAppearance.green, AppAppearance.amber, .orange, .pink, .indigo]
    var tint: Color { Bench.colors[(color % Bench.colors.count + Bench.colors.count) % Bench.colors.count] }
}

@MainActor @Observable final class BenchesStore {
    private(set) var benches: [Bench] = []
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "benches"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let decoded = try? JSONDecoder().decode([Bench].self, from: data) { benches = decoded }
    }
    func bench(_ id: UUID) -> Bench? { benches.first { $0.id == id } }
    func save(_ bench: Bench) {
        var bench = bench
        bench.name = bench.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bench.name.isEmpty else { return }
        if let index = benches.firstIndex(where: { $0.id == bench.id }) { benches[index] = bench } else { benches.append(bench) }
        persist()
    }
    func remove(_ id: UUID) { benches.removeAll { $0.id == id }; persist() }
    private func persist() { if let data = try? JSONEncoder().encode(benches) { defaults.set(data, forKey: Self.key) } }

    /// Combined live counts and today's tokens for a bench's projects.
    func rollup(_ bench: Bench, projects: [HomeProject]) -> (counts: HomeCounts, tokens: Double, members: Int) {
        let members = projects.filter { bench.projects.contains($0.id) }
        var counts = HomeCounts()
        for project in members {
            counts.running += project.counts.running; counts.waiting += project.counts.waiting
            counts.done += project.counts.done; counts.scheduled += project.counts.scheduled
        }
        return (counts, members.reduce(0) { $0 + $1.tokensToday }, members.count)
    }
}
