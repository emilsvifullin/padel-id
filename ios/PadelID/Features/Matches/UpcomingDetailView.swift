import SwiftUI

struct UpcomingDetailView: View {
    let matchId: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var detail: Resource<UpcomingMatch>
    @State private var isWorking = false
    @State private var error: String?
    @State private var confirmation: String?
    @State private var isInviting = false
    @State private var successCount = 0
    @State private var failureCount = 0

    init(matchId: UUID) {
        self.matchId = matchId
        _detail = State(initialValue: Resource(cacheKey: CacheKey.upcoming(matchId)) {
            .get("v1/upcoming-matches/" + matchId.uuidString.lowercased())
        })
    }

    var body: some View {
        Group {
            if let match = detail.value { content(match) }
            else if let error = detail.error {
                ErrorStateView(error: error) { Task { await detail.load(using: app) } }
            } else { LoadingView() }
        }
        .navigationTitle(detail.value?.visibility == "private" ? "Закрытая игра" : "Открытая игра")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: app.dataRevision) { await detail.load(using: app) }
        .sensoryFeedback(.success, trigger: successCount)
        .sensoryFeedback(.error, trigger: failureCount)
        .sheet(isPresented: $isInviting) { UpcomingInviteView(matchId: matchId).compactSheet() }
        .alert(confirmation == "cancel" ? "Отменить игру?" : "Отменить участие?", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { action in
            Button(action == "cancel" ? "Отменить игру" : "Отменить участие", role: .destructive) {
                confirmation = nil
                perform(action)
            }
            Button("Не отменять", role: .cancel) { confirmation = nil }
        } message: { action in
            Text(action == "cancel" ? "Все участники увидят отмену. Результат этой игры нельзя будет внести." : "Ваше место снова станет свободным.")
        }
    }

