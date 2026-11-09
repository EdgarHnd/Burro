import XCTest
@testable import Burro
@testable import BurroCore

final class AquariumTests: XCTestCase {
    private func session(_ id: String, _ provider: AgentProvider, model: String? = nil, effort: String? = nil,
                         started: Date? = nil, subagent: Bool = false, parent: String? = nil, state: AgentState = .working) -> AgentSession {
        AgentSession(id: id, provider: provider, title: "Chat \(id)", cwd: "/tmp", state: state, updatedAt: Date(), evidence: "",
                     isSubagent: subagent, parentSessionID: parent, model: model, effort: effort, startedAt: started)
    }

    func testSpeciesComesFromProviderAndModel() {
        XCTAssertEqual(AquariumFish.make(session("a", .claude, model: "claude-opus-5-5"), waiting: false).species, .shark)
        XCTAssertEqual(AquariumFish.make(session("b", .claude, model: "claude-fable-5-1"), waiting: false).species, .sailfish)
        XCTAssertEqual(AquariumFish.make(session("c", .claude, model: "claude-sonnet-5-5"), waiting: false).species, .barracuda)
        XCTAssertEqual(AquariumFish.make(session("d", .claude, model: "claude-haiku-5-5"), waiting: false).species, .minnow)
        XCTAssertEqual(AquariumFish.make(session("e", .claude), waiting: false).species, .shark)
        XCTAssertEqual(AquariumFish.make(session("f", .codex, model: "gpt-6.1-sol"), waiting: false).species, .tuna)
        XCTAssertEqual(AquariumFish.make(session("g", .codex, model: "gpt-6-astra"), waiting: false).species, .angelfish)
        XCTAssertEqual(AquariumFish.make(session("h", .codex, model: "gpt-5.5"), waiting: false).species, .puffer)
        XCTAssertEqual(AquariumFish.make(session("i", .codex), waiting: false).species, .tuna)
        let fry = AquariumFish.make(session("j", .codex, subagent: true, parent: "codex:p"), waiting: false)
        XCTAssertEqual(fry.species, .fry)
        XCTAssertEqual(fry.parent, "codex:p")
    }

    func testScheduledChatsAreJellyfish() throws {
        let scheduled = session("s", .claude, model: "claude-opus-5-5", effort: "high", state: .scheduled)
        let jelly = AquariumFish.make(scheduled, waiting: false)
        XCTAssertEqual(jelly.species, .jellyfish)
        XCTAssertTrue(jelly.detail.hasSuffix("scheduled"))
        let school = AquariumFish.school(running: [session("r", .codex)], waiting: [], scheduled: (0..<8).map { session("s\($0)", .claude, state: .scheduled) })
        XCTAssertEqual(school.first?.id, "r")
        XCTAssertEqual(school.filter { $0.species == .jellyfish }.count, 5)

        let fish = [jelly]
        let size = CGSize(width: 1400, height: 900)
        let spot = try XCTUnwrap(Aquarium.place(fish, width: size.width, height: size.height, t: 500).first)
        XCTAssertEqual(Aquarium.fish(at: CGPoint(x: spot.x, y: spot.y - spot.length * 0.2), size: size, t: 500, fish: fish)?.id, "s")
        XCTAssertNotNil(Aquarium.shape(.jellyfish, 0.5, -0.2), "bell")
        XCTAssertNotNil(Aquarium.shape(.jellyfish, 0.1, 0.5), "tentacle")
        XCTAssertNil(Aquarium.shape(.jellyfish, 0.5, -0.6), "above the bell")
    }

    func testHomeSummaryListsScheduledChats() {
        let summary = HomeSummary.build(sessions: [session("a", .claude, state: .scheduled), session("b", .codex)], worktrees: [])
        XCTAssertEqual(summary.scheduled.map(\.id), ["a"])
        XCTAssertEqual(summary.running.map(\.id), ["b"])
    }

    func testEffortSetsVarietyAndAgeSetsSize() {
        XCTAssertEqual(["low", "medium", "high", "xhigh", "max", "ultra", "minimal", nil].map(AquariumFish.effortTier), [0, 1, 2, 3, 4, 4, 0, 1])
        XCTAssertLessThan(Aquarium.fins(0), Aquarium.fins(4))
        XCTAssertEqual(AquariumFish.growth(0), 0.55, accuracy: 0.001)
        XCTAssertEqual(AquariumFish.growth(86_400), 1, accuracy: 0.001)
        XCTAssertLessThan(AquariumFish.growth(600), AquariumFish.growth(3_600))
        XCTAssertEqual(AquariumFish.growth(86_400 * 365), 1.15)
        let now = Date()
        let fish = AquariumFish.make(session("a", .claude, model: "claude-opus-5-5", effort: "xhigh", started: now.addingTimeInterval(-7_200)),
                                     waiting: false, now: now)
        XCTAssertEqual(fish.detail, "Opus 5.5 · xhigh · 2h old")
    }

