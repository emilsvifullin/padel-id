import SwiftUI

/// A verified coach rates the six Padel DNA skills of a player (0–7, step 0.5).
struct CoachAssessmentView: View {
    let player: PlayerCard
    let dna: PadelDNA?
    let onSaved: (PlayerProfileResponse) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var scores: [DNADimension: Double]
    @State private var note = ""
    @State private var isSubmitting = false
    @State private var error: APIError?
    @State private var failureCount = 0

    private static let noteLimit = 500

    init(player: PlayerCard, dna: PadelDNA?, onSaved: @escaping (PlayerProfileResponse) -> Void) {
        self.player = player
        self.dna = dna
        self.onSaved = onSaved
        _scores = State(initialValue: Self.initialScores(player: player, dna: dna))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PlayerRow(card: player) {
                        LevelChip(level: player.level, reliability: player.reliability)
                    }
                } footer: {
                    Text("Оценка подтверждает навыки в Padel DNA игрока и учитывается 180 дней. Используйте ту же шкалу 0–7, что и для общего уровня.")
                }

                Section {
                    ForEach(DNADimension.allCases) { dimension in
                        Stepper(value: binding(for: dimension), in: 0...7, step: 0.5) {
                            CoachAssessmentScoreLabel(
                                dimension: dimension,
                                score: scores[dimension] ?? 0,
                                reference: referenceLevel(for: dimension))
                        }
                        .accessibilityValue(Format.level(scores[dimension] ?? 0))
                    }
                } header: {
                    Text("Навыки")
                } footer: {
                    Text("Начальные значения — текущие уровни игрока в Padel DNA, округлённые до 0.5.")
                }

                Section {
                    TextField("Что получается хорошо и над чем работать", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Комментарий")
                } footer: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Необязательно. Виден только игроку и вам.")
                        Spacer(minLength: 8)
                        Text("\(noteLength)/\(Self.noteLimit)")
                            .monospacedDigit()
                            .accessibilityLabel("Символов: \(noteLength) из \(Self.noteLimit)")
                    }
                }

                if let error {
                    Section {
                        Label(error.message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.negative)
                    }
                } else if !app.isOnline {
                    Section {
                        Label("Нет подключения. Оценку можно сохранить только онлайн.", systemImage: "wifi.slash")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Оценка тренера")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("Сохранить", action: submit)
                            .disabled(!canSubmit)
                    }
                }
            }
            .interactiveDismissDisabled(isSubmitting)
            .onChange(of: note) { _, newValue in
                if newValue.unicodeScalars.count > Self.noteLimit {
                    note = String(String.UnicodeScalarView(newValue.unicodeScalars.prefix(Self.noteLimit)))
                }
            }
            .sensoryFeedback(.selection, trigger: scores)
            .sensoryFeedback(.error, trigger: failureCount)
        }
    }

    // MARK: - State

    private var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var noteLength: Int { note.unicodeScalars.count }

    private var canSubmit: Bool {
        !isSubmitting && app.isOnline && trimmedNote.unicodeScalars.count <= Self.noteLimit
    }

    private func binding(for dimension: DNADimension) -> Binding<Double> {
        Binding(
            get: { scores[dimension] ?? 0 },
            set: { scores[dimension] = min(7, max(0, $0)) }
        )
    }

    private func referenceLevel(for dimension: DNADimension) -> Double? {
        dna?.dimensions.first(where: { $0.dimension == dimension })?.level
    }

    private static func initialScores(player: PlayerCard, dna: PadelDNA?) -> [DNADimension: Double] {
        let fallback = player.level ?? dna?.rating?.mu ?? 0
        var result: [DNADimension: Double] = [:]
        for dimension in DNADimension.allCases {
            let level = dna?.dimensions.first(where: { $0.dimension == dimension })?.level ?? fallback
            result[dimension] = min(7, max(0, (level * 2).rounded() / 2))
        }
        return result
    }

    // MARK: - Submit

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        error = nil
        var payload: [String: Double] = [:]
        for dimension in DNADimension.allCases {
            payload[dimension.rawValue] = scores[dimension] ?? 0
        }
        let body = CoachAssessmentRequestBody(scores: payload, note: trimmedNote.isEmpty ? nil : trimmedNote)
        let path = "v1/players/\(player.id.uuidString.lowercased())/coach-assessments"
        Task {
            defer { isSubmitting = false }
            do {
                let response = try await app.api.send(.json(.post, path, body), as: PlayerProfileResponse.self)
                onSaved(response)
                dismiss()
            } catch let apiError as APIError {
                error = apiError
                failureCount += 1
            } catch {}
        }
    }
}

/// Request body of `POST v1/players/{id}/coach-assessments` (snake_case keys).
private nonisolated struct CoachAssessmentRequestBody: Encodable, Sendable {
    let scores: [String: Double]
    let note: String?
}

private struct CoachAssessmentScoreLabel: View {
    let dimension: DNADimension
    let score: Double
    let reference: Double?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Label(dimension.title, systemImage: dimension.symbol)
                if let reference {
                    Text("Сейчас в Padel DNA: \(Format.level(reference))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(Format.level(score))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .accessibilityHidden(true)
        }
    }
}
