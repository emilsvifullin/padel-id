import SwiftUI

/// Strengths (up to two) and one area to improve per player.
nonisolated struct MatchFeedbackSelection: Hashable, Sendable {
    var strengths: [DNADimension] = []
    var improvement: DNADimension?
}

/// Feedback on the partner and the opponents after a confirmed match. The
/// marks feed the players' Padel DNA.
struct MatchFeedbackSheet: View {
    let match: MatchDetail
    let viewerId: UUID?
    let onFinish: (MatchActionResult) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var selections: [UUID: MatchFeedbackSelection]
    @State private var limitNotice: UUID?
    @State private var limitFeedback = 0
    @State private var selectionFeedback = 0
    @State private var isSubmitting = false
    @State private var error: APIError?
    private let initial: [UUID: MatchFeedbackSelection]

    static let strengthLimit = 2

    init(match: MatchDetail, viewerId: UUID?, onFinish: @escaping (MatchActionResult) -> Void) {
        self.match = match
        self.viewerId = viewerId
        self.onFinish = onFinish
        var map: [UUID: MatchFeedbackSelection] = [:]
        for entry in match.viewer.feedback ?? [] {
            var selection = MatchFeedbackSelection()
            selection.strengths = Array(entry.strengths.compactMap { DNADimension(apiKey: $0) }.prefix(Self.strengthLimit))
            selection.improvement = entry.improvements.compactMap { DNADimension(apiKey: $0) }.first
            map[entry.playerId] = selection
        }
        initial = map
        _selections = State(initialValue: map)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Отметьте, что у каждого игрока получалось лучше всего и над чем стоит поработать, — отметки уточняют их Padel DNA.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(targets) { player in
                    playerSection(player)
                }
                if error != nil || !app.isOnline {
                    Section {
                        if let error {
                            Text(error.message)
                                .foregroundStyle(Theme.negative)
                        } else {
                            Text("Нет подключения: отметки сохранятся и отправятся автоматически.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.footnote)
                }
            }
            .disabled(isSubmitting)
            .navigationTitle("Отметки игрокам")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("Сохранить") {
                            submit()
                        }
                        .disabled(!hasChanges)
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: selectionFeedback)
            .sensoryFeedback(.impact(weight: .light), trigger: limitFeedback)
        }
        .interactiveDismissDisabled(isSubmitting || hasChanges)
    }

    // MARK: - Sections

    /// Partner first, then the opponents; never the viewer.
    private var targets: [MatchPlayer] {
        let others = match.players.filter { $0.id != viewerId && !$0.player.deleted }
        let ownTeam = match.viewer.team
        return others.filter { $0.team == ownTeam } + others.filter { $0.team != ownTeam }
    }

    private func playerSection(_ player: MatchPlayer) -> some View {
        let selection = selections[player.id] ?? MatchFeedbackSelection()
        return Section {
            HStack(spacing: 12) {
                AvatarView(card: player.player, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.player.displayName)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(player.team == match.viewer.team ? "Партнёр" : "Соперник")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            MatchFeedbackChipGroup(
                title: "Сильные стороны",
                hint: "до двух",
                selected: selection.strengths,
                blocked: selection.improvement.map { [$0] } ?? [],
                tint: Theme.positive
            ) { dimension in
                toggleStrength(dimension, for: player.id)
            }

            MatchFeedbackChipGroup(
                title: "Над чем поработать",
                hint: "одно направление",
                selected: selection.improvement.map { [$0] } ?? [],
                blocked: selection.strengths,
                tint: Theme.attention
            ) { dimension in
                toggleImprovement(dimension, for: player.id)
            }
        } footer: {
            if limitNotice == player.id {
                Text("Можно отметить не больше двух сильных сторон — снимите одну из выбранных.")
                    .foregroundStyle(Theme.attention)
            }
        }
    }

    // MARK: - Selection

    private func toggleStrength(_ dimension: DNADimension, for playerId: UUID) {
        var selection = selections[playerId] ?? MatchFeedbackSelection()
        if let index = selection.strengths.firstIndex(of: dimension) {
            selection.strengths.remove(at: index)
        } else {
            guard selection.improvement != dimension else { return }
            guard selection.strengths.count < Self.strengthLimit else {
                withAnimation(.snappy) { limitNotice = playerId }
                limitFeedback += 1
                return
            }
            selection.strengths.append(dimension)
        }
        if limitNotice == playerId {
            withAnimation(.snappy) { limitNotice = nil }
        }
        selections[playerId] = selection
        selectionFeedback += 1
    }

    private func toggleImprovement(_ dimension: DNADimension, for playerId: UUID) {
        var selection = selections[playerId] ?? MatchFeedbackSelection()
        if selection.improvement == dimension {
            selection.improvement = nil
        } else {
            guard !selection.strengths.contains(dimension) else { return }
            selection.improvement = dimension
        }
        selections[playerId] = selection
        selectionFeedback += 1
    }

    // MARK: - Submit

    private var ratings: [MatchFeedbackRating] {
        targets.compactMap { (player: MatchPlayer) -> MatchFeedbackRating? in
            let current = selections[player.id] ?? MatchFeedbackSelection()
            let previous = initial[player.id] ?? MatchFeedbackSelection()
            guard current != previous else { return nil }
            return MatchFeedbackRating(
                playerId: player.id.uuidString.lowercased(),
                strengths: current.strengths.map(\.rawValue),
                improvements: current.improvement.map { [$0.rawValue] } ?? [])
        }
    }

    private var hasChanges: Bool { !ratings.isEmpty }

    private func submit() {
        let payload = ratings
        guard !payload.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        error = nil
        Task {
            let result = await MatchActions.submitFeedback(match, ratings: payload, app: app)
            isSubmitting = false
            if case .failed(let failure) = result {
                error = failure
            } else {
                onFinish(result)
                dismiss()
            }
        }
    }
}

/// A titled grid of the six DNA dimensions as toggle chips.
private struct MatchFeedbackChipGroup: View {
    let title: String
    let hint: String
    let selected: [DNADimension]
    let blocked: [DNADimension]
    let tint: Color
    let onToggle: (DNADimension) -> Void

    @ScaledMetric(relativeTo: .subheadline) private var chipMinWidth: CGFloat = 112

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(hint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: chipMinWidth), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(DNADimension.allCases) { dimension in
                    chip(dimension)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func chip(_ dimension: DNADimension) -> some View {
        let isSelected = selected.contains(dimension)
        let isBlocked = !isSelected && blocked.contains(dimension)
        return Button {
            onToggle(dimension)
        } label: {
            Label(dimension.shortTitle, systemImage: dimension.symbol)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 8)
                .foregroundStyle(isSelected ? tint : (isBlocked ? Color.secondary : Color.primary))
                .background(isSelected ? tint.opacity(0.16) : Color(.tertiarySystemFill),
                            in: .rect(cornerRadius: 12, style: .continuous))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(tint, lineWidth: 1.5)
                    }
                }
                .opacity(isBlocked ? 0.5 : 1)
                .contentShape(.rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBlocked)
        .accessibilityLabel(dimension.title)
        .accessibilityHint(isBlocked ? "Уже отмечено в другой группе" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
