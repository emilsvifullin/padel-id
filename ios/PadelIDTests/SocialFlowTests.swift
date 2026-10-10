import Foundation
import Testing
@testable import PadelID

@MainActor
@Suite("Scheduled result editor", .timeLimit(.minutes(1)))
struct SocialFlowTests {
    private func canonicalJSON(_ data: Data?) throws -> Data {
        let body = try #require(data)
        let value = try JSONSerialization.jsonObject(with: body)
        return try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
    }

    private func editor() throws -> (UpcomingMatch, MatchEditorModel, UUID) {
        let game = try FixtureLoader.decode(UpcomingMatch.self, "upcoming_result_ready")
        let meId = game.organizer.id
        let model = MatchEditorModel(request: MatchEditorRequest(mode: .upcoming(game, playerId: meId)))
        model.prepare(meId: meId)
        model.setScore(SetScore(t1: 6, t2: 4), at: 0)
        model.setScore(SetScore(t1: 6, t2: 3), at: 1)
        return (game, model, meId)
    }

    @Test("A scheduled result starts with the admitted players, published type and club")
    func admittedLineup() throws {
        let (game, model, meId) = try editor()
        // Use the fixture's date, so this regression does not expire after the
        // server's fourteen-day result-entry window.
        let now = game.startsAt.addingTimeInterval(3_600)
        let body = try #require(model.makeBody(meId: meId, now: now))
        #expect(Set(body.players.map(\.playerId)) == Set(game.participants.map { $0.id.uuidString.lowercased() }))
        #expect(body.players.count == 4)
        #expect(body.matchType == game.matchType)
        #expect(body.clubId == game.club?.id)
        #expect(model.draft.playedAt == game.startsAt)
        #expect(model.createPath == "v1/upcoming-matches/" + game.id.uuidString.lowercased() + "/result")

        // Changing sides and team pairs remains possible without changing the
        // set of admitted people.
        model.swapSides(team: 1)
        model.swapSides(team: 2)
        #expect(model.makeBody(meId: meId, now: now) != nil)
    }

    @Test("A substituted player, different type, club or pre-start date cannot become a linked result")
    func rejectChangesToPublishedGame() throws {
        let (game, model, meId) = try editor()
        let now = game.startsAt.addingTimeInterval(3_600)
        let baseline = model.draft
        let outsider = PlayerCard(id: UUID(), username: "another_player", displayName: "Другой игрок",
                                  deleted: false, avatarPath: nil, city: game.city, club: game.club,
                                  preferredSide: .both, isCoach: false, level: 4, reliability: 80)
        model.draft.partner = outsider
        #expect(model.makeBody(meId: meId, now: now) == nil)

        model.draft = baseline
        model.draft.matchType = game.matchType == .ranked ? .friendly : .ranked
        #expect(model.makeBody(meId: meId, now: now) == nil)

        model.draft = baseline
        model.draft.club = NamedRef(id: 999_999, name: "Другой клуб")
        #expect(model.makeBody(meId: meId, now: now) == nil)
        model.draft.club = nil
        #expect(model.makeBody(meId: meId, now: now) == nil)

        model.draft = baseline
        model.draft.playedAt = game.startsAt.addingTimeInterval(-1)
        #expect(model.makeBody(meId: meId, now: now) == nil)
    }

    @Test("Selecting an admitted opponent as partner swaps positions without removing a participant")
    func reassignAdmittedPlayersWithoutEmptySlots() throws {
        let (game, model, meId) = try editor()
        let previousPartner = try #require(model.draft.partner)
        let opponent = try #require(model.draft.opponentRight)
        let target: EditorSlot = model.draft.mySide == .right ? .team1Left : .team1Right
        model.setPlayer(opponent, at: target)
        #expect(model.draft.partner?.id == opponent.id)
        #expect(model.draft.opponentRight?.id == previousPartner.id)
        let body = try #require(model.makeBody(meId: meId, now: game.startsAt.addingTimeInterval(3_600)))
        #expect(Set(body.players.map(\.playerId)) == Set(game.participants.map { $0.id.uuidString.lowercased() }))
        #expect(body.players.count == 4)
    }

    @Test("A linked result cannot substitute its editor or start from a nonparticipant")
    func rejectUnadmittedEditor() throws {
        let (game, model, _) = try editor()
        let foreignPlayer = UUID()
        let now = game.startsAt.addingTimeInterval(3_600)
        #expect(model.makeBody(meId: foreignPlayer, now: now) == nil)
        let unadmitted = MatchEditorModel(request: MatchEditorRequest(mode: .upcoming(game, playerId: foreignPlayer)))
        unadmitted.setScore(SetScore(t1: 6, t2: 4), at: 0)
        unadmitted.setScore(SetScore(t1: 6, t2: 3), at: 1)
        #expect(unadmitted.makeBody(meId: foreignPlayer, now: now) == nil)
    }

