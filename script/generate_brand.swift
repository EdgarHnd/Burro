// Original Burro vector marks. One geometry source exports transparent app assets and design previews.
import AppKit
import CoreGraphics
import Foundation

let artDirectory = URL(fileURLWithPath: "Resources/Brand")
let bundleDirectory = URL(fileURLWithPath: "Sources/Burro/Resources/Brand")
try FileManager.default.createDirectory(at: artDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)

let butterEyes = [CGRect(x: 32, y: 48, width: 7, height: 11), CGRect(x: 49, y: 51, width: 7, height: 11)]
func butterBody() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 23, y: 40))
    p.addCurve(to: CGPoint(x: 32, y: 28), control1: CGPoint(x: 23, y: 34), control2: CGPoint(x: 26, y: 30))
    p.addLine(to: CGPoint(x: 49, y: 21))
    p.addCurve(to: CGPoint(x: 62, y: 20), control1: CGPoint(x: 54, y: 19), control2: CGPoint(x: 57, y: 19))
    p.addLine(to: CGPoint(x: 82, y: 24))
    p.addCurve(to: CGPoint(x: 93, y: 37), control1: CGPoint(x: 90, y: 25), control2: CGPoint(x: 93, y: 29))
    p.addLine(to: CGPoint(x: 93, y: 57))
    p.addCurve(to: CGPoint(x: 86, y: 67), control1: CGPoint(x: 93, y: 62), control2: CGPoint(x: 91, y: 64))
    p.addLine(to: CGPoint(x: 63, y: 80))
    p.addCurve(to: CGPoint(x: 54, y: 82), control1: CGPoint(x: 60, y: 82), control2: CGPoint(x: 57, y: 83))
    p.addLine(to: CGPoint(x: 31, y: 77))
    p.addCurve(to: CGPoint(x: 23, y: 67), control1: CGPoint(x: 25, y: 76), control2: CGPoint(x: 23, y: 73))
    p.closeSubpath()
    return p
}
func butterPlate() -> CGPath {
    let p = CGMutablePath()
    // A single folded wrapper, with a generous gap that survives small sizes.
    p.move(to: CGPoint(x: 7, y: 53))
    p.addCurve(to: CGPoint(x: 5, y: 59), control1: CGPoint(x: 3, y: 51), control2: CGPoint(x: 3, y: 54))
    p.addLine(to: CGPoint(x: 13, y: 79))
    p.addCurve(to: CGPoint(x: 25, y: 89), control1: CGPoint(x: 16, y: 86), control2: CGPoint(x: 19, y: 87))
    p.addLine(to: CGPoint(x: 52, y: 96))
    p.addCurve(to: CGPoint(x: 65, y: 94), control1: CGPoint(x: 58, y: 97), control2: CGPoint(x: 60, y: 97))
    p.addLine(to: CGPoint(x: 92, y: 79))
    p.addCurve(to: CGPoint(x: 100, y: 69), control1: CGPoint(x: 97, y: 76), control2: CGPoint(x: 98, y: 73))
    p.addLine(to: CGPoint(x: 105, y: 57))
    p.addCurve(to: CGPoint(x: 102, y: 53), control1: CGPoint(x: 107, y: 53), control2: CGPoint(x: 105, y: 51))
    p.addLine(to: CGPoint(x: 97, y: 56))
    p.addLine(to: CGPoint(x: 97, y: 60))
    p.addCurve(to: CGPoint(x: 89, y: 71), control1: CGPoint(x: 97, y: 65), control2: CGPoint(x: 94, y: 68))
    p.addLine(to: CGPoint(x: 65, y: 85))
    p.addCurve(to: CGPoint(x: 53, y: 88), control1: CGPoint(x: 61, y: 88), control2: CGPoint(x: 58, y: 89))
    p.addLine(to: CGPoint(x: 29, y: 83))
    p.addCurve(to: CGPoint(x: 18, y: 69), control1: CGPoint(x: 22, y: 82), control2: CGPoint(x: 19, y: 77))
    p.addLine(to: CGPoint(x: 17, y: 60))
    p.closeSubpath()
    return p
}
func butter() -> CGPath {
    let p = CGMutablePath()
    p.addPath(butterBody())
    p.addPath(butterPlate())
    for eye in butterEyes { p.addEllipse(in: eye) }
    return p
}
func abstract() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 19, y: 80))
    p.addCurve(to: CGPoint(x: 30, y: 33), control1: CGPoint(x: 13, y: 68), control2: CGPoint(x: 21, y: 46))
    p.addCurve(to: CGPoint(x: 59, y: 18), control1: CGPoint(x: 40, y: 18), control2: CGPoint(x: 51, y: 13))
    p.addCurve(to: CGPoint(x: 64, y: 32), control1: CGPoint(x: 66, y: 21), control2: CGPoint(x: 69, y: 27))
    p.addCurve(to: CGPoint(x: 66, y: 39), control1: CGPoint(x: 60, y: 35), control2: CGPoint(x: 62, y: 37))
    p.addCurve(to: CGPoint(x: 93, y: 75), control1: CGPoint(x: 81, y: 42), control2: CGPoint(x: 90, y: 57))
    p.addCurve(to: CGPoint(x: 78, y: 90), control1: CGPoint(x: 96, y: 87), control2: CGPoint(x: 89, y: 90))
    p.addCurve(to: CGPoint(x: 56, y: 83), control1: CGPoint(x: 67, y: 90), control2: CGPoint(x: 64, y: 83))
    p.addCurve(to: CGPoint(x: 36, y: 90), control1: CGPoint(x: 48, y: 83), control2: CGPoint(x: 47, y: 90))
    p.addCurve(to: CGPoint(x: 19, y: 80), control1: CGPoint(x: 26, y: 90), control2: CGPoint(x: 22, y: 88))
    p.closeSubpath()
    p.addEllipse(in: CGRect(x: 38, y: 54, width: 7, height: 11))
    p.addEllipse(in: CGRect(x: 61, y: 54, width: 7, height: 11))
    return p
}
func draw(_ path: CGPath, in context: CGContext, size: CGFloat) {
    context.saveGState()
    context.scaleBy(x: size / 108, y: size / 108)
    context.translateBy(x: 0, y: 108)
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.addPath(path)
    context.drawPath(using: .eoFill)
    context.restoreGState()
}
func svg(_ path: CGPath) -> String {
    var d: [String] = []
    func point(_ p: CGPoint) -> String { "\(p.x) \(p.y)" }
    path.applyWithBlock { raw in
        let e = raw.pointee
        switch e.type {
        case .moveToPoint: d.append("M" + point(e.points[0]))
        case .addLineToPoint: d.append("L" + point(e.points[0]))
        case .addQuadCurveToPoint: d.append("Q" + point(e.points[0]) + " " + point(e.points[1]))
        case .addCurveToPoint: d.append("C" + point(e.points[0]) + " " + point(e.points[1]) + " " + point(e.points[2]))
        case .closeSubpath: d.append("Z")
        @unknown default: break
        }
    }
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 108 108\"><path fill=\"white\" fill-rule=\"evenodd\" d=\"\(d.joined(separator: " "))\"/></svg>\n"
}
func writePDF(_ path: CGPath, name: String) {
    var box = CGRect(x: 0, y: 0, width: 108, height: 108)
    let pdf = CGContext(bundleDirectory.appendingPathComponent(name + ".pdf") as CFURL, mediaBox: &box, nil)!
    pdf.beginPDFPage(nil); draw(path, in: pdf, size: 108); pdf.endPDFPage(); pdf.closePDF()
}
// The animated mark cuts its eyes out with a layer mask, using these same coordinates.
writePDF(butterBody(), name: "butter-body")
writePDF(butterPlate(), name: "butter-plate")
try JSONEncoder().encode(butterEyes).write(to: bundleDirectory.appendingPathComponent("butter-eyes.json"))
for (name, path) in [("butter", butter()), ("abstract", abstract())] {
    writePDF(path, name: name)
    try svg(path).write(to: artDirectory.appendingPathComponent(name + ".svg"), atomically: true, encoding: .utf8)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    draw(path, in: context, size: 512)
    try bitmap.representation(using: .png, properties: [:])!.write(to: artDirectory.appendingPathComponent(name + ".png"))
}
// Review both options on the app's actual dark surface, including their real UI sizes.
let preview = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1080, pixelsHigh: 540,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: preview)
let context = NSGraphicsContext.current!.cgContext
context.setFillColor(NSColor(srgbRed: 0.07, green: 0.07, blue: 0.07, alpha: 1).cgColor)
context.fill(CGRect(x: 0, y: 0, width: 1080, height: 540))
for (index, item) in [("Butter", butter()), ("Abstract", abstract())].enumerated() {
    let x = CGFloat(index) * 520 + 30
    let card = NSBezierPath(roundedRect: CGRect(x: x, y: 30, width: 500, height: 480), xRadius: 28, yRadius: 28)
    NSColor(srgbRed: 0.14, green: 0.14, blue: 0.14, alpha: 1).setFill(); card.fill()
    NSAttributedString(string: item.0, attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.white]).draw(at: CGPoint(x: x + 30, y: 460))
    context.saveGState(); context.translateBy(x: x + 125, y: 174); draw(item.1, in: context, size: 250); context.restoreGState()
    for (i, size) in [CGFloat(18), 22, 32].enumerated() {
        context.saveGState(); context.translateBy(x: x + 150 + CGFloat(i) * 78, y: 105); draw(item.1, in: context, size: size); context.restoreGState()
        NSAttributedString(string: "\(Int(size)) pt", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 0.55, alpha: 1)]).draw(at: CGPoint(x: x + 145 + CGFloat(i) * 78, y: 72))
    }
}
NSGraphicsContext.restoreGraphicsState()
try preview.representation(using: .png, properties: [:])!.write(to: artDirectory.appendingPathComponent("comparison.png"))
