import SwiftUI

struct EventCreateView: View {
    let initialKind: SportEventKind
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var kind: SportEventKind = .tournament
    @State private var format: SportEventFormat = .americano
    @State private var title = ""
    @State private var description = ""
    @State private var specialization = ""
    @State private var startsAt = Date.now.addingTimeInterval(172800)
    @State private var duration = 90
    @State private var city: NamedRef?
    @State private var club: NamedRef?
    @State private var location = ""
    @State private var capacity = 4
    @State private var minLevel = 0.0
    @State private var maxLevel = 7.0
    @State private var rounds = 3
    @State private var points = 32
    @State private var hasPrice = false
    @State private var priceText = ""
    @State private var isWorking = false
    @State private var error: APIError?
    @State private var clientId = UUID()
    @State private var submitted: SportEventCreateBody?
    @State private var prepared = false

    private var canCoach: Bool { app.me?.coachStatus == .approved }
    private var lengthValid: Bool {
        (2...100).contains(SettingsText.length(title)) && SettingsText.length(description) <= 1200 &&
        (2...160).contains(SettingsText.length(location)) && SettingsText.length(specialization) <= 160
    }
    private var priceValid: Bool { !hasPrice || Int(priceText).map { (0...100000).contains($0) } == true }
    private var valid: Bool { lengthValid && priceValid && city != nil && startsAt > .now && (kind != .training || canCoach) }
    private var totalRounds: Int {
        format == .americano ? capacity - 1 : format == .roundRobin ? capacity / 2 - 1 : rounds
    }

    var body: some View {
        SheetNavigationStack {
            Form {
                if !app.isOnline { SettingsOfflineNotice() }
                if let error { SettingsErrorRow(message: error.message) }
                Section("Событие") {
                    Picker("Тип", selection: $kind) {
                        Text("Турнир").tag(SportEventKind.tournament)
                        if canCoach { Text("Тренировка").tag(SportEventKind.training) }
                    }
                    TextField("Название", text: $title).accessibilityIdentifier("eventCreate.title")
                    Picker("Формат", selection: $format) {
                        ForEach(SportEventFormat.formats(for: kind)) { Text($0.title).tag($0) }
                    }
                    Text(format.explanation).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Описание и условия участия", text: $description, axis: .vertical)
                    SettingsCharacterCount(count: SettingsText.length(description), limit: 1200)
                    if kind == .training {
                        TextField("Над чем будем работать", text: $specialization, axis: .vertical)
                        SettingsCharacterCount(count: SettingsText.length(specialization), limit: 160)
                    }
                }
                Section("Когда и где") {
                    DatePicker("Начало", selection: $startsAt, in: Date.now...Date.now.addingTimeInterval(180 * 86400))
                    Picker("Продолжительность", selection: $duration) {
                        ForEach([30,60,90,120,180,240], id: \.self) { Text("\($0) мин").tag($0) }
                    }
                    NavigationLink { CityPickerView(selection: $city) } label: {
                        LabeledContent("Город", value: city?.name ?? "Выберите")
                    }
                    if let city {
                        NavigationLink { ClubPickerView(cityId: city.id, selection: $club) } label: {
                            LabeledContent("Клуб", value: club?.name ?? "Не указан")
                        }
                    }
                    TextField("Адрес и место встречи", text: $location, axis: .vertical)
                        .accessibilityIdentifier("eventCreate.location")
                }
                Section {
                    Picker("Игроков", selection: $capacity) {
                        ForEach(format.capacities, id: \.self) { Text("\($0)").tag($0) }
                    }
                    Stepper("Уровень от \(Format.level(minLevel))", value: $minLevel, in: 0...maxLevel, step: 0.25)
                    Stepper("До \(Format.level(maxLevel))", value: $maxLevel, in: minLevel...7, step: 0.25)
                    if kind == .tournament {
                        if format == .mexicano || format == .kingCourt {
                            Stepper("Раундов: \(rounds)", value: $rounds, in: 1...16)
                        } else { LabeledContent("Раундов", value: String(totalRounds)) }
                        Stepper("Очков на игру: \(points)", value: $points, in: 8...64, step: 8)
                    }
                } header: { Text("Участники и правила") } footer: {
                    Text(kind == .tournament
                         ? "Для одновременной игры нужно кортов: \(capacity / 4). Очки турнира не меняют спортивный рейтинг. Диапазон уровня ограничивает запись игроков с надёжным рейтингом; предварительный уровень не блокирует участие."
                         : "Вместимость включает игроков без тренера. Диапазон уровня ограничивает запись игроков с надёжным рейтингом; предварительный уровень не блокирует участие.")
                }
                Section {
                    Toggle("Указать стоимость", isOn: $hasPrice)
                    if hasPrice {
                        TextField("Стоимость участия, ₽", text: $priceText).keyboardType(.numberPad)
                    }
                } header: { Text("Условия участия") } footer: {
                    Text("Стоимость указывает организатор. Оплату и использование корта участники согласуют с ним напрямую.")
                }
            }.closeToBar()
            .disabled(isWorking || submitted != nil)
            .navigationTitle(kind == .training ? "Новая тренировка" : "Новый турнир")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(isWorking) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { publish() } label: {
                        if isWorking { ProgressView() } else { Text(submitted == nil ? "Опубликовать" : "Повторить") }
                    }
                    .disabled(isWorking || !app.isOnline || (submitted == nil && !valid))
                    .accessibilityIdentifier("eventCreate.publish")
                }
            }
            .onAppear {
                guard !prepared else { return }; prepared = true
                kind = initialKind == .training && canCoach ? .training : .tournament
                format = kind == .training ? .group : .americano
                city = app.me?.profile?.city; club = app.me?.profile?.club
            }
            .onChange(of: kind) { _, kind in
                format = SportEventFormat.formats(for: kind)[0]
                capacity = format.capacities[0]
            }
            .onChange(of: format) { _, format in
                if !format.capacities.contains(capacity) { capacity = format.capacities[0] }
            }
            .onChange(of: city?.id) { old, new in if old != nil && old != new { club = nil } }
        }
        .interactiveDismissDisabled(isWorking || submitted != nil)
    }

    private func publish() {
        guard let city, !isWorking, app.isOnline, submitted != nil || valid else { return }
        let payload: SportEventCreateBody = submitted ?? SportEventCreateBody(clientId: clientId, kind: kind, format: format,
            title: SettingsText.trimmed(title), description: SettingsText.trimmed(description), startsAt: JSONCoding.formatDate(startsAt),
            durationMinutes: duration, cityId: city.id, clubId: club?.id, location: SettingsText.trimmed(location), capacity: capacity,
            minLevel: minLevel, maxLevel: maxLevel, specialization: kind == .training ? SettingsText.trimmed(specialization) : nil,
            priceRub: hasPrice ? Int(priceText) : nil, roundCount: totalRounds, pointsPerGame: points)
        submitted = payload; isWorking = true; error = nil
        Task {
            defer { isWorking = false }
            do {
                _ = try await app.api.send(.json(.post, "v1/events", payload, idempotencyKey: payload.clientId), as: SportEvent.self)
                app.dataDidChange(); dismiss()
            } catch let failure as APIError {
                error = failure
                // Definitive refusal permits corrections. Uncertain transport
                // or decoding preserves the exact request and its publication key.
                if let status = failure.status, status < 500 { submitted = nil }
                Announce.post(failure.message)
            } catch { self.error = APIError(kind: .decoding, code: "decoding", serverMessage: nil) }
        }
    }
}