    @Test("Editing an existing linked result preserves the published roster, type, club and start boundary")
    func existingLinkedResultCannotBypassConstraints() throws {
        let detail = try FixtureLoader.decode(MatchDetail.self, "upcoming_linked_result")
        let startsAt = try #require(detail.scheduledStartsAt)
        #expect(detail.scheduledMatchId != nil)
        let model = MatchEditorModel(request: MatchEditorRequest(mode: .edit(detail)))
        model.prepare(meId: detail.createdBy)
        let now = detail.playedAt.addingTimeInterval(3_600)
        let original = model.draft
        #expect(model.isScheduledResult)
        #expect(model.makeBody(meId: detail.createdBy, now: now) != nil)
        #expect(Set(model.allowedPlayers?.map(\.id) ?? []) == Set(detail.players.map(\.player.id).filter { $0 != detail.createdBy }))

        model.draft.matchType = detail.matchType == .ranked ? .friendly : .ranked
        #expect(model.makeBody(meId: detail.createdBy, now: now) == nil)
        model.draft = original
        model.draft.club = nil
        #expect(model.makeBody(meId: detail.createdBy, now: now) == nil)
        model.draft = original
        model.draft.playedAt = startsAt.addingTimeInterval(-1)
        #expect(model.makeBody(meId: detail.createdBy, now: now) == nil)
        model.draft = original
        let foreign = PlayerCard(id: UUID(), username: "foreign", displayName: "Другой игрок", deleted: false,
                                 avatarPath: nil, city: nil, club: nil, preferredSide: .both, isCoach: false, level: 4, reliability: 80)
        model.draft.partner = foreign
        #expect(model.makeBody(meId: detail.createdBy, now: now) == nil)
        model.draft = original
        let previousPartner = try #require(model.draft.partner)
        let opponent = try #require(model.draft.opponentRight)
        model.setPlayer(opponent, at: model.draft.mySide == .right ? .team1Left : .team1Right)
        #expect(model.draft.partner?.id == opponent.id)
        #expect(model.draft.opponentRight?.id == previousPartner.id)
        let body = try #require(model.makeBody(meId: detail.createdBy, now: now))
        #expect(Set(body.players.map(\.playerId)) == Set(detail.players.map { $0.player.id.uuidString.lowercased() }))
    }

    @Test("An interrupted linked result persists its endpoint and key, then retries as one operation")
    func linkedResultSurvivesTransportFailure() async throws {
        let (game, model, meId) = try editor()
        // Submitting uses the real clock. Entering the actual result now is
        // valid even when this generated fixture is older than fourteen days.
        model.draft.playedAt = max(.now, game.startsAt)
        let baseURL = StubURLProtocol.makeBaseURL()
        let userId = UUID()
        let store = SessionStore()
        store.save(Session(accessToken: "access-token-scheduled-test-0123456789", refreshToken: "refresh-token-scheduled-test",
                           expiresIn: 3_600, expiresAt: Int(Date().timeIntervalSince1970) + 3_600,
                           user: AuthUser(id: userId, email: "test@padelid.app")))
        let client = APIClient(baseURL: baseURL, sessionStore: store, urlSession: StubURLProtocol.makeURLSession())
        let app = AppModel(api: client)
        app.outbox.activate(userId: userId)
        defer {
            app.outbox.purge()
            store.clear()
            StubURLProtocol.unregister(baseURL)
        }
        StubURLProtocol.register(baseURL) { _ in .transportFailure(.networkConnectionLost) }

        let outcome = await model.submit(app: app, meId: meId)
        guard case .queued = outcome else {
            Issue.record("A transport failure must queue the scheduled result")
            return
        }
        // The editor starts an immediate outbox pass. Let it finish before
        // testing the persisted retry, without depending on elapsed time.
        await Task.yield()
        await app.flushOutbox()
        while app.outbox.isProcessing { await Task.yield() }
        #expect(model.isFinished)
        #expect(app.outbox.pending.count == 1)
        let queued = try #require(app.outbox.pending.first)
        #expect(queued.kind == .createMatch)
        #expect(queued.method == "POST")
        #expect(queued.path == model.createPath)
        #expect(queued.idempotencyKey == model.idempotencyKey)
        let firstRequest = try #require(StubURLProtocol.requests(baseURL).first)
        #expect(firstRequest.path == "/" + model.createPath)
        #expect(firstRequest.header("Idempotency-Key") == model.idempotencyKey.uuidString.lowercased())
        // Online submission and enqueue encode the same typed body separately.
        // Object key ordering is immaterial to JSON and may differ; all actual
        // payload values, array order and the idempotency key must agree.
        let initialPayload = try canonicalJSON(firstRequest.body)
        let queuedPayload = try canonicalJSON(queued.body)
        #expect(initialPayload == queuedPayload)

        let restored = Outbox()
        restored.activate(userId: userId)
        defer { restored.purge() }
        #expect(restored.pending.count == 1)
        #expect(restored.pending.first?.id == queued.id)
        #expect(restored.pending.first?.body == queued.body)
        #expect(restored.pending.first?.idempotencyKey == queued.idempotencyKey)

        let result = try FixtureLoader.data("match_created")
        StubURLProtocol.register(baseURL) { _ in .data(200, result) }
        await restored.process(with: client)
        #expect(restored.operations.isEmpty)
        let retry = try #require(StubURLProtocol.requests(baseURL).first)
        #expect(retry.path == firstRequest.path)
        #expect(retry.body == queued.body)
        #expect(retry.header("Idempotency-Key") == firstRequest.header("Idempotency-Key"))
        await restored.process(with: client)
        #expect(StubURLProtocol.requests(baseURL).count == 1)

        let secondSubmit = await model.submit(app: app, meId: meId)
        guard case .failed = secondSubmit else {
            Issue.record("A finished editor must not submit its result twice")
            return
        }
        #expect(StubURLProtocol.requests(baseURL).count == 1)
    }
}
