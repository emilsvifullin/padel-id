import SwiftUI

/// Self-assessment of the six Padel DNA dimensions (−2…2 relative to the
/// player's overall level), the weakest source of the DNA profile.
struct SettingsDNASelfView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var values: [DNADimension: Int]
    @State private var original: [DNADimension: Int]
    @State private var hasAssessment: Bool
    @State private var isSaving = false
    @State private var error: APIError?
    @State private var saveCount = 0
    @State private var failureCount = 0

    /// `dnaSelf` comes from `Me`: keys may arrive camelCased by the decoder.
    init(dnaSelf: [String: Int]?) {
        var mapped = Dictionary(uniqueKeysWithValues: DNADimension.allCases.map { ($0, 0) })
        for (key, value) in dnaSelf ?? [:] {
            if let dimension = DNADimension(apiKey: key) {
                mapped[dimension] = min(2, max(-2, value))
            }
        }
        _values = State(initialValue: mapped)
        _original = State(initialValue: mapped)
        _hasAssessment = State(initialValue: !(dnaSelf ?? [:]).isEmpty)
    }

    var body: some View {
        Form {
            if !app.isOnline {
                Section {
                    SettingsOfflineNotice()
                }
            }
            Section {
                Text("Оцените каждое направление относительно своего общего уровня. Это стартовая точка Padel DNA с небольшим весом: отметки партнёров, соперников и тренеров постепенно уточняют профиль.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section {
                DNASelfAssessmentEditor(values: $values)
            } header: {
                Text("Направления")
            } footer: {
                if let error {
                    Text(error.message)
                        .foregroundStyle(Theme.negative)
                }
            }
        }
        .disabled(isSaving)
        .navigationTitle("Самооценка")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Сохранить", action: save)
                        .disabled(!canSave)
                }
            }
        }
        .interactiveDismissDisabled(isSaving || values != original)
        .sensoryFeedback(.success, trigger: saveCount)
        .sensoryFeedback(.error, trigger: failureCount)
    }

    private var canSave: Bool {
        (values != original || !hasAssessment) && app.isOnline && !isSaving
    }

    private func save() {
        guard canSave else { return }
        let body = Dictionary(uniqueKeysWithValues: DNADimension.allCases.map { dimension in
            (dimension.rawValue, min(2, max(-2, values[dimension] ?? 0)))
        })
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                _ = try await app.api.send(.json(.put, "v1/me/dna-self", body), as: PadelDNA.self)
                original = values
                hasAssessment = true
                saveCount += 1
                await app.refreshMe()
                app.dataDidChange()
                dismiss()
            } catch is CancellationError {
                return
            } catch let apiError as APIError {
                error = apiError
                failureCount += 1
                Announce.post(apiError.message)
            } catch {
                let failure = APIError(kind: .decoding, code: "decoding", serverMessage: nil)
                self.error = failure
                failureCount += 1
                Announce.post(failure.message)
            }
        }
    }
}
