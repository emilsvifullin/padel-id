import SwiftUI

/// Changes the same event and preserves its roster and sporting rules.
struct EventEditView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var event: SportEvent
    @State private var draft: SportEventEditDraft
    @State private var pending: SportEventEditBody?
    @State private var working = false
    @State private var needsReload = false
    @State private var needsReview = false
    @State private var error: String?

    init(event: SportEvent) {
        _event = State(initialValue: event)
        _draft = State(initialValue: SportEventEditDraft(event: event))
    }

    private var valid: Bool {
        event.viewer.isOrganizer && event.rosterIsOpen && draft.city != nil && draft.startsAt > .now &&
        draft.startsAt <= .now.addingTimeInterval(180 * 86400) &&
        (2...100).contains(SettingsText.length(draft.title)) && SettingsText.length(draft.description) <= 1200 &&
        (2...160).contains(SettingsText.length(draft.location)) && SettingsText.length(draft.specialization) <= 160 &&
        (!draft.hasPrice || Int(draft.priceText).map { (0...100000).contains($0) } == true)
    }

    var body: some View {
        SheetNavigationStack {
            Form {
                if let error { SettingsErrorRow(message: error) }
                if needsReload {
                    Button("Обновить условия") { Task { await reload() } }
                        .disabled(working || !app.isOnline)
                }
                if needsReview {
                    Section("Условия на другом устройстве") {
                        DisclosureGroup("Актуальные условия") {
                            LabeledContent("Название", value: event.title)
                            if !event.description.isEmpty { Text(event.description) }
                            LabeledContent("Начало", value: event.startsAt.formatted(date: .abbreviated, time: .shortened))
                            LabeledContent("Продолжительность", value: "\(event.durationMinutes) мин")
                            LabeledContent("Город", value: event.city.name)
                            LabeledContent("Клуб", value: event.club?.name ?? "Не указан")
                            LabeledContent("Место", value: event.location)
                            if let specialization = event.specialization { Text(specialization) }
                            LabeledContent("Стоимость", value: event.priceTitle ?? "Не указана")
                        }
                        Button("Продолжить с моим черновиком") { needsReview = false; error = nil }
                            .accessibilityIdentifier("eventEdit.keepDraft")
                        Button("Использовать актуальные условия") {
                            draft = SportEventEditDraft(event: event); needsReview = false; error = nil
                        }
                        .accessibilityIdentifier("eventEdit.useLatest")
                    }
                }
                Group {
                    Section("Событие") {
                        TextField("Название", text: $draft.title).accessibilityIdentifier("eventEdit.title")
                        TextField("Описание и условия участия", text: $draft.description, axis: .vertical)
                        if event.kind == .training {
                            TextField("Над чем будем работать", text: $draft.specialization, axis: .vertical)
                        }
                    }
                    Section("Когда и где") {
                        DatePicker("Начало", selection: $draft.startsAt,
                                   in: Date.now...Date.now.addingTimeInterval(180 * 86400))
                        Picker("Продолжительность", selection: $draft.duration) {
                            ForEach([30, 60, 90, 120, 180, 240], id: \.self) { Text("\($0) мин").tag($0) }
                        }
                        NavigationLink { CityPickerView(selection: Binding(get: { draft.city }, set: { newCity in
                                if newCity?.id != draft.city?.id { draft.club = nil }
                                draft.city = newCity
                            })) } label: {
                            LabeledContent("Город", value: draft.city?.name ?? "Выберите")
                        }
                        if let city = draft.city {
                            NavigationLink { ClubPickerView(cityId: city.id, selection: $draft.club) } label: {
                                LabeledContent("Клуб", value: draft.club?.name ?? "Не указан")
                            }
                        }
                        TextField("Адрес и место встречи", text: $draft.location, axis: .vertical)
                    }
                    Section {
                        Toggle("Указать стоимость", isOn: $draft.hasPrice)
                        if draft.hasPrice { TextField("Стоимость участия, ₽", text: $draft.priceText).keyboardType(.numberPad) }
                    } header: { Text("Условия участия") } footer: {
                        Text("Записи участников сохранятся. Они получат уведомление об изменении условий. Формат, состав, игровые правила и диапазон уровня сохраняются.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(working || pending != nil || needsReload || needsReview || !event.rosterIsOpen)
            }
            .navigationTitle("Событие")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() }.disabled(working) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pending == nil ? "Сохранить" : "Повторить") { save() }
                        .disabled(working || needsReload || needsReview || !app.isOnline || (pending == nil && !valid))
                        .accessibilityIdentifier("eventEdit.save")
                }
            }
        }
        .interactiveDismissDisabled(working || pending != nil)
    }

    private func save() {
        guard !working, !needsReload, !needsReview, app.isOnline, let city = draft.city, pending != nil || valid else { return }
        let body = pending ?? SportEventEditBody(version: event.editingVersion,
            title: SettingsText.trimmed(draft.title), description: SettingsText.trimmed(draft.description),
            startsAt: JSONCoding.formatDate(draft.startsAt), durationMinutes: draft.duration,
            cityId: city.id, clubId: draft.club?.id, location: SettingsText.trimmed(draft.location),
            specialization: event.kind == .training ? SettingsText.trimmed(draft.specialization) : nil,
            priceRub: draft.hasPrice ? Int(draft.priceText) : nil)
        pending = body; working = true; error = nil
        Task {
            defer { working = false }
            do {
                _ = try await app.api.send(.json(.put, "v1/events/\(event.id)", body, retryable: true), as: SportEvent.self)
                app.dataDidChange(); dismiss()
            } catch let failure as APIError {
                error = failure.message
                if failure.permitsSubmissionCorrection {
                    pending = nil
                    if failure.status == 409 {
                        needsReload = true
                        await reload(ownsWorkingState: false)
                    }
                }
            } catch { self.error = "Изменения не подтверждены. Повторите тот же запрос." }
        }
    }

    private func reload(ownsWorkingState: Bool = true) async {
        if ownsWorkingState { working = true }
        defer { if ownsWorkingState { working = false } }
        do {
            let fresh = try await app.api.send(.get("v1/events/\(event.id)"), as: SportEvent.self)
            draft.reconcile(from: event, to: fresh)
            event = fresh
            needsReview = fresh.rosterIsOpen && fresh.viewer.isOrganizer
            needsReload = false
            error = fresh.rosterIsOpen && fresh.viewer.isOrganizer
                ? "Условия изменились. Черновик сохранён; проверьте актуальные условия перед сохранением."
                : "Событие больше нельзя изменить. Закройте окно и обновите его."
        } catch let failure as APIError { error = failure.message }
        catch { self.error = "Не удалось обновить условия. Попробуйте снова." }
    }
}
