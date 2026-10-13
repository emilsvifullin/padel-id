import SwiftUI

struct EventDetailView: View {
    let eventId: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var event: Resource<SportEvent>
    @State private var friends = Resource<FriendsResponse>(cacheKey: nil) { .get("v1/friends") }
    @State private var partner: UUID?
    @State private var working = false
    @State private var error: String?
    @State private var score: SportEventGame?
    @State private var cancelled = false
    @State private var removing: SportEventRegistration?
    @State private var editing = false
    @State private var successCount = 0
    @State private var failureCount = 0
    init(eventId: UUID) {
        self.eventId = eventId
        _event = State(initialValue: Resource(cacheKey: nil) { .get("v1/events/\(eventId)") })
    }
    private var path: String { "v1/events/\(eventId)" }
    var body: some View {
        List {
            if let value = event.value {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(value.status.title, systemImage: value.kind.symbol)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .foregroundStyle(Theme.ink)
                            .background(Theme.lime, in: .capsule)
                            .padding(.bottom, 18)
                        Text(value.title).font(.display(.title2, weight: .bold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(value.startsAt, format: .dateTime.weekday(.wide).day().month(.wide).hour().minute())
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text([value.city.name, value.club?.name, value.location].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .inkCard()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .accessibilityElement(children: .combine)
                }
                Section {
                    if !value.description.isEmpty {
                        Text(value.description).fixedSize(horizontal: false, vertical: true)
                    }
                    LabeledContent("Продолжительность", value: "\(value.durationMinutes) мин")
                    if let price = value.priceTitle { LabeledContent("Стоимость участия", value: price) }
                    if let specialization = value.specialization { LabeledContent("Тема", value: specialization) }
                    NavigationLink(value: Route.player(value.organizer.id)) { PlayerRow(card: value.organizer, subtitle: "Организатор") }
                }
                Section {
                    LabeledContent("Формат", value: value.format.title)
                    Text(value.format.explanation).font(.subheadline).foregroundStyle(.secondary)
                    LabeledContent("Уровень", value: "\(Format.level(value.minLevel))–\(Format.level(value.maxLevel))")
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Места", value: "\(value.registeredCount) / \(value.capacity)")
                        ProgressView(value: Double(min(value.registeredCount, value.capacity)), total: Double(max(value.capacity, 1)))
                            .tint(Theme.accent)
                            .accessibilityHidden(true)
                    }
                    if value.rosterIsOpen {
                        registration(value)
                    } else if value.viewer.registration != nil {
                        Text("Состав зафиксирован.").font(.subheadline).foregroundStyle(.secondary)
                    }
                } header: { Text("Участие") } footer: {
                    Text("Запись не является оплатой или бронированием корта. Условия согласуйте с организатором.")
                }
                Section("Участники") {
                    ForEach(value.registrations) { registration in
                        HStack {
                            NavigationLink(value: Route.player(registration.id)) {
                                PlayerRow(card: registration.player, subtitle: registration.status == "invited" ? "Ожидается согласие в пару" : "Запись подтверждена")
                            }
                            if value.viewer.isOrganizer && value.rosterIsOpen {
                                Button("Удалить", systemImage: "person.badge.minus", role: .destructive) { removing = registration }
                                    .labelStyle(.iconOnly).disabled(working || !app.isOnline)
                            }
                        }
                    }
                }
                if value.kind == .tournament {
                    tournament(value)
                }
                if value.viewer.isOrganizer {
                    Section("Управление") {
                        if value.rosterIsOpen {
                            Button("Изменить время и условия") { editing = true }
                                .disabled(working || !app.isOnline)
                                .accessibilityIdentifier("event.edit")
                        }
                        if value.kind == .training && value.status == .open && value.endsAt <= .now {
                            Button("Завершить тренировку") { manage("complete") }.disabled(working || !app.isOnline)
                        }
                        if value.status != .cancelled && value.status != .completed {
                            Button("Отменить событие", role: .destructive) { cancelled = true }.disabled(working || !app.isOnline)
                        }
                    }
                }
            } else if let failure = event.error {
                ErrorStateView(error: failure) { Task { await event.load(using: app) } }
            } else { ProgressView() }
            if let error { SettingsErrorRow(message: error) }
            if working { ProgressView() }
        }
        .navigationTitle(event.value?.kind.singular ?? "Событие")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: successCount)
        .sensoryFeedback(.error, trigger: failureCount)
        .refreshable { await event.load(using: app) }
        .task(id: "\(app.dataRevision):\(scenePhase)") {
            guard scenePhase == .active else { return }
            await event.load(using: app)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await event.load(using: app)
            }
        }
        .sheet(item: $score) { game in
            if let value = event.value {
                EventScoreView(eventId: eventId, game: game, total: value.pointsPerGame, allowsTie: value.format != .kingCourt)
                    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $editing) {
            if let value = event.value { EventEditView(event: value) }
        }
        .alert("Отменить событие?", isPresented: $cancelled) {
            Button("Отменить событие", role: .destructive) { manage("cancel") }
            Button("Назад", role: .cancel) {}
        }
        .alert("Отменить запись участника?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Удалить", role: .destructive) {
                if let removing { mutate(.empty(.post, path + "/participants/\(removing.id)/remove", retryable: true)) }
                removing = nil
            }
            Button("Назад", role: .cancel) { removing = nil }
        } message: { Text("Для турнира с постоянными парами будет отменена запись всей пары.") }
    }

    @ViewBuilder private func registration(_ value: SportEvent) -> some View {
        if value.viewer.registration != nil {
            if value.viewer.registration == "invited" {
                Button("Принять приглашение в пару") { register() }.disabled(working || !app.isOnline)
            }
            Button(value.viewer.registration == "invited" ? "Отклонить приглашение" : "Отменить запись", role: .destructive) { manage("leave") }
                .disabled(working || !app.isOnline)
        } else if !(value.kind == .training && value.viewer.isOrganizer) {
            if value.format == .roundRobin {
                Picker("Партнёр", selection: $partner) {
                    Text("Выберите друга").tag(nil as UUID?)
                    ForEach(friends.value?.accepted ?? []) { friend in
                        if !value.registrations.contains(where: { $0.id == friend.id }) {
                            Text(friend.player.displayName).tag(friend.id as UUID?)
                        }
                    }
                }.task { await friends.load(using: app) }
                if let failure = friends.error { SettingsErrorRow(message: failure.message) }
            }
            Button("Записаться") { register(partner: value.format == .roundRobin ? partner : nil) }
                .buttonStyle(.padelPrimary)
                .disabled(working || !app.isOnline || value.registeredCount >= value.capacity || (value.format == .roundRobin && partner == nil))
        }
    }

    @ViewBuilder private func tournament(_ value: SportEvent) -> some View {
        Section("Раунды · \(value.currentRound) / \(value.roundCount)") {
            Text("\(value.pointsPerGame) очков на игру. Итоги учитывают только счёт, подтверждённый всеми четырьмя игроками.")
                .font(.subheadline).foregroundStyle(.secondary)
            if value.viewer.isOrganizer && value.currentRound < value.roundCount && value.startsAt <= .now && (value.status == .open || value.status == .running) {
                Button(value.currentRound == 0 ? "Начать турнир" : "Создать следующий раунд") {
                    mutate(.json(.post, path + "/rounds/generate", SportEventRoundBody(expectedRound: value.currentRound), retryable: true))
                }.disabled(working || !app.isOnline || (value.currentRound == 0 && (value.registeredCount != value.capacity || value.registrations.contains { $0.status != "accepted" })) || value.games.contains { !$0.confirmed })
            }
            ForEach(value.games) { game in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Раунд \(game.round) · Корт \(game.court)").font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        StatusPill(text: game.confirmed ? "Подтверждено" : "Подтверждений: \(game.confirmations.count) / 4",
                                   color: game.confirmed ? Theme.positive : Color.secondary,
                                   symbol: game.confirmed ? "checkmark" : nil)
                    }
                    EventGameLine(names: game.team1.map(\.displayName), points: game.points1,
                                  leads: (game.points1 ?? 0) > (game.points2 ?? 0))
                    EventGameLine(names: game.team2.map(\.displayName), points: game.points2,
                                  leads: (game.points2 ?? 0) > (game.points1 ?? 0))
                    if !game.confirmed && value.status == .running {
                        if value.viewer.isOrganizer || app.me.map({ game.playerIDs.contains($0.userId) }) == true {
                            Button(game.points1 == nil ? "Внести счёт" : "Исправить счёт") { score = game }.disabled(working || !app.isOnline)
                        }
                        if let me = app.me?.userId, game.playerIDs.contains(me), !game.confirmations.contains(me), game.points1 != nil {
                            Button("Подтвердить этот счёт") {
                                mutate(.json(.post, path + "/games/\(game.id)/confirm", SportEventConfirmBody(version: game.version), retryable: true))
                            }.disabled(working || !app.isOnline)
                        }
                    }
                }.padding(.vertical, 6)
            }
        }
        Section("Таблица результатов") {
            ForEach(value.standings) { standing in
                HStack(spacing: 12) {
                    Text("\(standing.rank)")
                        .font(.display(.subheadline, weight: .bold)).monospacedDigit()
                        .foregroundStyle(standing.rank == 1 ? Theme.ink : Color.primary)
                        .frame(width: 32, height: 32)
                        .background(standing.rank == 1 ? AnyShapeStyle(Theme.lime) : AnyShapeStyle(Theme.inset), in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(standing.players.map(\.displayName).joined(separator: " + ")).font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Игр: \(standing.played) · Побед: \(standing.wins)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text("\(standing.points)").font(.display(.title3, weight: .bold)).monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(standing.rank). " + standing.players.map(\.displayName).joined(separator: " + ")
                    + ". Очков: \(standing.points), игр: \(standing.played), побед: \(standing.wins)")
            }
            Text("Очки турнира не меняют спортивный рейтинг Padel ID.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func register(partner: UUID? = nil) { mutate(.json(.post, path + "/register", SportEventRegisterBody(partnerId: partner), retryable: true)) }
    private func manage(_ action: String) { mutate(.empty(.post, path + "/" + action, retryable: true)) }
    private func mutate(_ endpoint: Endpoint) {
        guard !working else { return }
        working = true; error = nil
        Task {
            defer { working = false }
            do {
                let value = try await app.api.send(endpoint, as: SportEvent.self)
                event.replace(with: value); app.dataDidChange()
                successCount += 1
            } catch let failure as APIError {
                self.error = failure.message
                failureCount += 1
                await event.load(using: app)
            } catch { self.error = "Действие не подтверждено. Обновите событие и повторите." }
        }
    }
}

private struct EventScoreView: View {
    let eventId: UUID
    let game: SportEventGame
    let total: Int
    let allowsTie: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var points = 0
    @State private var pending: SportEventScoreBody?
    @State private var canonicalGame: SportEventGame?
    @State private var needsReload = false
    @State private var noLongerEditable = false
    @State private var working = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(game.team1.map(\.displayName).joined(separator: " + "))
                    Stepper("Очков первой пары: \(points)", value: $points, in: 0...total)
                    LabeledContent("Очков второй пары", value: String(total - points))
                    Text(game.team2.map(\.displayName).joined(separator: " + "))
                }.disabled(working || pending != nil || needsReload || noLongerEditable)
                Section {
                    Text("Изменение счёта сбрасывает прежние подтверждения. Каждый игрок должен подтвердить новую версию.")
                    if !allowsTie && points * 2 == total { Text("В Короле корта нужен победитель.").foregroundStyle(Theme.attention) }
                    if let error { SettingsErrorRow(message: error) }
                    if needsReload {
                        Button("Обновить счёт") {
                            working = true
                            Task { defer { working = false }; await reloadAfterConflict() }
                        }
                            .disabled(working || !app.isOnline)
                    }
                    Button(pending == nil ? "Сохранить счёт" : "Повторить сохранение") { save() }
                        .buttonStyle(.padelPrimary).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                        .disabled(working || needsReload || noLongerEditable || !app.isOnline || (!allowsTie && points * 2 == total))
                        .accessibilityIdentifier("eventScore.save")
                    if working { ProgressView() }
                }
            }
            .navigationTitle("Счёт раунда")
            .toolbar { Button("Закрыть") { dismiss() }.disabled(working) }
            .onAppear { points = game.points1 ?? total / 2 }
        }
    }
    private func save() {
        guard !working else { return }
        let body = pending ?? SportEventScoreBody(version: canonicalGame?.version ?? game.version, points1: points, points2: total - points)
        pending = body; working = true; error = nil
        Task {
            defer { working = false }
            do {
                _ = try await app.api.send(.json(.put, "v1/events/\(eventId)/games/\(game.id)/score", body, retryable: true), as: SportEvent.self)
                app.dataDidChange(); dismiss()
            } catch let failure as APIError {
                error = failure.message
                if failure.permitsSubmissionCorrection {
                    // A definitive rejection permits correction; uncertain
                    // transport/decoding retains the exact submitted payload.
                    pending = nil
                    if failure.status == 409 {
                        needsReload = true
                        await reloadAfterConflict()
                    }
                }
            }
            catch { self.error = "Сохранение не подтверждено. Повторите запрос." }
        }
    }

    private func reloadAfterConflict() async {
        do {
            let event = try await app.api.send(.get("v1/events/\(eventId)"), as: SportEvent.self)
            guard let fresh = event.games.first(where: { $0.id == game.id }) else {
                noLongerEditable = true; needsReload = false
                error = "Игра больше недоступна. Закройте окно и обновите событие."
                return
            }
            canonicalGame = fresh
            points = fresh.points1 ?? total / 2
            needsReload = false
            noLongerEditable = fresh.confirmed || event.status != .running
            error = noLongerEditable ? "Этот счёт уже зафиксирован. Закройте окно и обновите событие."
                                    : "Счёт изменился. Загружена актуальная версия; проверьте значения перед сохранением."
        } catch let failure as APIError { error = failure.message }
        catch { self.error = "Не удалось загрузить актуальный счёт. Повторите обновление." }
    }
}

/// One pair of a tournament game with its points, the leading pair on lime.
private struct EventGameLine: View {
    let names: [String]
    let points: Int?
    let leads: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(names.joined(separator: " + "))
                .font(leads ? .body.weight(.semibold) : .body)
                .foregroundStyle(leads || points == nil ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(points.map(String.init) ?? "–")
                .font(.display(.subheadline, weight: .bold)).monospacedDigit()
                .foregroundStyle(leads ? Theme.ink : Color.secondary)
                .frame(minWidth: 40, minHeight: 32)
                .background(leads ? AnyShapeStyle(Theme.lime) : AnyShapeStyle(Theme.inset), in: .rect(cornerRadius: 9, style: .continuous))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(names.joined(separator: " и ") + (points.map { ", очков: \($0)" } ?? ", счёт не внесён"))
    }
}
