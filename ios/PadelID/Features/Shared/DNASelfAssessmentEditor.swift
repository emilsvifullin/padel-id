import SwiftUI

/// Self-assessment of the six Padel DNA dimensions relative to the player's
/// overall level, each on a five-step scale −2…2 (missing keys mean 0).
///
/// Emits one row per dimension, so place it inside a `Form` or `List`
/// (directly, or inside a `Section` with your own header and footer).
struct DNASelfAssessmentEditor: View {
    @Binding private var values: [DNADimension: Int]

    init(values: Binding<[DNADimension: Int]>) {
        _values = values
    }

    var body: some View {
        ForEach(DNADimension.allCases) { dimension in
            SharedDNAAssessmentRow(dimension: dimension, value: binding(for: dimension))
        }
    }

    private func binding(for dimension: DNADimension) -> Binding<Int> {
        Binding(
            get: { SharedDNAAssessmentScale.clamp(values[dimension] ?? 0) },
            set: { values[dimension] = SharedDNAAssessmentScale.clamp($0) }
        )
    }
}

/// Wording of the self-assessment scale.
private nonisolated enum SharedDNAAssessmentScale {
    static let steps = [-2, -1, 0, 1, 2]

    static func clamp(_ value: Int) -> Int {
        min(2, max(-2, value))
    }

    /// "Заметно слабее" … "Заметно сильнее".
    static func label(_ value: Int) -> String {
        switch clamp(value) {
        case -2: "Заметно слабее"
        case -1: "Немного слабее"
        case 1: "Немного сильнее"
        case 2: "Заметно сильнее"
        default: "На уровне моей игры"
        }
    }

    /// Compact segment caption with a typographic minus: "−2" … "+2".
    static func shortLabel(_ value: Int) -> String {
        switch value {
        case ..<0: "−\(abs(value))"
        case 0: "0"
        default: "+\(value)"
        }
    }
}

private struct SharedDNAAssessmentRow: View {
    let dimension: DNADimension
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: dimension.symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(minWidth: 24)
                        .accessibilityHidden(true)
                    Text(dimension.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(dimension.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            SharedDNAAssessmentControl(title: dimension.title, value: $value)
                .accessibilityIdentifier("dnaSelf.\(dimension.rawValue)")

            Text(SharedDNAAssessmentScale.label(value))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(value == 0 ? Color.secondary : Theme.accent)
                .contentTransition(.opacity)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
    }
}

/// Five segments −2…2; one adjustable element for VoiceOver.
private struct SharedDNAAssessmentControl: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SharedDNAAssessmentScale.steps, id: \.self) { step in
                let isSelected = step == value
                Button {
                    value = step
                } label: {
                    Text(SharedDNAAssessmentScale.shortLabel(step))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(isSelected ? Theme.accent : Color(.tertiarySystemFill),
                                    in: .rect(cornerRadius: 12, style: .continuous))
                        .contentShape(.rect(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.snappy(duration: 0.2), value: value)
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(SharedDNAAssessmentScale.label(value))
        .accessibilityHint("Смахните вверх или вниз, чтобы изменить оценку.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = SharedDNAAssessmentScale.clamp(value + 1)
            case .decrement: value = SharedDNAAssessmentScale.clamp(value - 1)
            @unknown default: break
            }
        }
    }
}
