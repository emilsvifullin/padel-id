import Charts
import SwiftUI

/// Rating over time with its uncertainty band (μ ± σ).
struct RatingChart: View {
    let data: RatingChartData
    let compact: Bool

    init(points: [RatingPoint], compact: Bool = false) {
        self.init(data: RatingChartData(points: points), compact: compact)
    }

    init(data: RatingChartData, compact: Bool = false) {
        self.data = data
        self.compact = compact
    }

    var body: some View {
        Chart {
            // Each homogeneous series is one vectorized plot rather than a
            // separate SwiftUI mark per point. All original samples remain.
            AreaPlot(data.samples,
                     x: .value("Дата", \.at),
                     yStart: .value("Нижняя граница", \.lower),
                     yEnd: .value("Верхняя граница", \.upper))
                .foregroundStyle(Theme.accent.opacity(0.12))
                .interpolationMethod(.monotone)
            LinePlot(data.samples, x: .value("Дата", \.at), y: .value("Уровень", \.level))
                .foregroundStyle(Theme.accent)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            if !compact {
                // Wins and losses differ by shape as well as colour.
                PointPlot(data.wins, x: .value("Дата", \.at), y: .value("Уровень", \.mu))
                        .foregroundStyle(Theme.positive)
                        .symbol(.circle)
                        .symbolSize(28)
                PointPlot(data.losses, x: .value("Дата", \.at), y: .value("Уровень", \.mu))
                        .foregroundStyle(Theme.negative)
                        .symbol(.cross)
                        .symbolSize(36)
            }
            if let last = data.samples.last {
                PointMark(x: .value("Дата", last.at), y: .value("Уровень", last.level))
                    .foregroundStyle(Theme.accent)
                    .symbolSize(compact ? 50 : 70)
            }
        }
        .chartYScale(domain: data.yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: compact ? 3 : 4)) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(Format.locale))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: compact ? 3 : 5)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel {
                    if let level = value.as(Double.self) { Text(Format.level(level)) }
                }
            }
        }
        .environment(\.locale, Format.locale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("График рейтинга")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let first = data.samples.first, let last = data.samples.last else { return "Нет данных" }
        return "От \(Format.level(first.level)) до \(Format.level(last.level)), \(Format.matches(data.matchCount))"
    }
}

/// Stored key paths let Swift Charts read the complete collection efficiently;
/// domain and outcome grouping are computed when data arrives, not in `body`.
nonisolated struct RatingChartData: Sendable {
    let samples: [RatingChartSample]
    let wins: [RatingPoint]
    let losses: [RatingPoint]
    let yDomain: ClosedRange<Double>
    let matchCount: Int

    init(points: [RatingPoint]) {
        samples = points.map {
            RatingChartSample(at: $0.at, level: $0.mu,
                              lower: max(0, $0.mu - $0.sigma), upper: min(7, $0.mu + $0.sigma))
        }
        wins = points.filter { $0.kind == "match" && $0.won == true }
        losses = points.filter { $0.kind == "match" && $0.won != true }
        matchCount = wins.count + losses.count
        let low = max(0, (samples.map(\.lower).min() ?? 0) - 0.1)
        let high = min(7, (samples.map(\.upper).max() ?? 7) + 0.1)
        if high - low < 0.6 {
            let mid = (high + low) / 2
            yDomain = max(0, mid - 0.3)...min(7, mid + 0.3)
        } else {
            yDomain = low...high
        }
    }
}

nonisolated struct RatingChartSample: Sendable {
    let at: Date
    let level: Double
    let lower: Double
    let upper: Double
}
