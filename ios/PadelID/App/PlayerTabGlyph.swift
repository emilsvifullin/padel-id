import UIKit

@MainActor
enum PlayerTabGlyph {
    case calendar, membership, settings

    private static let center: CGFloat = 14
    private static let size = CGSize(width: center * 2, height: center * 2)
    private static let renderer: UIGraphicsImageRenderer = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: size, format: format)
    }()
    private static let calendarImage = Self.calendar.render(progress: 1).withRenderingMode(.alwaysTemplate)
    private static let membershipImage = Self.membership.render(progress: 1).withRenderingMode(.alwaysTemplate)
    private static let settingsImage = Self.settings.render(progress: 1).withRenderingMode(.alwaysTemplate)

    var image: UIImage {
        switch self {
        case .calendar: Self.calendarImage
        case .membership: Self.membershipImage
        case .settings: Self.settingsImage
        }
    }

    func render(progress: CGFloat) -> UIImage {
        Self.renderer.image { renderer in
            let context = renderer.cgContext
            context.setFillColor(UIColor.white.cgColor)
            context.setStrokeColor(UIColor.white.cgColor)
            let lift = smooth(min(1, progress / 0.38)) * smooth(min(1, (1 - progress) / 0.62))
            switch self {
            case .calendar:
                drawCalendar(in: context, lift: lift)
            case .membership:
                drawMembership(in: context, lift: lift)
            case .settings:
                drawSettings(in: context, turn: smooth(progress))
            }
        }
    }

    private func drawCalendar(in context: CGContext, lift: CGFloat) {
        let frame = CGRect(x: 2.6, y: 5, width: 22.8, height: 20.8)
        let hinge: CGFloat = 11
        let corners = CGSize(width: 4.3, height: 4.3)

        let header = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: hinge - frame.minY)
        context.addPath(UIBezierPath(roundedRect: header, byRoundingCorners: [.topLeft, .topRight],
                                     cornerRadii: corners).cgPath)
        context.fillPath()
        for x: CGFloat in [7.6, 17.5] {
            fillRoundedRect(CGRect(x: x, y: 2.2, width: 2.9, height: 5.7), radius: 1.45, in: context)
        }

        // The page bends at the binding while the header stays fixed.
        let pageTop = hinge + 1.65
        context.saveGState()
        context.translateBy(x: 0, y: pageTop)
        context.scaleBy(x: 1, y: 1 - 0.32 * lift)
        let page = CGRect(x: frame.minX, y: 0, width: frame.width, height: frame.maxY - pageTop)
        context.addPath(UIBezierPath(roundedRect: page, byRoundingCorners: [.bottomLeft, .bottomRight],
                                     cornerRadii: corners).cgPath)
        context.fillPath()
        context.setBlendMode(.clear)
        for y: CGFloat in [2.35, 8.1] {
            for x: CGFloat in [7, 12.7, 18.4] {
                fillRoundedRect(CGRect(x: x, y: y, width: 2.6, height: 2.6), radius: 0.8, in: context)
            }
        }
        context.restoreGState()
    }

    private func drawMembership(in context: CGContext, lift: CGFloat) {
        context.translateBy(x: Self.center, y: Self.center - 1.5 * lift)
        context.rotate(by: -0.24 * lift)

        let ticket = CGRect(x: -12.3, y: -8.5, width: 24.6, height: 17)
        fillRoundedRect(ticket, radius: 3.8, in: context)
        context.setBlendMode(.clear)
        for edge in [ticket.minX, ticket.maxX] {
            context.fillEllipse(in: CGRect(x: edge - 2.5, y: -2.5, width: 5, height: 5))
        }
        for y: CGFloat in [-5.8, -1.5, 2.8] {
            fillRoundedRect(CGRect(x: 3.2, y: y, width: 1.9, height: 3), radius: 0.95, in: context)
        }
    }

    private func drawSettings(in context: CGContext, turn: CGFloat) {
        context.translateBy(x: Self.center, y: Self.center)

        let toothCount = 12
        let toothAngle = 2 * CGFloat.pi / CGFloat(toothCount)
        context.saveGState()
        context.rotate(by: 2 * toothAngle * turn)
        context.fillEllipse(in: CGRect(x: -10.7, y: -10.7, width: 21.4, height: 21.4))
        for _ in 0..<toothCount {
            fillRoundedRect(CGRect(x: -0.95, y: -12.85, width: 1.9, height: 3.6), radius: 0.95, in: context)
            context.rotate(by: toothAngle)
        }
        context.setBlendMode(.clear)
        context.fillEllipse(in: CGRect(x: -7.8, y: -7.8, width: 15.6, height: 15.6))
        context.restoreGState()

        let spokeAngle = 2 * CGFloat.pi / 3
        context.rotate(by: -spokeAngle * turn)
        context.setLineCap(.round)
        context.setLineWidth(2.15)
        for _ in 0..<3 {
            context.move(to: .zero)
            context.addLine(to: CGPoint(x: 8.1, y: 0))
            context.strokePath()
            context.rotate(by: spokeAngle)
        }
    }

    private func fillRoundedRect(_ rect: CGRect, radius: CGFloat, in context: CGContext) {
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    private func smooth(_ progress: CGFloat) -> CGFloat {
        progress * progress * (3 - 2 * progress)
    }
}

@MainActor
final class PlayerTabMotion: NSObject {
    private final class Mount {
        weak var icon: UIImageView?
        let overlay: CALayer
        init(icon: UIImageView, overlay: CALayer) {
            self.icon = icon
            self.overlay = overlay
        }
    }

    private static let hideKey = "tennisTabGlyphHidden"
    private static let duration: TimeInterval = 0.56
    private var mounts: [Mount] = []
    private var displayLink: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var glyph: PlayerTabGlyph = .calendar
    private(set) var activation: Int?

    func prepare(activation: Int) {
        stop()
        self.activation = activation
    }

    func play(_ glyph: PlayerTabGlyph, over icons: [UIImageView], activation: Int) {
        guard self.activation == activation, displayLink == nil else { return }
        self.glyph = glyph
        let image = glyph.image.cgImage
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for icon in icons {
            guard let parent = icon.layer.superlayer else { continue }
            let overlay = CALayer()
            overlay.frame = icon.layer.frame
            overlay.contents = image
            overlay.contentsGravity = .resizeAspect
            overlay.contentsScale = glyph.image.scale
            parent.insertSublayer(overlay, above: icon.layer)
            let hide = CABasicAnimation(keyPath: "opacity")
            hide.fromValue = 0
            hide.toValue = 0
            hide.duration = Self.duration + 0.1
            icon.layer.add(hide, forKey: Self.hideKey)
            mounts.append(Mount(icon: icon, overlay: overlay))
        }
        CATransaction.commit()

        guard !mounts.isEmpty else { return }
        start = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(draw(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for mount in mounts {
            mount.icon?.layer.removeAnimation(forKey: Self.hideKey)
            mount.overlay.removeFromSuperlayer()
        }
        mounts.removeAll()
        CATransaction.commit()
        activation = nil
    }

    @objc private func draw(_ link: CADisplayLink) {
        let progress = CGFloat(min(1, max(0, (link.targetTimestamp - start) / Self.duration)))
        guard progress < 1 else {
            stop()
            return
        }
        let image = glyph.render(progress: progress).cgImage
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for mount in mounts {
            mount.overlay.contents = image
        }
        CATransaction.commit()
    }
}
