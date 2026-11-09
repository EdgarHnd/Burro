// Home's aquarium, the page's fixed background, drawn as a dot matrix: every shape is sampled on a
// 6-point grid and each cell becomes a small square sized by how solid the shape is there (a
// halftone), so a frame is a handful of path fills rather than text layout.
//
// Your agents are the fish, and each fish describes its chat:
// - Species is provider and model. Claude Opus is a shark, Fable a sailfish, Sonnet a barracuda and
//   Haiku a minnow. Codex's Sol models are tunas, Astra models angelfish, and other GPT models
//   pufferfish. Subagents are small fry keeping close to their parent.
// - Variety is reasoning effort. Low effort darts about with small plain fins; higher effort glides
//   slower with longer fins, stripes at xhigh and spots at max (or ultra).
// - Size is age. A new chat is a small fish that grows over its first day, and a little after.
// - Waiting on you turns a fish amber and brings it up to the surface, as if waiting to be fed.
// - Scheduled chats, waiting on a timer, are jellyfish drifting in place and pulsing.
// - Every other chat from today swims too, darker, so the tank shows the whole day.
// Clicking a fish opens its chat.
//
// Open water otherwise, with bubbles rising. With no agents at work the tank is empty.
import SwiftUI
import BurroCore

struct AquariumFish: Hashable, Sendable {
    enum Species: Sendable { case shark, sailfish, barracuda, minnow, tuna, angelfish, puffer, fry, jellyfish }
    var id: String
    var species: Species
    /// Reasoning effort, 0 (low) to 4 (max or ultra).
    var effort: Int = 1
    /// Size for age: 0.55 for a chat that just began, 1 at a day old, up to 1.15.
    var growth: Double = 0.8
    var waiting = false
    /// Not working, waiting or scheduled: drawn darker.
    var resting = false
    /// For a subagent's fry: the agent it swims with.
    var parent: String? = nil
    var title = ""
    var detail = ""

    /// One fish per chat: waiting on you first, then at work, scheduled (jellyfish), and the rest of
    /// today's chats, which rest darker. Each agent keeps the same fish.
    static func school(running: [AgentSession], waiting: [AgentSession], scheduled: [AgentSession] = [],
                       today: [AgentSession] = [], now: Date = Date()) -> [AquariumFish] {
        var fish: [AquariumFish] = [], seen: Set<String> = [], big = 0, fry = 0, jellies = 0
        let ordered = waiting.prefix(4).map { ($0, true) } + (running + scheduled + today).map { ($0, false) }
        for (session, isWaiting) in ordered where seen.insert(session.id).inserted {
            let one = make(session, waiting: isWaiting, now: now)
            switch one.species {
            case .fry: guard fry < 16 else { continue }; fry += 1
            case .jellyfish: guard jellies < 5 else { continue }; jellies += 1
            default: guard big < 24 else { continue }; big += 1
            }
            fish.append(one)
        }
        return fish
    }

    static func make(_ session: AgentSession, waiting: Bool, now: Date = Date()) -> AquariumFish {
        let model = session.model?.lowercased() ?? ""
        let species: Species
        if session.state == .scheduled, !waiting { species = .jellyfish }
        else if session.isSubagent == true, !waiting { species = .fry }
        else if session.provider == .claude {
            species = model.contains("fable") ? .sailfish : model.contains("sonnet") ? .barracuda : model.contains("haiku") ? .minnow : .shark
        } else {
            species = model.contains("astra") ? .angelfish : model.contains("mini") ? .minnow
                : (model.contains("sol") || model.isEmpty) ? .tuna : .puffer
        }
        let age = session.startedAt.map { max(0, now.timeIntervalSince($0)) }
        let resting = !waiting && session.state != .working && session.state != .scheduled
        return AquariumFish(id: session.id, species: species, effort: effortTier(session.effort), growth: growth(age), waiting: waiting,
                            resting: resting, parent: session.isSubagent == true ? session.parentSessionID : nil,
                            title: session.title, detail: detail(session, age: age))
    }

