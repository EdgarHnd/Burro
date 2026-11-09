// Core Animation owns the motion; no timer or per-frame SwiftUI/layout updates.
import AppKit
import QuartzCore

@MainActor final class BurroMascotView: NSView {
    let mascot = CALayer()
    let plate = CALayer()
    let eyes = CAShapeLayer()
    private let bodyFill = CALayer()
    private let bodySilhouette = CALayer()
    private let plateSilhouette = CALayer()
    /// The orchestrator's sunglasses (and their glint), drawn over closed eyes.
    private let shadesLayer = CAShapeLayer()
    private let glintLayer = CAShapeLayer()
    private var shades = false
    private var active = false
    private var working = false
    private var reduceMotion = false
    private var phase: Double = 0
    private var tint: NSColor = .white
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        bodySilhouette.contents = BurroBrand.bodyImage
        plateSilhouette.contents = BurroBrand.plateImage
        bodySilhouette.contentsGravity = .resizeAspect
        plateSilhouette.contentsGravity = .resizeAspect
        bodyFill.backgroundColor = NSColor.white.cgColor
        plate.backgroundColor = NSColor.white.cgColor
        bodyFill.mask = bodySilhouette
        plate.mask = plateSilhouette
        mascot.addSublayer(bodyFill)
        shadesLayer.fillColor = NSColor(white: 0.1, alpha: 1).cgColor
        glintLayer.fillColor = nil
        glintLayer.strokeColor = NSColor(white: 1, alpha: 0.55).cgColor
        glintLayer.lineCap = .round
        shadesLayer.isHidden = true; glintLayer.isHidden = true
        mascot.addSublayer(shadesLayer)
        mascot.addSublayer(glintLayer)
        // Squash/lean around the butter's feet; the wrapper stays on the ground.
        mascot.anchorPoint = CGPoint(x: 0.54, y: 0.76)
        eyes.fillRule = .evenOdd
        eyes.fillColor = NSColor.white.cgColor
        mascot.mask = eyes
        layer?.addSublayer(plate)
        layer?.addSublayer(mascot)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    func configure(active: Bool, working: Bool, reduceMotion: Bool, tint: NSColor = .white, phase: Double = 0, shades: Bool = false) {
        if self.shades != shades {
            self.shades = shades
            stopAnimating()
            eyes.path = eyeMask(openness: 1)
            layoutShades()
        }
        self.active = active
        self.working = working
        self.reduceMotion = reduceMotion
        if self.phase != phase { stopAnimating(); self.phase = phase }
        self.tint = tint
        applyTint()
        reconcileAnimation()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }
    /// Resolve adaptive tints against this view (the notch is dark even when the app is light).
    private func applyTint() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bodyFill.backgroundColor = tint.cgColor
            plate.backgroundColor = tint.cgColor
            // A soft glow in the mascot's own colour for the orchestrator.
            layer?.shadowColor = tint.cgColor
        }
        layer?.shadowOpacity = shades ? 0.55 : 0
        layer?.shadowOffset = .zero
        layer?.shadowRadius = shades ? max(2, min(bounds.width, bounds.height) * 0.12) : 0
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        let frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        guard mascot.frame != frame else { return }
        stopAnimating()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mascot.frame = frame
        plate.frame = frame
        bodyFill.frame = mascot.bounds
        bodySilhouette.frame = mascot.bounds
        plateSilhouette.frame = plate.bounds
        eyes.frame = mascot.bounds
        eyes.path = eyeMask(openness: 1)
        layoutShades()
        mascot.contentsScale = window?.backingScaleFactor ?? 2
        eyes.contentsScale = mascot.contentsScale
        bodySilhouette.contentsScale = mascot.contentsScale
        plateSilhouette.contentsScale = mascot.contentsScale
        CATransaction.commit()
        reconcileAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
            if let clip = enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                    name: NSView.boundsDidChangeNotification, object: clip)
            }
        }
        reconcileAnimation()
    }
    override func viewDidHide() { super.viewDidHide(); reconcileAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); reconcileAnimation() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    @objc private func visibilityChanged() { reconcileAnimation() }

    func stopAnimating() {
        eyes.removeAllAnimations()
        mascot.removeAllAnimations()
    }

    private func reconcileAnimation() {
        // Modern NSView visibleRect may extend beyond its own bounds when unclipped.
        guard active, !reduceMotion, !isHiddenOrHasHiddenAncestor, bounds.intersects(visibleRect), mascot.bounds.width > 0,
              let window, window.isVisible, window.occlusionState.contains(.visible) else {
            stopAnimating()
            return
        }
        // Live activity updates must not restart the blink every time data is sampled.
        // Behind sunglasses nobody sees a blink.
        if !shades && eyes.animation(forKey: "blink") == nil {
            let blink = CAKeyframeAnimation(keyPath: "path")
            let open = eyeMask(openness: 1), closed = eyeMask(openness: 0.12)
            let glance = eyeMask(openness: 1, glance: 3)
            blink.values = [open, open, closed, open, open, glance, glance, open, open, closed, open, closed, open, open]
            blink.keyTimes = [0, 0.1, 0.115, 0.135, 0.28, 0.33, 0.40, 0.45, 0.62, 0.635, 0.655, 0.675, 0.695, 1]
            blink.duration = 12
            blink.beginTime = eyes.convertTime(CACurrentMediaTime(), from: nil) - phase * blink.duration
            blink.repeatCount = .infinity
            eyes.add(blink, forKey: "blink")
        }
        if working {
            mascot.removeAnimation(forKey: "idle")
            if mascot.animation(forKey: "hop") == nil { addMotion(BurroMascotMotion.working(size: mascot.bounds.width), key: "hop") }
        } else {
            mascot.removeAnimation(forKey: "hop")
            if mascot.animation(forKey: "idle") == nil { addMotion(BurroMascotMotion.idle(size: mascot.bounds.width), key: "idle") }
        }
    }

    private func addMotion(_ animation: CAKeyframeAnimation, key: String) {
        animation.beginTime = mascot.convertTime(CACurrentMediaTime(), from: nil) - phase * animation.duration
        mascot.add(animation, forKey: key)
    }

    /// Wayfarer-ish sunglasses over both eyes, tilted along the line between them, in the
    /// mascot's 108-unit design space.
    private func layoutShades() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        shadesLayer.isHidden = !shades; glintLayer.isHidden = !shades
        layer?.shadowOpacity = shades ? 0.55 : 0
        guard shades, mascot.bounds.width > 0, BurroBrand.eyes.count == 2 else { return }
        shadesLayer.frame = mascot.bounds; glintLayer.frame = mascot.bounds
        let scale = mascot.bounds.width / 108
        let (a, b) = (BurroBrand.eyes[0], BurroBrand.eyes[1])
        let left = CGPoint(x: a.midX, y: a.midY), right = CGPoint(x: b.midX, y: b.midY)
        let angle = atan2(right.y - left.y, right.x - left.x)
        let half = hypot(right.x - left.x, right.y - left.y) / 2
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .translatedBy(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
            .rotated(by: angle)
        let lens = CGSize(width: 13, height: 9.5)
        let frame = CGMutablePath()
        for x in [-half, half] {
            frame.addRoundedRect(in: CGRect(x: x - lens.width / 2, y: -lens.height / 2 + 0.5, width: lens.width, height: lens.height),
                                 cornerWidth: 3.6, cornerHeight: 4.2, transform: transform)
        }
        let bridge = half - lens.width / 2 + 0.6
        frame.addRect(CGRect(x: -bridge, y: -lens.height / 2 + 0.5, width: bridge * 2, height: 2.4), transform: transform)
        // Arms toward the edges of the butter.
        frame.addRect(CGRect(x: -half - lens.width / 2 - 4, y: -lens.height / 2 + 0.5, width: 4.6, height: 2), transform: transform)
        frame.addRect(CGRect(x: half + lens.width / 2 - 0.6, y: -lens.height / 2 + 0.5, width: 4.6, height: 2), transform: transform)
        shadesLayer.path = frame
        let glint = CGMutablePath()
        for x in [-half, half] {
            glint.move(to: CGPoint(x: x - 3.6, y: -1.4), transform: transform)
            glint.addLine(to: CGPoint(x: x - 1.2, y: -3.2), transform: transform)
        }
        glintLayer.path = glint
        glintLayer.lineWidth = max(0.6, 1.3 * scale)
    }

    // Both states have identical path topology so Core Animation can interpolate the blink.
    func eyeMask(openness: CGFloat, glance: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        path.addRect(mascot.bounds)
        // With sunglasses on, the eyes stay closed so the lenses aren't cut out by them.
        if shades { return path }
        let scale = mascot.bounds.width / 108
        for eye in BurroBrand.eyes {
            let height = eye.height * openness
            path.addEllipse(in: CGRect(x: (eye.minX + glance) * scale, y: (eye.midY - height / 2) * scale,
                                      width: eye.width * scale, height: height * scale))
        }
        return path
    }
}
