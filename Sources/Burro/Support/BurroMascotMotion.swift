import QuartzCore

// Coordinates are in the original 108-point artwork. Even the highest jump stays
// inside the avatar, so rows and the notch header never need extra space.
enum BurroMascotMotion {
    static func working(size: CGFloat) -> CAKeyframeAnimation {
        animation(duration: 14, poses: [
            Pose(0), Pose(0.025, sx: 1.09, sy: 0.89),
            Pose(0.055, y: -14, angle: -0.06, sx: 0.96, sy: 1.03),
            Pose(0.095, sx: 1.10, sy: 0.88), Pose(0.115, y: -3), Pose(0.14),
            Pose(0.36), Pose(0.39, angle: -0.07), Pose(0.43, angle: 0.06), Pose(0.47),
            Pose(0.67), Pose(0.695, sx: 1.07, sy: 0.91),
            Pose(0.72, y: -12, angle: 0.05), Pose(0.75, sx: 1.08, sy: 0.91),
            Pose(0.772, y: -8, angle: -0.04), Pose(0.80, sx: 1.06, sy: 0.94),
            Pose(0.82), Pose(1)
        ], size: size)
    }

    static func idle(size: CGFloat) -> CAKeyframeAnimation {
        animation(duration: 18, poses: [
            Pose(0), Pose(0.24), Pose(0.28, angle: -0.05), Pose(0.34, angle: -0.05),
            Pose(0.38), Pose(0.67), Pose(0.71, sx: 1.03, sy: 0.97), Pose(0.77), Pose(1)
        ], size: size)
    }

    private struct Pose {
        let time: Double
        var y: CGFloat = 0
        var angle: CGFloat = 0
        var sx: CGFloat = 1
        var sy: CGFloat = 1
        init(_ time: Double, y: CGFloat = 0, angle: CGFloat = 0, sx: CGFloat = 1, sy: CGFloat = 1) {
            self.time = time; self.y = y; self.angle = angle; self.sx = sx; self.sy = sy
        }
        func transform(size: CGFloat) -> CATransform3D {
            let translated = CATransform3DMakeTranslation(0, y * size / 108, 0)
            return CATransform3DScale(CATransform3DRotate(translated, angle, 0, 0, 1), sx, sy, 1)
        }
    }

    private static func animation(duration: Double, poses: [Pose], size: CGFloat) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = poses.map { NSValue(caTransform3D: $0.transform(size: size)) }
        animation.keyTimes = poses.map { NSNumber(value: $0.time) }
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: poses.count - 1)
        animation.duration = duration
        animation.repeatCount = .infinity
        return animation
    }
}
