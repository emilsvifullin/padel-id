import SwiftUI

struct UpcomingCreateView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var city: NamedRef?
    @State private var club: NamedRef?
    @State private var startsAt = Date.now.addingTimeInterval(86400)
    @State private var location = ""
    @State private var note = ""
    @State private var matchType: MatchType = .friendly
    @State private var minLevel = 0.0
    @State private var maxLevel = 7.0
    @State private var isWorking = false
    @State private var error: String?
    @State private var clientId = UUID()
    @State private var prepared = false
    @State private var submittedBody: UpcomingCreateBody?

    private var valid: Bool {
        city != nil && SettingsText.length(location) >= 2 && SettingsText.length(location) <= 120
            && SettingsText.length(note) <= 280 && minLevel <= maxLevel && startsAt > .now
    }

    var body: some View {
        NavigationStack {
            Form {
                if !app.isOnline { SettingsOfflineNotice() }
                if let error { SettingsErrorRow(message: error) }
                Section("Когда и где") {
                    DatePicker("Начало", selection: $startsAt, in: Date.now...Date.now.addingTimeInterval(90 * 86400))
                    NavigationLink { CityPickerView(selection: $city) } label: {
                        LabeledContent("Город", value: city?.name ?? "Выберите")
                    }
                    if let city {
                        NavigationLink { ClubPickerView(cityId: city.id, selection: $club) } label: {
                            LabeledContent("Клуб", value: club?.name ?? "Не указан")
                        }
                    }
                    TextField("Адрес или место встречи", text: $location, axis: .vertical)
                        .accessibilityIdentifier("upcoming.location")
                }
                Section {
                    Picker("Тип матча", selection: $matchType) {
                        Text("Товарищеский").tag(MatchType.friendly)
                        Text("Рейтинговый").tag(MatchType.ranked)
                    }
                    Stepper("Уровень от \(Format.level(minLevel))", value: $minLevel, in: 0...maxLevel, step: 0.25)
                    Stepper("До \(Format.level(maxLevel))", value: $maxLevel, in: minLevel...7, step: 0.25)
                } header: { Text("Участники") } footer: {
                    Text("Вы займёте первое из четырёх мест. В диапазоне игры участники с надёжностью от 70% и минимум пятью рейтинговыми матчами присоединяются сразу. При меньшей надёжности или числе игр вы рассматриваете заявку. Надёжный уровень вне диапазона не допускается.")
                }
                Section {
                    TextField("Что нужно знать игрокам", text: $note, axis: .vertical)
                    SettingsCharacterCount(count: SettingsText.length(note), limit: 280)
                } header: { Text("Примечание") }
            }
            .disabled(isWorking || submittedBody != nil)
            .navigationTitle("Новая открытая игра")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(isWorking) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { publish() } label: {
                        if isWorking { ProgressView() } else { Text(submittedBody == nil ? "Опубликовать" : "Повторить") }
                    }
                    .disabled((submittedBody == nil && !valid) || !app.isOnline || isWorking)
                    .accessibilityIdentifier("upcoming.publish")
                }
            }
        }
        .interactiveDismissDisabled(isWorking)
        .onAppear {
            guard !prepared else { return }
            prepared = true
            city = app.me?.profile?.city
            club = app.me?.profile?.club
        }
        .onChange(of: city?.id) { old, new in if old != nil && old != new { club = nil } }
    }

    private func publish() {
        guard let city, submittedBody != nil || valid, app.isOnline, !isWorking else { return }
        isWorking = true
        error = nil
        let body = submittedBody ?? UpcomingCreateBody(clientId: clientId, startsAt: JSONCoding.formatDate(startsAt), cityId: city.id,
                                      clubId: club?.id, location: SettingsText.trimmed(location), matchType: matchType,
                                      minLevel: minLevel, maxLevel: maxLevel, note: note.isEmpty ? nil : SettingsText.trimmed(note))
        submittedBody = body
        Task {
            defer { isWorking = false }
            do {
                _ = try await app.api.send(.json(.post, "v1/upcoming-matches", body, idempotencyKey: clientId), as: UpcomingMatch.self)
                app.dataDidChange()
                Announce.post("Игра опубликована")
                dismiss()
            } catch let failure as APIError {
                if !failure.isTransient && failure.kind != .decoding { submittedBody = nil }
                error = failure.message
                Announce.post(failure.message)
            }
            catch { self.error = "Не удалось опубликовать игру. Попробуйте снова." }
        }
    }
}