    static func effortTier(_ effort: String?) -> Int {
        switch effort?.lowercased() {
        case "minimal", "low": 0
        case "high": 2
        case "xhigh": 3
        case "max", "ultra": 4
        default: 1
        }
    }

    /// Grows over the first day on a log scale (an hour old is about three quarters grown), then slowly.
    static func growth(_ age: TimeInterval?) -> Double {
        guard let age else { return 0.8 }
        return min(1.15, 0.55 + 0.45 * log10(1 + age / 60) / log10(1 + 1440))
    }

    static func detail(_ session: AgentSession, age: TimeInterval?) -> String {
        var parts = [modelName(session.model) ?? session.provider.rawValue]
        if let effort = session.effort, !effort.isEmpty { parts.append(effort) }
        if let age { parts.append(ageText(age)) }
        if session.isSubagent == true { parts.append("subagent") }
        if session.state == .scheduled { parts.append("scheduled") }
        else if session.state != .working && session.state != .waiting {
            parts.append(session.isDone ? "done" : session.state == .idle ? "idle" : "inactive")
        }
        return parts.joined(separator: " · ")
    }

    /// "claude-opus-5-5" reads "Opus 5.5"; other names stay as they are.
    static func modelName(_ model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        guard model.hasPrefix("claude-") else { return model }
        let parts = model.dropFirst(7).split(separator: "-")
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().filter { $0.count <= 2 }.joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " " + version)
    }

    static func ageText(_ age: TimeInterval) -> String {
        let minutes = Int(age / 60)
        if minutes < 1 { return "just started" }
        if minutes < 60 { return "\(minutes)m old" }
        if minutes < 48 * 60 { return "\(minutes / 60)h old" }
        return "\(minutes / 1440)d old"
    }
}

enum Aquarium {
    static let cell = 6.0
    /// Resting fish far and near, then working fish far and near.
    static let strengths = [0.065, 0.09, 0.17, 0.25]

    /// The frame's cells: for each strength (and amber), the dot size in every lit cell. Shapes
    /// that overlap keep the larger dot, so each cell is drawn once per strength.
    struct Ink {
        /// Indices 0–3 by strength, then amber (layer -1) and the highlighted fish (layer -2).
        var cells = [[Int: Double]](repeating: [:], count: 6)
        var rings = Path()

        mutating func set(_ col: Int, _ row: Int, _ size: Double, _ layer: Int) {
            guard col >= 0, row >= 0, col < 1 << 20, size > 0.5 else { return }
            let key = row << 20 | col, index = layer >= 0 ? layer : (layer == -1 ? 4 : 5)
            if let old = cells[index][key], old >= size { return }
            cells[index][key] = size
        }

        /// A dot in the grid cell holding (x, y).
        mutating func dot(_ x: Double, _ y: Double, _ size: Double, _ layer: Int) {
            set(Int((x / Aquarium.cell).rounded(.down)), Int((y / Aquarium.cell).rounded(.down)), size, layer)
        }

        /// A soft round brush: cells within `radius` of (x, y), larger dots towards the middle.
        mutating func brush(_ x: Double, _ y: Double, radius: Double, size: Double, _ layer: Int) {
            guard radius >= Aquarium.cell * 0.5 else { dot(x, y, size, layer); return }
            let cell = Aquarium.cell, reach = radius + cell * 0.3
            let c0 = Int(((x - reach) / cell).rounded(.down)), c1 = Int(((x + reach) / cell).rounded(.down))
            let r0 = Int(((y - reach) / cell).rounded(.down)), r1 = Int(((y + reach) / cell).rounded(.down))
            for row in r0...r1 {
                for col in c0...c1 {
                    let d = hypot((Double(col) + 0.5) * cell - x, (Double(row) + 0.5) * cell - y)
                    if d <= reach { set(col, row, size * (1 - 0.5 * d / reach), layer) }
                }
            }
        }

