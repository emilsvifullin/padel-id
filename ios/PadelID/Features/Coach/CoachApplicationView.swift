import SwiftUI

/// Coach verification: the current application status and the application
/// form (`GET`/`PUT v1/coach/application`).
struct CoachApplicationView: View {
    @Environment(AppModel.self) private var app
    @State private var resource = Resource<CoachApplicationSnapshot>(cacheKey: CoachApplicationSnapshot.cacheKey) {
        .get("v1/coach/application")
    }
    @State private var form = CoachApplicationForm(years: 0, certification: "", about: "", club: nil)
    @State private var didPrefill = false
    @State private var isSubmitting = false
    @State private var submitError: APIError?
    @State private var successCount = 0
    @State private var failureCount = 0

    var body: some View {
        content
            .navigationTitle("Статус тренера")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: app.dataRevision) { await resource.load(using: app) }
            .onChange(of: resource.value, initial: true) { oldValue, newValue in
                guard let newValue else { return }
                // Prefill from the server unless the user has edited the form.
                if !didPrefill || form == baseline(for: oldValue?.application) {
                    form = baseline(for: newValue.application)
                    didPrefill = true
                }
            }
            .sensoryFeedback(.success, trigger: successCount)
            .sensoryFeedback(.error, trigger: failureCount)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = resource.value {
            formView(snapshot.application)
        } else if let error = resource.error {
            ErrorStateView(error: error) {
                Task { await resource.load(using: app) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
        } else {
            LoadingView()
                .background(Color(.systemGroupedBackground))
        }
    }

    // MARK: - Form

    private func formView(_ application: CoachApplication?) -> some View {
        Form {
            if resource.isStale, resource.error?.isNetwork == true {
                Section {
                    OfflineBanner()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            } else if !app.isOnline {
                Section {
                    SettingsOfflineNotice(message: "Нет подключения к интернету. Отправить заявку можно только онлайн.")
                }
            }

            if let application {
                Section {
                    CoachApplicationStatusView(application: application)
                } header: {
                    Text("Статус")
                }
            }

            Section {
                CoachApplicationBenefits()
            } header: {
                Text("Подтверждённый тренер")
            }

            if application?.status != .revoked {
                editableSections(application)
            }
        }
        .disabled(isSubmitting)
        .refreshable { await resource.load(using: app) }
    }

    @ViewBuilder
    private func editableSections(_ application: CoachApplication?) -> some View {
        Section {
            Stepper(value: $form.years, in: 0...60) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Тренерский стаж")
                    Text(Format.count(form.years, "год", "года", "лет"))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .sensoryFeedback(.selection, trigger: form.years)
        } header: {
            Text("Опыт")
        }

        Section {
            TextField("Например, сертификат федерации падела", text: $form.certification)
                .textInputAutocapitalization(.sentences)
        } header: {
            Text("Сертификация")
        } footer: {
            HStack(alignment: .firstTextBaseline) {
                Text("Необязательно.")
                Spacer(minLength: 8)
                SettingsCharacterCount(count: SettingsText.length(form.certification), limit: CoachApplicationLimits.certification)
            }
        }

        Section {
            TextField("С кем и где занимаетесь, какие тренировки проводите", text: $form.about, axis: .vertical)
                .lineLimit(4...10)
        } header: {
            Text("О себе")
        } footer: {
            HStack(alignment: .firstTextBaseline) {
                Text(aboutHint)
                Spacer(minLength: 8)
                SettingsCharacterCount(count: SettingsText.length(form.about), limit: CoachApplicationLimits.aboutMaximum)
            }
        }

        if let cityId = app.me?.profile?.city?.id {
            Section {
                NavigationLink {
                    ClubPickerView(cityId: cityId, selection: $form.club)
                } label: {
                    LabeledContent("Клуб", value: form.club?.name ?? "Не выбран")
                }
            } header: {
                Text("Клуб")
            } footer: {
                Text("Необязательно. Где вы проводите тренировки.")
            }
        }

        Section {
            SettingsActionButton(title: submitTitle(application), isWorking: isSubmitting) {
                submit(application)
            }
            .disabled(!canSubmit(application))
        } footer: {
            if let submitError {
                Text(submitError.message)
                    .foregroundStyle(Theme.negative)
            } else if application?.status == .approved {
                Text("Изменения анкеты не влияют на подтверждённый статус.")
            } else {
                Text("Заявки проверяются вручную. Решение появится на этом экране.")
            }
        }
    }

    // MARK: - State

    private var aboutHint: String {
        let length = SettingsText.length(form.about)
        if length < CoachApplicationLimits.aboutMinimum {
            let missing = CoachApplicationLimits.aboutMinimum - length
            return "Ещё минимум \(Format.count(missing, "символ", "символа", "символов"))."
        }
        return "Расскажите об опыте, учениках и формате занятий."
    }

    private func baseline(for application: CoachApplication?) -> CoachApplicationForm {
        guard let application else {
            return CoachApplicationForm(years: 0, certification: "", about: "", club: app.me?.profile?.club)
        }
        return CoachApplicationForm(
            years: application.experienceYears,
            certification: application.certification ?? "",
            about: application.about,
            club: application.club)
    }

    private var isValid: Bool {
        let about = SettingsText.length(form.about)
        let aboutIsValid = about >= CoachApplicationLimits.aboutMinimum && about <= CoachApplicationLimits.aboutMaximum
        let certificationIsValid = SettingsText.length(form.certification) <= CoachApplicationLimits.certification
        return aboutIsValid && certificationIsValid && (0...60).contains(form.years)
    }

    private func hasChanges(comparedTo application: CoachApplication) -> Bool {
        if form.years != application.experienceYears { return true }
        if form.club?.id != application.club?.id { return true }
        let certification = SettingsText.trimmed(application.certification ?? "")
        if SettingsText.trimmed(form.certification) != certification { return true }
        return SettingsText.trimmed(form.about) != SettingsText.trimmed(application.about)
    }

    private func canSubmit(_ application: CoachApplication?) -> Bool {
        guard isValid, app.isOnline, !isSubmitting else { return false }
        guard let application else { return true }
        switch application.status {
        case .revoked: return false
        case .rejected: return true
        case .pending, .approved: return hasChanges(comparedTo: application)
        }
    }

    private func submitTitle(_ application: CoachApplication?) -> String {
        guard let application else { return "Отправить заявку" }
        switch application.status {
        case .pending: return "Обновить заявку"
        case .approved: return "Сохранить изменения"
        case .rejected, .revoked: return "Отправить повторно"
        }
    }

    private func submit(_ application: CoachApplication?) {
        guard canSubmit(application) else { return }
        let certification = SettingsText.trimmed(form.certification)
        let body = CoachApplicationBody(
            experienceYears: form.years,
            certification: certification.isEmpty ? nil : certification,
            about: SettingsText.trimmed(form.about),
            clubId: form.club?.id)
        isSubmitting = true
        submitError = nil
        Task {
            defer { isSubmitting = false }
            do {
                let data = try await app.api.data(.json(.put, "v1/coach/application", body))
                let snapshot = try JSONCoding.decoder.decode(CoachApplicationSnapshot.self, from: data)
                resource.replace(with: snapshot, data: data, app: app)
                successCount += 1
                await app.refreshMe()
                app.dataDidChange()
            } catch is CancellationError {
                return
            } catch let error as APIError {
                submitError = error
                failureCount += 1
                if error.code == "coach_revoked" {
                    await resource.load(using: app)
                }
            } catch {
                submitError = APIError(kind: .decoding, code: "decoding", serverMessage: nil)
                failureCount += 1
            }
        }
    }
}

// MARK: - Status

private struct CoachApplicationStatusView: View {
    let application: CoachApplication

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusPill(text: CoachApplicationCopy.status(application.status), color: color, symbol: symbol)
            Text(summary)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if let note = application.reviewNote, !note.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Комментарий администратора")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(note)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch application.status {
        case .pending: Theme.attention
        case .approved: Theme.positive
        case .rejected, .revoked: Theme.negative
        }
    }