    func testModelNames() {
        XCTAssertEqual(AquariumFish.modelName("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(AquariumFish.modelName("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(AquariumFish.modelName("gpt-6-astra"), "gpt-6-astra")
        XCTAssertNil(AquariumFish.modelName(""))
    }

    func testSchoolPutsWaitingFirstAndCapsFish() {
        let running = (0..<30).map { session("r\($0)", .claude) }
        let waiting = [session("w", .codex)]
        let school = AquariumFish.school(running: running + waiting, waiting: waiting)
        XCTAssertEqual(school.first?.id, "w")
        XCTAssertTrue(school.first?.waiting == true)
        XCTAssertEqual(school.filter { $0.id == "w" }.count, 1)
        XCTAssertEqual(school.count, 24)
    }

    func testTodaysOtherChatsSwimDarker() {
        let idle = session("i", .claude, state: .idle), working = session("r", .codex)
        let school = AquariumFish.school(running: [working], waiting: [], today: [idle, working])
        XCTAssertEqual(school.map(\.id), ["r", "i"])
        XCTAssertEqual(school.map(\.resting), [false, true])
        XCTAssertTrue(school[1].detail.hasSuffix("idle"))
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: now))!
        var old = session("o", .codex, state: .inactive); old.updatedAt = yesterday
        var recent = session("n", .codex, state: .inactive); recent.updatedAt = now
        XCTAssertEqual(HomeSummary.build(sessions: [old, recent], worktrees: [], now: now).today.map(\.id), ["n"])
    }

    func testFishDoNotJumpWhenTheyGrowOrTheWindowResizes() {
        let t = 41_234.5
        func x(_ growth: Double, width: Double = 1400) -> Double {
            Aquarium.place([AquariumFish(id: "a", species: .shark, effort: 2, growth: growth)], width: width, height: 900, t: t)[0].x
        }
        XCTAssertEqual(x(0.8), x(0.8003), accuracy: 0.5)
        XCTAssertEqual(x(0.8, width: 1400), x(0.8, width: 1401), accuracy: 2)
        // Frame to frame, a swimming fish moves a few points, never across the tank.
        let fish = [AquariumFish(id: "b", species: .tuna, effort: 0, growth: 1)]
        var last = Aquarium.place(fish, width: 1400, height: 900, t: t)[0].x
        for step in 1...600 {
            let next = Aquarium.place(fish, width: 1400, height: 900, t: t + Double(step) / 6)[0].x
            if abs(next - last) < 500 { XCTAssertLessThan(abs(next - last), 12) }   // (or wrapping round, out of view)
            last = next
        }
    }

    func testWaitingFishTurnInsteadOfFlipping() {
        let fish = [AquariumFish(id: "w", species: .shark, waiting: true)]
        var last = Aquarium.place(fish, width: 1400, height: 900, t: 0)[0].direction
        for step in 1...1_200 {
            let next = Aquarium.place(fish, width: 1400, height: 900, t: Double(step) / 6)[0].direction
            XCTAssertLessThan(abs(next - last), 0.2)
            last = next
        }
    }

    func testClickHitsTheFishThatIsDrawnThere() throws {
        let fish = [AquariumFish(id: "shark", species: .shark, effort: 2, growth: 1)]
        let size = CGSize(width: 1400, height: 900)
        let t = 1_234.0
        let spot = try XCTUnwrap(Aquarium.place(fish, width: size.width, height: size.height, t: t).first)
        XCTAssertEqual(Aquarium.fish(at: CGPoint(x: spot.x, y: spot.y), size: size, t: t, fish: fish)?.id, "shark")
        XCTAssertNil(Aquarium.fish(at: CGPoint(x: spot.x, y: spot.y - spot.length), size: size, t: t, fish: fish))
    }

    func testShapesHaveBodiesAndEyes() {
        for species in [AquariumFish.Species.shark, .sailfish, .barracuda, .minnow, .tuna, .angelfish, .puffer, .fry, .jellyfish] {
            XCTAssertNotNil(Aquarium.shape(species, 0.55, 0), "\(species) body")
            XCTAssertNil(Aquarium.shape(species, 0.5, 0.9), "\(species) outside")
        }
        XCTAssertNil(Aquarium.shape(.shark, 0.88, -0.014), "shark eye")
        XCTAssertNotNil(Aquarium.shape(.sailfish, 1.15, 0.004), "sailfish bill")
    }

    func testClaudeTranscriptTailReadsTheLastModelAndEffort() throws {
        XCTAssertEqual(ClaudeTranscriptTail.projectFolder("/Users/me/Dev/my_app.v2"), "-Users-me-Dev-my-app-v2")
        let text = #"{"model":"claude-fable-5-1","effort":"high"} {"content":"{\"model\":\"fake\"}"} {"model":"claude-opus-5-5","effort":"xhigh"}"#
        XCTAssertEqual(ClaudeTranscriptTail.last("model", in: text), "claude-opus-5-5")
        XCTAssertEqual(ClaudeTranscriptTail.last("effort", in: text), "xhigh")
        XCTAssertNil(ClaudeTranscriptTail.last("model", in: #"{"model":"bad value"}"#))

        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = UUID().uuidString.lowercased()
        let folder = home.appendingPathComponent(".claude/projects/-tmp-proj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(text.utf8).write(to: folder.appendingPathComponent(id + ".jsonl"))
        let found = ClaudeTranscriptTail().modelAndEffort(home: home.path, cwd: "/tmp/proj", sessionID: id)
        XCTAssertEqual(found.model, "claude-opus-5-5")
        XCTAssertEqual(found.effort, "xhigh")
    }
}
