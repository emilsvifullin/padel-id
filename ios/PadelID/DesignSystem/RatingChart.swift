import Charts
import SwiftUI

/// Rating over time with its uncertainty band (μ ± σ).
struct RatingChart: View {
    let points: [RatingPoint]
    var compact = false

    var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("Дата", point.at),
                    yStart: .value("Нижняя граница", max(0, point.mu - point.sigma)),
                    yEnd: .value("Верхняя граница", min(7, point.mu + point.sigma))
                )
                .foregroundStyle(Theme.accent.opacity(0.12))
                .interpolationMethod(.monotone)
            }
            ForEach(points) { point in
                LineMark(x: .value("Дата", point.at), y: .value("Уровень", point.mu))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if !compact {
                // Wins and losses differ by shape as well as colour.
                ForEach(points.filter { $0.kind == "match" && $0.won == true }) { point in
                    PointMark(x: .value("Дата", point.at), y: .value("Уровень", point.mu))
                        .foregroundStyle(Theme.positive)
                        .symbol(.circle)
                        .symbolSize(28)
                }
                ForEach(points.filter { $0.kind == "match" && $0.won != true }) { point in
                    PointMark(x: .value("Дата", point.at), y: .value("Уровень", point.mu))
                        .foregroundStyle(Theme.negative)
                        .symbol(.cross)
                        .symbolSize(36)
                }
            }
            if let last = points.last {
                PointMark(x: .value("Дата", last.at), y: .value("Уровень", last.mu))
                    .foregroundStyle(Theme.accent)
                    .symbolSize(compact ? 50 : 70)
            }
        }
        .chartYScale(domain: yDomain)
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

    private var yDomain: ClosedRange<Double> {
        let lows = points.map { $0.mu - $0.sigma }
        let highs = points.map { $0.mu + $0.sigma }
        let low = max(0, (lows.min() ?? 0) - 0.1)
        let high = min(7, (highs.max() ?? 7) + 0.1)
        if high - low < 0.6 {
            let mid = (high + low) / 2
            return max(0, mid - 0.3)...min(7, mid + 0.3)
        }
        return low...high
    }

    private var accessibilitySummary: String {
        guard let first = points.first, let last = points.last else { return "Нет данных" }
        return "От \(Format.level(first.mu)) до \(Format.level(last.mu)), \(Format.matches(points.filter { $0.kind == "match" }.count))"
    }
}