    private var symbol: String {
        switch application.status {
        case .pending: "clock"
        case .approved: "checkmark.seal.fill"
        case .rejected: "xmark.circle"
        case .revoked: "slash.circle"
        }
    }

    private var summary: String {
        switch application.status {
        case .pending:
            return "Заявка отправлена \(Format.date(application.submittedAt)) и проверяется вручную — решение появится здесь."
        case .approved:
            guard let reviewedAt = application.reviewedAt else {
                return "Вы подтверждённый тренер: оценивать навыки игрока можно в его профиле."
            }
            return "С \(Format.date(reviewedAt)) вы подтверждённый тренер: оценивать навыки игрока можно в его профиле."
        case .rejected:
            return "Заявка отклонена. Дополните анкету и отправьте её снова."
        case .revoked:
            return "Статус тренера отозван. Ваши оценки больше не учитываются в Padel DNA игроков, повторная заявка недоступна."
        }
    }
}

private struct CoachApplicationBenefits: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            benefit(symbol: "hexagon",
                    text: "Оценивает навыки игроков по шести направлениям Padel DNA прямо в их профиле.")
            benefit(symbol: "checkmark.seal",
                    text: "Оценки тренера — самый весомый источник Padel DNA: они подтверждают навыки игрока на 180 дней.")
            benefit(symbol: "person.text.rectangle",
                    text: "Получает отметку тренера в профиле и в поиске игроков.")
            benefit(symbol: "hand.raised",
                    text: "Каждую заявку мы проверяем вручную.")
        }
        .padding(.vertical, 4)
    }

    private func benefit(symbol: String, text: String) -> some View {
        Label {
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Theme.accent)
        }
    }
}

// MARK: - Shared copy

/// Russian names of coach verification statuses.
nonisolated enum CoachApplicationCopy {
    static func status(_ status: CoachStatus) -> String {
        switch status {
        case .pending: "На рассмотрении"
        case .approved: "Подтверждён"
        case .rejected: "Отклонён"
        case .revoked: "Отозван"
        }
    }
}

// MARK: - Data

private nonisolated enum CoachApplicationLimits {
    static let certification = 120
    static let aboutMinimum = 20
    static let aboutMaximum = 500
}

private nonisolated struct CoachApplicationForm: Equatable, Sendable {
    var years: Int
    var certification: String
    var about: String
    var club: NamedRef?
}

/// `GET v1/coach/application` answers JSON `null` when there is no application.
private nonisolated struct CoachApplicationSnapshot: Decodable, Hashable, Sendable {
    static let cacheKey = "coach.application"

    let application: CoachApplication?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        application = container.decodeNil() ? nil : try container.decode(CoachApplication.self)
    }
}

/// Body of `PUT v1/coach/application` (snake_case via the shared encoder).
private nonisolated struct CoachApplicationBody: Encodable, Sendable {
    let experienceYears: Int
    let certification: String?
    let about: String
    let clubId: Int?
}