        func path(_ index: Int) -> Path {
            var path = Path()
            let cell = Aquarium.cell
            for (key, size) in cells[index] {
                let side = min(cell - 1, max(0.8, size))
                let cx = (Double(key & 0xF_FFFF) + 0.5) * cell, cy = (Double(key >> 20) + 0.5) * cell
                path.addRect(CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side))
            }
            return path
        }
    }

    /// The animation clock in seconds (wrapping every thousand days), or a fixed moment when the
    /// tank holds still.
    static func time(_ date: Date, animate: Bool, still: Double = 1_000) -> Double {
        animate ? date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 86_400_000) : still
    }

    /// A frame: fish, jellyfish and bubbles. The one under the pointer is drawn stronger.
    static func draw(_ context: inout GraphicsContext, size: CGSize, t: Double, ink color: Color, amber: Color,
                         fish: [AquariumFish], highlight: String?) {
        let width = Double(size.width), height = Double(size.height)
        guard width > 0, height > 0 else { return }
        var ink = Ink()
        bubbles(&ink, width: width, floor: height, t: t)
        var highlightWaits = false
        for placed in place(fish, width: width, height: height, t: t) {
            let lit = placed.fish.id == highlight
            if lit { highlightWaits = placed.fish.waiting }
            render(&ink, placed, layer: lit ? -2 : placed.layer, width: width, height: height)
        }
        context.stroke(ink.rings, with: .color(color.opacity(0.13)), lineWidth: 0.8)
        for index in 0..<4 { context.fill(ink.path(index), with: .color(color.opacity(strengths[index]))) }
        context.fill(ink.path(4), with: .color(amber.opacity(0.42)))
        context.fill(ink.path(5), with: .color(highlightWaits ? amber.opacity(0.75) : color.opacity(0.5)))
    }

    // MARK: Randomness

    /// Stable 0…1 for a seed and a salt.
    static func r(_ seed: Int, _ salt: Int) -> Double { CoverField.hash(seed, salt, 7) }

    /// Stable 0…1 for an agent id (Swift's own hashing changes every launch).
    static func unit(_ id: String, _ salt: UInt64) -> Double {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ (salt &* 0x9e37_79b9_7f4a_7c15)
        for byte in id.utf8 { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        h ^= h >> 31; h = h &* 0xbf58_476d_1ce4_e5b9; h ^= h >> 29
        return Double(h >> 11) / Double(1 << 53)
    }

    // MARK: Bubbles

    /// Rising rings: two columns from below and a scatter.
    private static func bubbles(_ ink: inout Ink, width: Double, floor: Double, t: Double) {
        for i in 0..<20 {
            let column = i < 12
            let speed = 14 + r(i, 1) * 14
            let travel = (t * speed + r(i, 2) * floor).truncatingRemainder(dividingBy: floor)
            let y = floor - travel
            let source = column ? width * (i % 2 == 0 ? 0.08 : 0.9) : r(i, 3) * width
            let x = source + sin(t * 1.3 + Double(i)) * (column ? 4 : 8)
            let radius = 1.2 + 1.6 * travel / floor
            ink.rings.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
    }

    // MARK: Fish

    struct Placed {
        var fish: AquariumFish
        var x: Double, y: Double, direction: Double, length: Double, pitch: Double, beat: Double
        var layer: Int
        var depth: Double
    }

    /// Where every fish is at time `t`. Pure, so a click can ask which fish is under the pointer.
    static func place(_ fish: [AquariumFish], width: Double, height: Double, t: Double) -> [Placed] {
        var placed: [Placed] = [], byID: [String: Placed] = [:]
        // Far to near, so near fish sit on top.
        for one in fish.filter({ $0.species != .fry }).sorted(by: { unit($0.id, 1) < unit($1.id, 1) }) {
            let depth = unit(one.id, 1), seed = unit(one.id, 2) * 100
            let (full, pace) = size(one.species)
            let length = full * one.growth * (0.9 + 0.1 * depth)
            // Room to swim fully out of view: the largest this species gets, so growing never shifts its path.
            let margin = full * 1.15 * 1.3
            let layer = one.waiting ? -1 : one.resting ? (depth > 0.5 ? 1 : 0) : (depth > 0.5 ? 3 : 2)
            var spot: Placed
            if one.species == .jellyfish {
                // Scheduled: drifting nearly in place, rising a little with each pulse.
                let pulse = sin(t * 1.2 + seed)
                spot = Placed(fish: one, x: width * (0.1 + 0.8 * unit(one.id, 3)) + sin(t * 0.02 + seed) * width * 0.08,
                              y: height * (0.2 + 0.6 * unit(one.id, 8)) + sin(t * 0.05 + seed) * height * 0.07 - (pulse + 1) * 2.5,
                              direction: 1, length: length, pitch: 0, beat: t * 1.2 + seed, layer: layer, depth: depth)
            } else if one.waiting {
                // Waiting on you: up at the surface, nose raised, as if waiting to be fed. It patrols a
                // short way and turns at each end, narrowing as it faces you mid-turn.
                let wander = sin(t * 0.12 + seed)
                spot = Placed(fish: one, x: width * (0.14 + 0.72 * unit(one.id, 3)) + wander * 34,
                              y: height * 0.075 + length * 0.14 + sin(t * 0.9 + seed) * 3,
                              direction: max(-1, min(1, cos(t * 0.12 + seed) * 3)), length: length, pitch: -0.2,
                              beat: t * 5 + seed, layer: layer, depth: depth)
            } else {
                // Thinking harder swims slower.
                let speed = pace * [1.35, 1.15, 1.0, 0.85, 0.72][min(4, max(0, one.effort))] * (0.85 + 0.3 * unit(one.id, 4))
                let direction = unit(one.id, 5) < 0.5 ? 1.0 : -1.0
                // Position from time alone, as a share of the crossing, so neither growth nor a window
                // resize makes a fish jump.
                let phase = (t * speed / 2_400 + unit(one.id, 6)).truncatingRemainder(dividingBy: 1)
                let run = phase * (width + margin * 2)
                let x = direction > 0 ? run - margin : width + margin - run
                let drift = 0.1 + 0.06 * unit(one.id, 7), sway = 22.0
                let lane = height * (0.16 + 0.68 * unit(one.id, 8))
                spot = Placed(fish: one, x: x, y: lane + sin(t * drift + seed) * sway, direction: direction, length: length,
                              pitch: atan(cos(t * drift + seed) * sway * drift / speed),
                              beat: t * (2.2 + 30 / length) + seed, layer: layer, depth: depth)
            }
            placed.append(spot); byID[one.id] = spot
        }
        // Subagents: small fry beside their parent, or a loose group of their own.
        for (index, one) in fish.filter({ $0.species == .fry }).sorted(by: { $0.id < $1.id }).enumerated() {
            let k = unit(one.id, 1), seed = k * 100
            let length = size(.fry).0 * (0.75 + 0.3 * one.growth)
            if let parent = one.parent.flatMap({ byID[$0] }) {
                let side: Double = k < 0.5 ? 1 : -1
                placed.append(Placed(fish: one,
                    x: parent.x - parent.direction * parent.length * (0.1 + 0.4 * unit(one.id, 3)) + sin(t * 0.7 + seed) * 8,
                    y: parent.y + side * parent.length * (0.14 + 0.12 * unit(one.id, 4)) + cos(t * 0.6 + seed) * 5,
                    direction: parent.direction, length: length, pitch: 0, beat: t * 6 + seed, layer: one.resting ? 0 : 2, depth: 0.5))
            } else {
                let group = one.parent.map { unit($0, 9) } ?? 0.5
                let phase = (t * 18 / 2_400 + group).truncatingRemainder(dividingBy: 1)
                placed.append(Placed(fish: one, x: phase * (width + 200) - 100 - Double(index % 5) * 16 + sin(t + seed) * 6,
                    y: height * (0.3 + 0.4 * group) + Double(index % 3) * 12 + sin(t * 0.8 + seed) * 6,
                    direction: 1, length: length, pitch: 0, beat: t * 6 + seed, layer: one.resting ? 0 : 2, depth: 0.5))
            }
        }
        return placed
    }

    /// The fish under a point: active before resting, nearest first; forgiving by a cell either way.
    static func fish(at point: CGPoint, size: CGSize, t: Double, fish: [AquariumFish]) -> AquariumFish? {
        let placed = place(fish, width: Double(size.width), height: Double(size.height), t: t).reversed()
        for spot in placed.filter({ !$0.fish.resting }) + placed.filter(\.fish.resting) {
            for (dx, dy) in [(0.0, 0.0), (cell, 0), (-cell, 0), (0, cell), (0, -cell)] {
                let (p, n) = frame(spot, Double(point.x) + dx, Double(point.y) + dy)
                if shape(spot.fish.species, p, n, fins: fins(spot.fish.effort)) != nil { return spot.fish }
            }
        }
        return nil
    }

    /// Full-grown length in points, and cruising speed in points a second.
    private static func size(_ species: AquariumFish.Species) -> (Double, Double) {
        switch species {
        case .shark: (300, 15)
        case .sailfish: (260, 26)
        case .barracuda: (220, 19)
        case .minnow: (56, 24)
        case .tuna: (130, 24)
        case .angelfish: (100, 9)
        case .puffer: (86, 7)
        case .fry: (26, 18)
        case .jellyfish: (84, 0)
        }
    }

    /// Fin length for effort: small at low, long at max.
    static func fins(_ effort: Int) -> Double { [0.8, 1.0, 1.1, 1.25, 1.4][min(4, max(0, effort))] }

    /// Markings for effort: plain, faint bands at high, stripes at xhigh, spots at max.
    private static func markings(_ effort: Int, _ p: Double, _ n: Double) -> Double {
        switch effort {
        case 2: sin(p * 26) > 0.8 ? 0.6 : 1
        case 3: sin(p * 30) > 0.4 ? 0.5 : 1
        case 4...: sin(p * 46) * sin(n * 46 + 1) > 0.3 ? 0.4 : 1
        default: 1
        }
    }

    /// A point in a fish's own frame. Side view: the dorsal fin stays up whichever way it swims.
    private static func frame(_ spot: Placed, _ x: Double, _ y: Double) -> (Double, Double) {
        // Mid-turn the fish narrows (a fractional facing) instead of flipping in one frame.
        let facing = abs(spot.direction) < 0.15 ? (spot.direction < 0 ? -0.15 : 0.15) : spot.direction
        if spot.fish.species == .jellyfish {
            var p = (x - spot.x) / spot.length + 0.5
            let n = (y - spot.y) / spot.length
            if n < 0.04 { p = 0.5 + (p - 0.5) / (1 + 0.08 * sin(spot.beat)) }          // the bell breathes
            else { p += 0.05 * sin(n * 8 - spot.beat * 1.5) * min(1, n * 2.5) }      // tentacles trail and wave
            return (p, n)
        }
        let lx = (x - spot.x) / facing, py = y - spot.y
        let (cp, sp) = (cos(spot.pitch), sin(spot.pitch))
        var p = (lx * cp + py * sp) / spot.length + 0.5
        let n = (-lx * sp + py * cp) / spot.length
        // The tail beats side to side, which from the side reads as it shortening a little and back.
        if p < 0.1 { p = 0.1 - (0.1 - p) / (0.9 + 0.1 * sin(spot.beat)) }
        return (p, n)
    }

    /// Samples a fish on the grid around it.
    private static func render(_ ink: inout Ink, _ spot: Placed, layer: Int, width: Double, height: Double) {
        let species = spot.fish.species, f = fins(spot.fish.effort)
        let tall: Double = switch species {
        case .jellyfish: 1.4; case .angelfish: 0.72; case .puffer: 0.4; case .sailfish, .shark: 0.3; case .barracuda: 0.14; default: 0.22
        }
        let reachX = spot.length * 0.78, reachY = spot.length * (tall * max(1, f) + 0.65 * abs(sin(spot.pitch)))
        let c0 = max(0, Int((spot.x - reachX) / cell)), c1 = min(Int(width / cell), Int((spot.x + reachX) / cell))
        let r0 = max(0, Int((spot.y - reachY) / cell)), r1 = min(Int(height / cell), Int((spot.y + reachY) / cell))
        guard c0 <= c1, r0 <= r1 else { return }
        let grain = 0.82 + 0.18 * spot.depth
        for row in r0...r1 {
            let cy = (Double(row) + 0.5) * cell
            for col in c0...c1 {
                let (p, n) = frame(spot, (Double(col) + 0.5) * cell, cy)
                guard let solid = shape(species, p, n, fins: f) else { continue }
                ink.set(col, row, (1.2 + 2.7 * solid * markings(spot.fish.effort, p, n)) * grain, layer)
            }
        }
    }

    // MARK: Shapes
    // Side view, in body lengths: `p` runs from the tail stalk (0) to the snout (1), `n` down from
    // the midline. `fins` stretches the fins. Each returns how solid the point is, or nil outside
    // (or in the eye).

    static func shape(_ species: AquariumFish.Species, _ p: Double, _ n: Double, fins f: Double = 1) -> Double? {
        switch species {
        case .shark: shark(p, n, f)
        case .sailfish: sailfish(p, n, f)
        case .barracuda: barracuda(p, n, f)
        case .minnow: minnow(p, n, f)
        case .tuna: tuna(p, n, f)
        case .angelfish: angelfish(p, n, f)
        case .puffer: puffer(p, n, f)
        case .fry: fry(p, n)
        case .jellyfish: jellyfish(p, n, f)
        }
    }

    /// Half-heights of a streamlined body: nothing at `from` and the snout, thickest about 60% along.
    private static func body(_ p: Double, from: Double, up: Double, down: Double, blunt: Double) -> (top: Double, bottom: Double)? {
        guard p > from, p < 1 else { return nil }
        let q = (p - from) / (1 - from)
        let f = pow(sin(Double.pi * pow(q, 1.25)), blunt)
        return (up * f, down * f)
    }

    private static func inBody(_ n: Double, _ edge: (top: Double, bottom: Double)?) -> Double? {
        guard let edge, n >= -edge.top, n <= edge.bottom else { return nil }
        let mid = (edge.bottom - edge.top) / 2, half = max((edge.bottom + edge.top) / 2, 0.0001)
        return 1 - 0.6 * pow((n - mid) / half, 2)
    }

    static func shark(_ p: Double, _ n: Double, _ f: Double) -> Double? {
        if hypot(p - 0.88, n + 0.014) < 0.016 { return nil }
        if let solid = inBody(n, body(p, from: 0.06, up: 0.085, down: 0.062, blunt: 0.7)) { return solid }
        if inTriangle(p, n, (0.58, -0.06), (0.40, -0.06), (0.35, -0.06 - 0.15 * f)) { return 0.75 }   // dorsal fin
        if inTriangle(p, n, (0.19, -0.03), (0.13, -0.03), (0.11, -0.03 - 0.05 * f)) { return 0.6 }    // second dorsal
        if inTriangle(p, n, (0.68, 0.04), (0.58, 0.04), (0.46, 0.04 + 0.12 * f)) { return 0.6 }       // pectoral fin
        if inTriangle(p, n, (0.22, 0.03), (0.17, 0.03), (0.15, 0.03 + 0.045 * f)) { return 0.5 }      // anal fin
        if p >= 0, p <= 0.07, abs(n) <= 0.022 { return 0.8 }                                           // tail stalk
        if inTriangle(p, n, (0.09, -0.012), (0.02, 0.014), (-0.04 - 0.12 * f, -0.2 * f)) { return 0.7 } // long upper lobe
        if inTriangle(p, n, (0.07, 0), (0.02, 0), (-0.06 * f, 0.1 * f)) { return 0.6 }                 // short lower lobe
        return nil
    }

    static func sailfish(_ p: Double, _ n: Double, _ f: Double) -> Double? {
        if hypot(p - 0.9, n + 0.008) < 0.014 { return nil }
        if let solid = inBody(n, body(p, from: 0.07, up: 0.05, down: 0.05, blunt: 0.5)) { return solid }
        if p >= 0.97, p <= 1.24, abs(n - 0.004) <= 0.006 + 0.01 * (1.24 - p) / 0.27 { return 0.8 }   // the bill
        // The sail: a tall spined fin along most of the back, highest towards the front.
        if p > 0.28, p < 0.82, n < 0 {
            let q = (p - 0.28) / 0.54
            if -n <= 0.045 + 0.2 * f * pow(sin(Double.pi * pow(q, 0.7)), 0.8) {
                return abs((p * 60).truncatingRemainder(dividingBy: 2) - 1) < 0.35 ? 0.75 : 0.4
            }
        }
        if n > 0.05, n < 0.05 + 0.12 * f, abs(p - (0.68 - (n - 0.05) * 0.4)) < 0.012 { return 0.5 }  // pelvic streamers
        if p >= 0, p <= 0.08, abs(n) <= 0.016 { return 0.8 }
        if inTriangle(p, n, (0.08, -0.01), (0.03, 0.01), (-0.06 - 0.06 * f, -0.16 * f)) { return 0.65 }
        if inTriangle(p, n, (0.08, 0.01), (0.03, -0.01), (-0.06 - 0.06 * f, 0.16 * f)) { return 0.65 }
        return nil
    }

    static func barracuda(_ p: Double, _ n: Double, _ f: Double) -> Double? {
        if hypot(p - 0.88, n + 0.01) < 0.013 { return nil }
        if let solid = inBody(n, body(p, from: 0.07, up: 0.042, down: 0.04, blunt: 0.42)) { return solid }
        if p > 0.94, p < 1.02, n > 0, n < 0.02 { return 0.7 }                                          // jutting jaw
        if inTriangle(p, n, (0.58, -0.03), (0.51, -0.03), (0.49, -0.03 - 0.06 * f)) { return 0.6 }
        if inTriangle(p, n, (0.25, -0.03), (0.19, -0.03), (0.17, -0.03 - 0.05 * f)) { return 0.55 }
        if inTriangle(p, n, (0.25, 0.03), (0.19, 0.03), (0.17, 0.03 + 0.045 * f)) { return 0.5 }
        if p >= 0, p <= 0.08, abs(n) <= 0.016 { return 0.8 }
        if inTriangle(p, n, (0.08, -0.01), (0.03, 0.01), (-0.04 - 0.04 * f, -0.11 * f)) { return 0.6 }
        if inTriangle(p, n, (0.08, 0.01), (0.03, -0.01), (-0.04 - 0.04 * f, 0.11 * f)) { return 0.6 }
        return nil
    }

    static func minnow(_ p: Double, _ n: Double, _ f: Double) -> Double? {
        if hypot(p - 0.83, n + 0.02) < 0.035 { return nil }
        let dp = (p - 0.55) / 0.42, dn = n / 0.13
        let d = dp * dp + dn * dn
        if d <= 1 { return 1 - 0.5 * d }
        if inTriangle(p, n, (0.56, -0.1), (0.42, -0.1), (0.40, -0.1 - 0.1 * f)) { return 0.6 }
        if p > 0, p < 0.16, abs(n) < 0.02 + (0.16 - p) * 0.9 * f, abs(n) > (0.08 - p) * 0.6 { return 0.6 }   // forked tail
        return nil
    }

    static func tuna(_ p: Double, _ n: Double, _ f: Double) -> Double? {
        if hypot(p - 0.85, n + 0.016) < 0.024 { return nil }
        if let solid = inBody(n, body(p, from: 0.1, up: 0.12, down: 0.105, blunt: 0.62)) { return solid }
        if p >= 0.03, p <= 0.12, abs(n) <= 0.024 { return 0.8 }
        if inTriangle(p, n, (0.06, -0.01), (0.02, 0.012), (-0.05 - 0.06 * f, -0.18 * f)) { return 0.65 }  // crescent tail
        if inTriangle(p, n, (0.06, 0.01), (0.02, -0.012), (-0.05 - 0.06 * f, 0.18 * f)) { return 0.65 }
        if inTriangle(p, n, (0.62, -0.1), (0.48, -0.1), (0.46, -0.1 - 0.1 * f)) { return 0.6 }
        if inTriangle(p, n, (0.40, -0.06), (0.32, -0.06), (0.29, -0.06 - 0.09 * f)) { return 0.55 }
        if inTriangle(p, n, (0.40, 0.06), (0.32, 0.06), (0.29, 0.06 + 0.09 * f)) { return 0.55 }
        if inTriangle(p, n, (0.72, 0.02), (0.64, 0.03), (0.52, 0.03 + 0.06 * f)) { return 0.5 }          // pectoral
        return nil
    }

    static func angelfish(_ p: Double, _ n: Double, _ f: Double) -> Double? {
        if hypot(p - 0.79, n + 0.035) < 0.035 { return nil }
        let dp = (p - 0.55) / 0.33, dn = n / 0.27
        let d = dp * dp + dn * dn
        if d <= 1 { return (1 - 0.5 * d) * (sin((p - 0.55) * 30) > 0.55 ? 0.5 : 1) }                  // striped disc
        if p > 0.86, p < 0.95, abs(n + 0.02) < 0.035 { return 0.8 }                                    // snout
        if inTriangle(p, n, (0.66, -0.2), (0.40, -0.2), (0.14, -0.2 - 0.46 * f)) { return 0.5 }       // tall dorsal
        if inTriangle(p, n, (0.66, 0.2), (0.40, 0.2), (0.14, 0.2 + 0.46 * f)) { return 0.5 }          // tall anal
        if n > 0.24, n < 0.24 + 0.38 * f, abs(p - (0.64 - (n - 0.24) * 0.3)) < 0.014 { return 0.45 } // trailing streamer
        if p > 0.02, p < 0.25, abs(n) < 0.04 + (0.25 - p) * 0.75 * f { return 0.5 }                   // tail fan
        return nil
    }

    static func puffer(_ p: Double, _ n: Double, _ f: Double) -> Double? {
        if hypot(p - 0.74, n + 0.08) < 0.045 { return nil }                                           // big eye
        let dp = (p - 0.56) / 0.3, dn = n / 0.27
        let d = (dp * dp + dn * dn).squareRoot()
        if d <= 1 { return 1 - 0.45 * d * d }
        let a = atan2(dn, dp) * 5 / Double.pi                                                          // ten spines
        if abs(a - a.rounded()) < 0.2, d < 1 + 0.22 * f { return 0.55 }
        if p > 0.1, p < 0.27, abs(n) < 0.03 + (0.27 - p) * 0.8 * f { return 0.55 }                     // tail fan
        return nil
    }

    /// Across the bell's width, `n` down from its rim: a translucent dome with a solid edge, frilly
    /// arms in the middle and tentacles that grow longer with effort.
    static func jellyfish(_ p: Double, _ n: Double, _ f: Double) -> Double? {
        let dp = (p - 0.5) / 0.5
        if n <= 0.04, n >= -0.45 {
            let dn = min(n, 0) / 0.45
            let d = dp * dp + dn * dn
            if d <= 1 { return d > 0.6 || n > -0.05 ? 0.95 : 0.35 }
        }
        guard n > 0.04 else { return nil }
        if abs(p - 0.5) < 0.09, n < 0.04 + 0.35 * f { return 0.75 }
        let reach = 0.7 + 0.6 * f
        guard n < 0.04 + reach else { return nil }
        for strand in [0.1, 0.26, 0.74, 0.9] where abs(p - strand) < 0.04 { return 0.6 * (1 - 0.6 * (n - 0.04) / reach) }
        return nil
    }

    static func fry(_ p: Double, _ n: Double) -> Double? {
        let dp = (p - 0.58) / 0.36, dn = n / 0.17
        if dp * dp + dn * dn <= 1 { return 0.9 }
        if p > 0, p < 0.26, abs(n) < 0.03 + (0.26 - p) * 0.55 { return 0.7 }
        return nil
    }

    private static func inTriangle(_ x: Double, _ y: Double, _ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double)) -> Bool {
        func side(_ p: (Double, Double), _ q: (Double, Double)) -> Double { (x - q.0) * (p.1 - q.1) - (p.0 - q.0) * (y - q.1) }
        let d1 = side(a, b), d2 = side(b, c), d3 = side(c, a)
        return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
    }
}