    private func content(_ match: UpcomingMatch) -> some View {
        List {
            if detail.isStale, let error = detail.error { StaleDataBanner(error: error) }
            if let error { SettingsErrorRow(message: error) }
            Section {
                UpcomingMatchRow(match: match, prominent: true)
                    .padding(22)
                    .inkCard()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                if let note = match.note, !note.isEmpty { Text(note).fixedSize(horizontal: false, vertical: true) }
                NavigationLink(value: Route.player(match.organizer.id)) {
                    PlayerRow(card: match.organizer, subtitle: "Организатор") {
                        LevelChip(level: match.organizer.level, reliability: match.organizer.reliability)
                    }
                }
            }
            Section("Состав · \(match.participants.count) из 4") {
                ForEach(match.participants) { member in
                    NavigationLink(value: Route.player(member.id)) {
                        PlayerRow(card: member.player) {
                            LevelChip(level: member.player.level, reliability: member.player.reliability)
                        }
                    }
                }
                if match.viewer.canInvite == true {
                    Button("Пригласить друзей", systemImage: "person.badge.plus") { isInviting = true }
                        .disabled(!app.isOnline || isWorking)
                }
                if match.viewer.participation == "accepted" {
                    GameChatButton(gameId: match.id)
                }
            }
            Section {
                participationActions(match)
                if isWorking { ProgressView() }
                if !app.isOnline { SettingsOfflineNotice(message: "Для участия и изменения состава нужно подключение.") }
            } footer: { Text(admissionText(match)) }
            if match.viewer.isOrganizer {
                let pending = match.applications.filter { $0.status == "pending" || $0.status == "waitlisted" || $0.status == "invited" }
                if !pending.isEmpty {
                    Section("Заявки на участие") {
                        ForEach(pending) { application in
                            VStack(alignment: .leading, spacing: 8) {
                                NavigationLink(value: Route.player(application.id)) {
                                    PlayerRow(card: application.player) {
                                        LevelChip(level: application.player.level, reliability: application.player.reliability)
                                    }
                                }
                                Text(application.status == "waitlisted" ? "Лист ожидания" : application.status == "invited" ? "Приглашение отправлено" : "Заявка")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    if application.status != "invited" {
                                        Button("Принять") { review(application.id, accepted: true) }
                                            .buttonStyle(.padelProminent).disabled(match.spotsLeft == 0)
                                    }
                                    Button("Отклонить") { review(application.id, accepted: false) }.buttonStyle(.bordered)
                                }.disabled(isWorking || !app.isOnline || match.isClosed || match.startsAt <= .now)
                            }
                        }
                    }
                }
            }
            if let result = match.resultMatchId {
                Section {
                    NavigationLink(value: Route.match(result)) { Label("Результат и подтверждения", systemImage: "checkmark.circle") }
                } footer: { Text("Участие в игре не подтверждает счёт. Результат засчитывается после подтверждения всеми четырьмя игроками.") }
            } else if match.canEnterResult {
                Section {
                    Button("Внести результат") { if let id = app.me?.userId { app.matchEditor = MatchEditorRequest(mode: .upcoming(match, playerId: id)) } }
                        .disabled(app.outbox.operations.contains { $0.path == path + "/result" })
                        .accessibilityIdentifier("upcoming.result")
                    if app.outbox.operations.contains(where: { $0.path == path + "/result" }) {
                        Text("Результат в очереди отправки. Проверьте его во вкладке «Матчи».").font(.footnote)
                    }
                }
            }
        }
        .refreshable { await detail.load(using: app) }
    }

    @ViewBuilder
    private func participationActions(_ match: UpcomingMatch) -> some View {
        if match.isClosed { Text(match.statusTitle).foregroundStyle(.secondary) }
        else if match.viewer.isOrganizer {
            Button("Отменить игру", role: .destructive) { confirmation = "cancel" }.disabled(!app.isOnline || isWorking)
        } else if match.viewer.participation == "accepted" || match.viewer.participation == "pending" {
            if match.viewer.participation == "pending" { Label("Заявка у организатора", systemImage: "clock") }
            Button(match.viewer.participation == "pending" ? "Отозвать заявку" : "Отменить участие", role: .destructive) {
                if match.viewer.participation == "pending" { perform("leave") } else { confirmation = "leave" }
            }.disabled(!app.isOnline || isWorking || match.startsAt <= .now)
        } else if match.viewer.participation == "invited" {
            Label("Вас пригласили", systemImage: "envelope.open")
            Button("Принять приглашение") { perform("invitations/respond", body: ["decision":"accepted"]) }
                .buttonStyle(.padelPrimary)
                .disabled(match.spotsLeft == 0 || !app.isOnline || isWorking)
            Button("Отклонить", role: .destructive) { perform("invitations/respond", body: ["decision":"declined"]) }
                .disabled(!app.isOnline || isWorking)
            if match.viewer.canWaitlist == true {
                Button("Ждать свободного места") { perform("waitlist") }.disabled(!app.isOnline || isWorking)
            }
        } else if match.viewer.participation == "waitlisted" {
            Label("Вы в листе ожидания", systemImage: "clock")
            Text("Место не зарезервировано. Когда оно освободится, появится уведомление; подтвердите участие отдельно.")
                .font(.footnote).foregroundStyle(.secondary)
            if match.spotsLeft > 0 {
                Button("Присоединиться") { perform("join") }.disabled(!app.isOnline || isWorking)
            }
            Button("Выйти из листа ожидания", role: .destructive) { perform("leave") }.disabled(!app.isOnline || isWorking)
        } else if match.viewer.canJoin {
            Button(match.viewer.admission == "auto" ? "Занять место" : "Подать заявку") { perform("join") }
                .buttonStyle(.padelPrimary).disabled(!app.isOnline || isWorking)
                .accessibilityIdentifier("upcoming.join")
        } else if match.viewer.admission == "out_of_range" {
            Text("Ваш подтверждённый уровень вне диапазона этой игры.").foregroundStyle(.secondary)
        } else if match.viewer.canWaitlist == true {
            Button("Ждать свободного места") { perform("waitlist") }.disabled(!app.isOnline || isWorking)
        } else { Text(match.spotsLeft == 0 ? "Все места заняты" : "Набор завершён").foregroundStyle(.secondary) }
    }

    private func admissionText(_ match: UpcomingMatch) -> String {
        "Автоматическое место: уровень \(Format.level(match.minLevel))–\(Format.level(match.maxLevel)), надёжность от \(match.admission.minReliability)% и минимум \(Format.matches(match.admission.minimumRankedMatches)). При предварительном рейтинге решение принимает организатор."
    }
    private var path: String { "v1/upcoming-matches/" + matchId.uuidString.lowercased() }
    private func review(_ player: UUID, accepted: Bool) {
        perform("requests/" + player.uuidString.lowercased() + "/respond", body: ["decision": accepted ? "accepted" : "rejected"])
    }
    private func perform(_ action: String, body: [String: String] = [:]) {
        guard app.isOnline, !isWorking else { return }
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                let data = try await app.api.data(.json(.post, path + "/" + action, body, retryable: true))
                let fresh = try JSONCoding.decoder.decode(UpcomingMatch.self, from: data)
                if fresh.visibility == "private", !fresh.viewer.isOrganizer,
                   ["leave", "invitations/respond"].contains(action),
                   ["withdrawn", "rejected", "none"].contains(fresh.viewer.participation) {
                    app.cache.remove(CacheKey.upcoming(matchId))
                    app.dataDidChange(); dismiss(); return
                }
                detail.replace(with: fresh, data: data, app: app)
                app.dataDidChange()
                successCount += 1
                Announce.post(action == "join" && fresh.viewer.participation == "pending" ? "Заявка отправлена организатору" : "Игра обновлена")
            } catch let failure as APIError {
                error = failure.message
                failureCount += 1
                Announce.post(failure.message)
                await detail.load(using: app)
            } catch { self.error = "Не удалось обновить игру. Попробуйте снова." }
        }
    }
}
