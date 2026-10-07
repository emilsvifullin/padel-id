import SwiftUI

/// Hexagonal Padel DNA shape. Each axis shows a dimension's offset from the
/// player's overall level; the dashed ring is the overall level itself.
struct DNAHexagon: View {
    let dimensions: [DNADimensionState]
    var comparison: [DNADimensionState]? = nil
    var showLabels = true

    private static let reference: CGFloat = 0.6

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let labelInset: CGFloat = showLabels ? 34 : 4
            let radius = max(10, size / 2 - labelInset)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                Canvas { context, _ in
                    drawGrid(context: &context, center: center, radius: radius)
                    if let comparison, comparison.count == 6 {
                        let path = polygon(values: ordered(comparison), center: center, radius: radius)
                        context.stroke(path, with: .color(.secondary.opacity(0.7)),
                                       style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                    let values = ordered(dimensions)
                    guard values.count == 6 else { return }
                    let shape = polygon(values: values, center: center, radius: radius)
                    context.fill(shape, with: .linearGradient(
                        Gradient(colors: [Theme.accent.opacity(0.35), Theme.ball.opacity(0.25)]),
                        startPoint: CGPoint(x: center.x, y: center.y - radius),
                        endPoint: CGPoint(x: center.x, y: center.y + radius)))
                    context.stroke(shape, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    for (index, state) in values.enumerated() {
                        let point = vertex(index: index, fraction: fraction(state.offset), center: center, radius: radius)
                        let dot = Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
                        if state.confidence >= 0.5 {
                            context.fill(dot, with: .color(Theme.accent))
                        } else {
                            context.fill(dot, with: .color(Color(.systemBackground)))
                            context.stroke(dot, with: .color(Theme.accent), lineWidth: 1.5)
                        }
                    }
                }
                if showLabels {
                    ForEach(Array(DNADimension.allCases.enumerated()), id: \.offset) { index, dimension in
                        let point = vertex(index: index, fraction: 1, center: center, radius: radius + 20)
                        HStack(spacing: 2) {
                            Text(dimension.shortTitle)
                            if isVerified(dimension) {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.accent)
                            }
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(point)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Padel DNA")
        .accessibilityValue(accessibilitySummary)
    }

    private func ordered(_ states: [DNADimensionState]) -> [DNADimensionState] {
        DNADimension.allCases.compactMap { dimension in states.first { $0.dimension == dimension } }
    }

    private func isVerified(_ dimension: DNADimension) -> Bool {
        dimensions.first { $0.dimension == dimension }?.coachVerifiedAt != nil
    }

    private func fraction(_ offset: Double) -> CGFloat {
        min(1, max(0.12, Self.reference + CGFloat(offset) * 0.8))
    }

    private func vertex(index: Int, fraction: CGFloat, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = (-90 + Double(index) * 60) * .pi / 180
        return CGPoint(x: center.x + CGFloat(cos(angle)) * radius * fraction,
                       y: center.y + CGFloat(sin(angle)) * radius * fraction)
    }

    private func polygon(values: [DNADimensionState], center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for (index, state) in values.enumerated() {
            let point = vertex(index: index, fraction: fraction(state.offset), center: center, radius: radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private func drawGrid(context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        for level in [0.33, 0.66, 1.0] as [CGFloat] {
            var ring = Path()
            for index in 0..<6 {
                let point = vertex(index: index, fraction: level, center: center, radius: radius)
                if index == 0 { ring.move(to: point) } else { ring.addLine(to: point) }
            }
            ring.closeSubpath()
            context.stroke(ring, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
        }
        for index in 0..<6 {
            var spoke = Path()
            spoke.move(to: center)
            spoke.addLine(to: vertex(index: index, fraction: 1, center: center, radius: radius))
            context.stroke(spoke, with: .color(.secondary.opacity(0.12)), lineWidth: 1)
        }
        var reference = Path()
        for index in 0..<6 {
            let point = vertex(index: index, fraction: Self.reference, center: center, radius: radius)
            if index == 0 { reference.move(to: point) } else { reference.addLine(to: point) }
        }
        reference.closeSubpath()
        context.stroke(reference, with: .color(.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    private var accessibilitySummary: String {
        ordered(dimensions).compactMap { state in
            guard let dimension = state.dimension else { return nil }
            return "\(dimension.title): \(Format.level(state.level))"
        }.joined(separator: ", ")
    }
}
