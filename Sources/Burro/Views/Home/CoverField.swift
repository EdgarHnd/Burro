// Home's backdrop as a living field drawn in grid cells, in the Maurice app's style. By default the
// aquarium (see Aquarium.swift), where your agents are the fish; also a drifting glyph weather and
// a dithered pixel version. One Canvas, a few frames a second, only while Home is on screen.
import AppKit
import SwiftUI

struct CoverField: View {
    enum Style: String, CaseIterable, Identifiable {
        case aquarium, glyphs, pixels, photo
        var id: String { rawValue }
        var title: String {
            switch self {
            case .aquarium: "Aquarium"
            case .glyphs: "Glyphs"
            case .pixels: "Pixels"
            case .photo: "Photo"
            }
        }
    }

    var style: Style = .aquarium
    /// Agents working: each one sends a crest of colour across.
    var running = 0
    /// Chats waiting on you: amber cells flicker.
    var waiting = 0
    /// The aquarium's fish: one per agent at work or waiting on you.
    var fish: [AquariumFish] = []
    /// The fish under the pointer, drawn stronger.
    var hover: AquariumHover? = nil
    /// False off screen or with Reduce Motion: the field holds still.
    var animate = true
    /// The moment drawn when the field holds still.
    var stillTime: Double = 1_000
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if style == .aquarium {
            AquariumView(fish: fish, hover: hover, animate: animate, stillTime: stillTime, ink: glyph, amber: Self.amber)
        } else {
            // A cell grid moves in whole cells, so a few frames a second read as smooth (and cost little).
            TimelineView(.animation(minimumInterval: 1.0 / 6, paused: !animate)) { timeline in
                Canvas(rendersAsynchronously: true) { context, size in
                    let t = Aquarium.time(timeline.date, animate: animate, still: stillTime)
                    if style == .pixels { drawPixels(&context, size: size, t: t) } else { drawGlyphs(&context, size: size, t: t) }
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// The weather's colour: light on a dark page, dark on a light one.
    private var glyph: Color { scheme == .dark ? .white : .black }

    // MARK: Field

    /// Drifting density, 0…1: a few slow interfering waves, so it reads as weather, not noise.
    static func density(_ x: Double, _ y: Double, _ t: Double) -> Double {
        let a = sin(x * 0.11 + t * 0.32) * cos(y * 0.23 - t * 0.21)
        let b = sin((x + y * 1.7) * 0.055 - t * 0.17)
        let c = cos((x * 0.7 - y) * 0.09 + t * 0.26)
        return min(1, max(0, 0.5 + 0.28 * a + 0.22 * b + 0.16 * c))
    }

    /// How strongly the crests light a cell, 0…1, and where along the palette it sits.
    func crest(_ x: Double, _ y: Double, cols: Double, rows: Double, t: Double) -> Double {
        let count = max(1, min(running, 4))
        let speed = running > 0 ? 0.035 : 0.018
        let width = running > 0 ? 5.0 : 3.5
        var best = 0.0
        for k in 0..<count {
            let phase = (t * speed + Double(k) / Double(count)).truncatingRemainder(dividingBy: 1)
            let front = phase * (cols + 30) - 15
            let distance = abs(x - front + (y - rows / 2) * 0.8)
            best = max(best, 1 - distance / width)
        }
        return max(0, best) * (running > 0 ? 1 : 0.55)
    }

    /// Butter gold → lime → green → violet across the cover.
    static func tint(_ position: Double) -> Color {
        let stops: [(Double, Double, Double)] = [(0.98, 0.79, 0.27), (0.78, 0.93, 0.36), (0.36, 0.82, 0.55), (0.62, 0.52, 0.98)]
        let p = min(0.999, max(0, position)) * Double(stops.count - 1)
        let i = Int(p), f = p - Double(i)
        let a = stops[i], b = stops[min(i + 1, stops.count - 1)]
        return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }
    static let amber = Color(red: 1, green: 0.62, blue: 0.2)

    /// Stable pseudo-random 0…1 per cell and tick (the same hash Maurice's cells use).
    static func hash(_ a: Int, _ b: Int, _ c: Int) -> Double {
        let h = sin(Double(a) * 127.1 + Double(b) * 311.7 + Double(c % 100_000) * 74.7) * 43758.5453
        return h - h.rounded(.down)
    }

    // MARK: Glyphs

    /// Dense to sparse, as in Maurice's ASCII figures.
    static let ramp = Array("8%XSSt%t;:")

    private static let cell = CGSize(width: 11, height: 14)
    private static let glyphFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
    /// Each monospaced glyph's advance; tracking pads it out to exactly one cell.
    private static let advance = ("0" as NSString).size(withAttributes: [.font: glyphFont]).width

    /// A row of glyphs as one string (spaces for empty cells), tracked out to the cell grid, so a
    /// frame is a few dozen text draws rather than one per cell.
    private func drawRow(_ context: inout GraphicsContext, _ characters: [Character], y: CGFloat, color: Color) {
        guard characters.contains(where: { $0 != " " }) else { return }
        let text = Text(String(characters)).font(Font(Self.glyphFont)).tracking(Self.cell.width - Self.advance).foregroundStyle(color)
        context.draw(context.resolve(text), at: CGPoint(x: (Self.cell.width - Self.advance) / 2 - 0.5, y: y), anchor: .leading)
    }

    private func drawGlyphs(_ context: inout GraphicsContext, size: CGSize, t: Double) {
        let cell = Self.cell
        let cols = Int((size.width / cell.width).rounded(.up))
        // The backdrop fades out over its last fifth; nothing there would show.
        let rows = Int((size.height * 0.82 / cell.height).rounded(.up))
        guard cols > 0, rows > 0 else { return }
        let tick = Int(t * 3)
        let shades = [0.06, 0.11, 0.18]
        let hues = 6
        var wash: [Int: Path] = [:]   // colour bucket → faint cell washes
        let flicker = waiting > 0 ? min(0.006, 0.002 * Double(waiting)) : 0
        let blank = [Character](repeating: " ", count: cols)
        var lines: [(y: CGFloat, greys: [[Character]], colored: [[Character]], amber: [Character])] = []
        lines.reserveCapacity(rows)

        for row in 0..<rows {
            var greys = [blank, blank, blank], colored = [[Character]](repeating: blank, count: hues), amber = blank
            for col in 0..<cols {
                let x = Double(col), y = Double(row)
                let rect = CGRect(x: CGFloat(col) * cell.width, y: CGFloat(row) * cell.height, width: cell.width - 1, height: cell.height - 1)
                let jitter = Self.hash(col, row, tick)
                let glyph = Self.ramp[min(9, Int(jitter * 10))]
                if flicker > 0, Self.hash(col, row, tick / 2 + 17) < flicker {
                    amber[col] = glyph
                    continue
                }
                let wave = crest(x, y, cols: Double(cols), rows: Double(rows), t: t)
                // Ragged edges, as in Maurice's pixel dissolve; colour stays in the glyphs.
                if wave > 0.2 + Self.hash(col, row, 3) * 0.35 {
                    let hue = min(hues - 1, Int(x / Double(cols) * Double(hues)))
                    colored[hue][col] = glyph
                    if wave > 0.6 { wash[hue, default: Path()].addRect(rect) }
                    continue
                }
                let d = Self.density(x, y, t)
                guard d > 0.46 else { continue }
                // Denser weather picks heavier glyphs and brighter grey.
                let heavy = min(9, max(0, Int((1 - d) * 14 + jitter * 3) - 2))
                greys[d > 0.72 ? 2 : (d > 0.56 ? 1 : 0)][col] = Self.ramp[heavy]
            }
            lines.append((CGFloat(row) * cell.height + (cell.height - 1) / 2, greys, colored, amber))
        }
        for (hue, path) in wash { context.fill(path, with: .color(Self.tint(Double(hue) / Double(hues - 1)).opacity(0.07))) }
        for line in lines {
            for (index, characters) in line.greys.enumerated() { drawRow(&context, characters, y: line.y, color: glyph.opacity(shades[index])) }
            for (hue, characters) in line.colored.enumerated() {
                drawRow(&context, characters, y: line.y, color: Self.tint(Double(hue) / Double(hues - 1)).opacity(0.55))
            }
            drawRow(&context, line.amber, y: line.y, color: Self.amber.opacity(0.8))
        }
    }

    // MARK: Pixels

    /// The same weather as dithered square pixels (an ordered 4×4 Bayer pattern).
    private func drawPixels(_ context: inout GraphicsContext, size: CGSize, t: Double) {
        let pixel: CGFloat = 5
        let cols = Int((size.width / pixel).rounded(.up)), rows = Int((size.height / pixel).rounded(.up))
        guard cols > 0, rows > 0 else { return }
        let bayer: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { ($0 + 0.5) / 16 }
        var greys = [Path](repeating: Path(), count: 3)
        var tinted: [Int: Path] = [:]
        var amber = Path()
        let tick = Int(t * 3)
        let flicker = waiting > 0 ? min(0.002, 0.0008 * Double(waiting)) : 0
        for row in 0..<rows {
            for col in 0..<cols {
                // Sample the field at glyph-cell scale so both styles share the same weather.
                let x = Double(col) * Double(pixel) / 11, y = Double(row) * Double(pixel) / 14
                let rect = CGRect(x: CGFloat(col) * pixel, y: CGFloat(row) * pixel, width: pixel - 1, height: pixel - 1)
                let threshold = bayer[(row % 4) * 4 + col % 4]
                if flicker > 0, Self.hash(col / 2, row / 2, tick / 2 + 29) < flicker { amber.addRect(rect); continue }
                let wave = crest(x, y, cols: Double(cols) * Double(pixel) / 11, rows: Double(rows) * Double(pixel) / 14, t: t)
                if wave > threshold * 0.9 + 0.1 {
                    let bucket = min(7, Int(Double(col) / Double(cols) * 8))
                    tinted[bucket, default: Path()].addRect(rect)
                    continue
                }
                let d = Self.density(x, y, t)
                let level = (d - 0.38) * 2.2
                guard level > threshold else { continue }
                greys[level > 1.2 ? 2 : (level > 0.75 ? 1 : 0)].addRect(rect)
            }
        }
        for (index, path) in greys.enumerated() { context.fill(path, with: .color(glyph.opacity([0.05, 0.09, 0.15][index]))) }
        for (bucket, path) in tinted { context.fill(path, with: .color(Self.tint(Double(bucket) / 7).opacity(0.32))) }
        context.fill(amber, with: .color(Self.amber.opacity(0.7)))
    }
}
