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
    @State private var submittedSeries: UpcomingSeriesBody?
    @State private var isPrivate = false
    @State private var repeating = false
    @State private var occurrences = 4
    @State private var intervalWeeks = 1
    private var hasSubmission: Bool { submittedBody != nil || submittedSeries != nil }

    private var valid: Bool {
        city != nil && SettingsText.length(location) >= 2 && SettingsText.length(location) <= 120
            && SettingsText.length(note) <= 280 && minLevel <= maxLevel && startsAt > .now
            && (!repeating || (Calendar.current.date(byAdding: .weekOfYear, value: (occurrences - 1) * intervalWeeks, to: startsAt) ?? .distantFuture) < Date.now.addingTimeInterval(180 * 86400))
    }

    var body: some View {
        SheetNavigationStack {
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
                    Toggle("Закрытая игра", isOn: $isPrivate)
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
                Section {
                    Toggle("Повторять игру", isOn: $repeating)
                    if repeating {
                        Stepper("Количество игр: \(occurrences)", value: $occurrences, in: 2...12)
                        Stepper("Каждые \(intervalWeeks) нед.", value: $intervalWeeks, in: 1...4)
                    }
                } header: { Text("Постоянная игра") } footer: {
                    Text("Все даты должны быть в пределах 180 дней. Каждый состав собирается отдельно; приглашение не резервирует место. В закрытые игры вы приглашаете друзей после создания.")
                }
            }
            .disabled(isWorking || hasSubmission)
            .navigationTitle("Новая игра")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(isWorking) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { publish() } label: {
                        if isWorking { ProgressView() } else { Text(hasSubmission ? "Повторить" : "Опубликовать") }
                    }
                    .disabled((!hasSubmission && !valid) || !app.isOnline || isWorking)
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
        guard let city, hasSubmission || valid, app.isOnline, !isWorking else { return }
        isWorking = true
        error = nil
        var body = submittedBody ?? submittedSeries?.match ?? UpcomingCreateBody(clientId: repeating ? nil : clientId, startsAt: JSONCoding.formatDate(startsAt), cityId: city.id,
                                      clubId: club?.id, location: SettingsText.trimmed(location), matchType: matchType,
                                      minLevel: minLevel, maxLevel: maxLevel, note: note.isEmpty ? nil : SettingsText.trimmed(note))
        if !hasSubmission {
            body.visibility = isPrivate ? "private" : "public"
            if repeating {
                submittedSeries = UpcomingSeriesBody(match: body, occurrences: occurrences, intervalWeeks: intervalWeeks, timeZone: TimeZone.current.identifier)
            } else { submittedBody = body }
        }
        Task {
            defer { isWorking = false }
            do {
                if let series = submittedSeries {
                    _ = try await app.api.send(.json(.post, "v1/upcoming-matches/series", series, idempotencyKey: clientId), as: UpcomingSeriesResponse.self)
                } else {
                    _ = try await app.api.send(.json(.post, "v1/upcoming-matches", body, idempotencyKey: clientId), as: UpcomingMatch.self)
                }
                app.dataDidChange()
                Announce.post("Игра опубликована")
                dismiss()
            } catch let failure as APIError {
                if !failure.isTransient && failure.kind != .decoding { submittedBody = nil; submittedSeries = nil }
                error = failure.message
                Announce.post(failure.message)
            }
            catch { self.error = "Не удалось опубликовать игру. Попробуйте снова." }
        }
    }
}
