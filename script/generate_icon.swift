// Render Burro's white vector butter mascot on charcoal at native macOS icon resolutions.
import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let mascotURL = URL(fileURLWithPath: "Sources/Burro/Resources/Brand/butter.pdf")
guard let mascot = NSImage(contentsOf: mascotURL) else { fatalError("Missing butter.pdf; run swift script/generate_brand.swift") }
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        // Explicit pixels keep iconutil's 1x/2x representations independent of the current screen scale.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        let shape = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 212, yRadius: 212)
        NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1),
                   ending: NSColor(srgbRed: 0.035, green: 0.035, blue: 0.04, alpha: 1))!.draw(in: shape, angle: -90)
        mascot.draw(in: NSRect(x: 132, y: 132, width: 760, height: 760), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
