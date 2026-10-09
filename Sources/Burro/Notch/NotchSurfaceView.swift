// Core Animation owns the changing outline/fades; two fixed SwiftUI hosts own accessible content.
import AppKit
import QuartzCore
import SwiftUI
import BurroCore

@MainActor final class NotchSurfaceView: NSView {
    let background = CAShapeLayer()
    private let surfaceMask = CAShapeLayer()
    let glassBackdrop = NotchGlassView(frame: .zero)
    private let glassMask = CAShapeLayer()
    private let reduceTransparency: () -> Bool
    let attentionGlow = CAShapeLayer()
    private let glowContainer = CALayer()
    private let glowClip = CAShapeLayer()
    private let glowFade = CAGradientLayer()
    private(set) var attention: AgentAttention = .none
    private var attentionAnimated = false
    private let content = FlippedNotchView()
    private let compactHost: NSHostingView<NotchView>
    private let expandedHost: NSHostingView<NotchView>
    private var compactSize = CGSize(width: 108, height: 26)
    private var expandedSize = CGSize(width: 480, height: 373)
    private var motion = NotchMotion()
    private var generation = UUID()
    private(set) var isAnimating = false
    private var expanded = false
    override var isFlipped: Bool { true }

    init(compact: NotchView, expanded: NotchView,
         reduceTransparency: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }) {
        self.reduceTransparency = reduceTransparency
        compactHost = NSHostingView(rootView: compact)
        expandedHost = NSHostingView(rootView: expanded)
        super.init(frame: .zero)
        wantsLayer = true
        background.fillColor = NSColor.black.cgColor
        layer?.addSublayer(background)
        addSubview(glassBackdrop)
        glassBackdrop.layer?.mask = glassMask
        glassBackdrop.layer?.opacity = 0
        glassBackdrop.isHidden = true
        // An inner rim leaves the window and hover footprint unchanged. The top edge stays black.
        layer?.addSublayer(glowContainer)
        glowContainer.mask = glowClip
        glowContainer.addSublayer(attentionGlow)
        attentionGlow.fillColor = NSColor.clear.cgColor
        attentionGlow.strokeColor = NSColor.systemBlue.cgColor
        attentionGlow.shadowColor = NSColor.systemBlue.cgColor
        attentionGlow.lineWidth = 2
        attentionGlow.shadowRadius = 7
        attentionGlow.shadowOffset = .zero
        attentionGlow.shadowOpacity = 1
        attentionGlow.opacity = 0
        attentionGlow.mask = glowFade
        glowFade.colors = [NSColor.clear.cgColor, NSColor.white.cgColor]
        glowFade.locations = [0.25, 1]
        glowFade.startPoint = CGPoint(x: 0.5, y: 0)
        glowFade.endPoint = CGPoint(x: 0.5, y: 1)
        content.wantsLayer = true
        addSubview(content)
        content.layer?.mask = surfaceMask
        for host in [compactHost, expandedHost] {
            host.safeAreaRegions = []
            host.sizingOptions = []
            host.wantsLayer = true
            content.addSubview(host)
        }
    }
    required init?(coder: NSCoder) { nil }

    func setContentSizes(compact: CGSize, expanded: CGSize) {
        guard compactSize != compact || expandedSize != expanded else { return }
        compactSize = compact; expandedSize = expanded
        needsLayout = true
    }
    override func layout() {
        super.layout()
        withoutActions {
            content.frame = bounds
            compactHost.frame = CGRect(x: (bounds.width - compactSize.width) / 2, y: 0,
                                       width: compactSize.width, height: compactSize.height)
            expandedHost.frame = CGRect(x: (bounds.width - expandedSize.width) / 2, y: 0,
                                        width: expandedSize.width, height: expandedSize.height)
            background.frame = bounds
            surfaceMask.frame = content.bounds
            glassBackdrop.frame = bounds
            glassMask.frame = bounds
            glowContainer.frame = bounds; glowClip.frame = bounds
            attentionGlow.frame = bounds
            let compactRect = CGRect(x: (bounds.width - compactSize.width) / 2, y: 0,
                                     width: compactSize.width, height: compactSize.height)
            let glowPath = outline(size: compactSize, expansion: 0)
            glowClip.path = glowPath; attentionGlow.path = glowPath
            glowFade.frame = compactRect
            if !isAnimating { setModel(motion.sample(at: CACurrentMediaTime())) }
        }
    }
    func transition(size: CGSize, expanded: Bool, animated: Bool, completion: @escaping @MainActor () -> Void) {
        let now = CACurrentMediaTime()
        motion.retarget(size: size, expanded: expanded, at: now, animated: animated)
        self.expanded = expanded
        let id = UUID(); generation = id
        isAnimating = animated
        updateAttentionGlow(animated: animated && attentionAnimated)
        layoutSubtreeIfNeeded()
        compactHost.setAccessibilityHidden(expanded)
        expandedHost.setAccessibilityHidden(!expanded)
        let layers: [CALayer] = [background, surfaceMask, glassMask, glassBackdrop.layer!, compactHost.layer!, expandedHost.layer!]
        let end = motion.sample(at: now + motion.duration)
        guard animated else {
            withoutActions {
                layers.forEach { $0.removeAllAnimations() }
                setModel(end)
            }
            completion()
            return
        }

        // Keyframes carry an analytic spring's position AND velocity across reversals. The render
        // server interpolates them at its own refresh rate; no SwiftUI/window layout runs per frame.
        let count = max(2, Int(ceil(motion.duration * 120)))
        let samples = (0...count).map { motion.sample(at: now + motion.duration * Double($0) / Double(count)) }
        let paths = samples.map { outline($0) }
        let times = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
        func animation(_ key: String, values: [Any]) -> CAKeyframeAnimation {
            let result = CAKeyframeAnimation(keyPath: key)
            result.values = values; result.keyTimes = times
            result.duration = motion.duration
            result.beginTime = now
            result.calculationMode = .linear
            return result
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.isAnimating = false
                self.glassBackdrop.isHidden = !self.expanded || self.reduceTransparency()
                self.updateAttentionGlow(animated: self.attentionAnimated)
                completion()
            }
        }
        setModel(end)
        background.add(animation("path", values: paths), forKey: "notch.path")
        surfaceMask.add(animation("path", values: paths), forKey: "notch.path")
        glassMask.add(animation("path", values: paths), forKey: "notch.path")
        glassBackdrop.layer?.add(animation("opacity", values: samples.map { glassOpacity($0.expansion) }), forKey: "notch.glass")
        background.add(animation("opacity", values: samples.map { 1 - glassOpacity($0.expansion) }), forKey: "notch.glass")
        compactHost.layer?.add(animation("opacity", values: samples.map { compactOpacity($0.expansion) }), forKey: "notch.fade")
        expandedHost.layer?.add(animation("opacity", values: samples.map { expandedOpacity($0.expansion) }), forKey: "notch.fade")
        expandedHost.layer?.add(animation("transform.translation.y", values: samples.map { -6 * (1 - $0.expansion) }), forKey: "notch.lift")
        CATransaction.commit()
    }
    func setAttention(_ attention: AgentAttention, animated: Bool) {
        let changed = self.attention != attention
        self.attention = attention; attentionAnimated = animated
        if changed || !animated { updateAttentionGlow(animated: animated) }
    }
    private func updateAttentionGlow(animated: Bool) {
        let color = attention == .waiting ? NSColor(NotchStyle.attention) : NSColor.systemBlue
        let opacity: Float = attention != .none && !expanded && !isAnimating ? 1 : 0
        let visible = attentionGlow.presentation() ?? attentionGlow
        let oldOpacity = visible.opacity
        let oldColor = visible.strokeColor
        let oldShadow = visible.shadowColor
        withoutActions {
            attentionGlow.removeAllAnimations()
            attentionGlow.strokeColor = color.cgColor
            attentionGlow.shadowColor = color.cgColor
            attentionGlow.opacity = opacity
        }
        guard animated else { return }
        for (key, from, to) in [("opacity", oldOpacity as Any, opacity as Any),
                                ("strokeColor", oldColor as Any, color.cgColor as Any),
                                ("shadowColor", oldShadow as Any, color.cgColor as Any)] {
            let fade = CABasicAnimation(keyPath: key)
            fade.fromValue = from; fade.toValue = to; fade.duration = 0.22
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            attentionGlow.add(fade, forKey: "attention." + key)
        }
    }
    func cancel() {
        generation = UUID(); isAnimating = false
        withoutActions { [background, surfaceMask, glassMask, glassBackdrop.layer, attentionGlow, compactHost.layer, expandedHost.layer].forEach { $0?.removeAllAnimations() } }
    }
    func updateGlassAccessibility() {
        withoutActions {
            glassBackdrop.layer?.removeAnimation(forKey: "notch.glass")
            background.removeAnimation(forKey: "notch.glass")
            let opacity = glassOpacity(expanded ? 1 : 0)
            glassBackdrop.layer?.opacity = Float(opacity)
            background.opacity = Float(1 - opacity)
            glassBackdrop.isHidden = opacity == 0
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Layer opacity does not control NSView hit testing. Route only to the intended content.
        let local = convert(point, from: superview)
        let host = expanded ? expandedHost : compactHost
        return host.hitTest(content.convert(local, from: self))
    }
    private func setModel(_ sample: NotchMotion.Sample) {
        let path = outline(sample)
        background.path = path; surfaceMask.path = path; glassMask.path = path
        let glass = glassOpacity(sample.expansion)
        glassBackdrop.layer?.opacity = Float(glass)
        background.opacity = Float(1 - glass)
        glassBackdrop.isHidden = reduceTransparency() || (!expanded && !isAnimating)
        compactHost.layer?.opacity = Float(compactOpacity(sample.expansion))
        expandedHost.layer?.opacity = Float(expandedOpacity(sample.expansion))
        expandedHost.layer?.transform = CATransform3DMakeTranslation(0, -6 * (1 - sample.expansion), 0)
    }
    private func compactOpacity(_ progress: Double) -> Double { max(0, 1 - progress * 3) }
    private func glassOpacity(_ progress: Double) -> Double { reduceTransparency() ? 0 : expandedOpacity(progress) }
    private func expandedOpacity(_ progress: Double) -> Double { max(0, (progress - 0.12) / 0.88) }
    private func outline(_ sample: NotchMotion.Sample) -> CGPath {
        outline(size: sample.size, expansion: sample.expansion)
    }
    private func outline(size: CGSize, expansion: Double) -> CGPath {
        let rect = CGRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height)
        let shoulder = min(8.0, rect.height / 3)
        let radius = min(10 + 16 * expansion, (rect.height - shoulder) / 2)
        let left = rect.minX + shoulder, right = rect.maxX - shoulder
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.minY + shoulder), control: CGPoint(x: right, y: rect.minY))
        path.addLine(to: CGPoint(x: right, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: right - radius, y: rect.maxY), control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: left + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.maxY - radius), control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: left, y: rect.minY + shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: left, y: rect.minY))
        path.closeSubpath()
        return path
    }
    private func withoutActions(_ action: () -> Void) {
        CATransaction.begin(); CATransaction.setDisableActions(true); action(); CATransaction.commit()
    }
}
private final class FlippedNotchView: NSView {
    override var isFlipped: Bool { true }
}
