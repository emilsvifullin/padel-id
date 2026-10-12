import Foundation
import Testing
@testable import PadelID

@MainActor
@Suite("Community transport and privacy regressions")
struct CommunityTests {
    @Test func lateChatResponseDoesNotReopenAProfileTheUserAlreadyLeft() {
        let navigation = NavigationRouter()
        let profile = Route.player(UUID())
        navigation.path = [.friends, .findPlayers, profile]
        let source = navigation.path
        // A creation response can arrive after the user pressed Back.
        navigation.path.removeLast()
        let returnedPath = navigation.path
        navigation.push(.conversation(UUID()), from: source)
        #expect(navigation.path == returnedPath)

        // While the source is still shown, the same response adds a normal
        // value destination and retains the full history for Back.
        navigation.path = source
        let chat = Route.conversation(UUID())
        navigation.push(chat, from: source)
        #expect(navigation.path == source + [chat])
    }

    @Test func diagnosticsDoesNotTreatHTMLAsAPISuccessOrSendCredentials() async {
        let url = StubURLProtocol.makeBaseURL()
        StubURLProtocol.register(url) { _ in .json(200, "<html>Challenge</html>") }
        defer { StubURLProtocol.unregister(url) }
        let diagnostics = NetworkDiagnostics(baseURL: url, session: StubURLProtocol.makeURLSession())
        await diagnostics.run()
        #expect(diagnostics.probes.count == 2)
        #expect(diagnostics.probes.allSatisfy { !$0.apiOK })
        #expect(StubURLProtocol.requests(url).allSatisfy { $0.header("Authorization") == nil })
    }

    @Test func diagnosticsKeepsWorkingGatewaySeparateFromFailedDatabase() async {
        let url = StubURLProtocol.makeBaseURL()
        StubURLProtocol.register(url) { request in
            if request.request.url?.query() == "deep=1" { return .error(503, code: "service_unavailable", message: "Недоступно") }
            return .json(200, "{\"status\":\"ok\"}")
        }
        defer { StubURLProtocol.unregister(url) }
        let diagnostics = NetworkDiagnostics(baseURL: url, session: StubURLProtocol.makeURLSession())
        await diagnostics.run()
        #expect(diagnostics.probes.first?.apiOK == true)
        #expect(diagnostics.probes.last?.apiOK == false)
        #expect(diagnostics.probes.last?.status == 503)
        #expect(diagnostics.probes.last?.databaseOK == false)
    }

    @Test func diagnosticsRetainsDNSFailureAndMakesNoDatabaseClaim() async {
        let url = StubURLProtocol.makeBaseURL()
        StubURLProtocol.register(url) { _ in .transportFailure(.cannotFindHost) }
        defer { StubURLProtocol.unregister(url) }
        let diagnostics = NetworkDiagnostics(baseURL: url, session: StubURLProtocol.makeURLSession())
        await diagnostics.run()
        #expect(diagnostics.probes.count == 1)
        #expect(diagnostics.probes.first?.code == URLError.cannotFindHost.rawValue)
        #expect(diagnostics.probes.first?.errorDomain == NSURLErrorDomain)
        #expect(diagnostics.probes.first?.databaseOK == nil)
    }

    @Test func diagnosticsChecksTheIndependentGatewayWhenThePrimaryHasNoConnection() async {
        let primary = StubURLProtocol.makeBaseURL(), fallback = StubURLProtocol.makeBaseURL().appending(path: "functions/v1/gateway")
        defer { StubURLProtocol.unregister(primary); StubURLProtocol.unregister(fallback) }
        StubURLProtocol.register(primary) { _ in .transportFailure(.cannotConnectToHost) }
        StubURLProtocol.register(fallback) { _ in .json(200, #"{"status":"ok","database":"ok"}"#) }
        let diagnostics = NetworkDiagnostics(baseURL: primary, session: StubURLProtocol.makeURLSession(), fallbackURLs: [fallback])
        await diagnostics.run()
        #expect(diagnostics.probes.count == 3)
        #expect(diagnostics.probes[0].apiOK == false)
        #expect(diagnostics.probes[1].apiOK == true)
        #expect(diagnostics.probes[2].databaseOK == true)
        #expect(StubURLProtocol.requests(fallback).map(\.path) == ["/functions/v1/gateway/v1/health", "/functions/v1/gateway/v1/health"])
        #expect((StubURLProtocol.requests(primary) + StubURLProtocol.requests(fallback)).allSatisfy { $0.header("Authorization") == nil && $0.body == nil })
    }

    @Test(arguments: [401, 403, 404])
    func revokedMembershipClearsVisibleChatMessagesAndOverridesSendFailure(status: Int) async throws {
        let context = CommunityTestContext()
        defer { context.close() }
        let calls = StubCounter()
        let chat = Self.conversation()
        let chatData = try JSONCoding.encoder.encode(chat)
        let message = Self.message(conversation: chat.id)
        let messageJSON = String(decoding: try JSONCoding.encoder.encode(message), as: UTF8.self)
        StubURLProtocol.register(context.url) { request in
            if request.method == "POST", request.path.hasSuffix("/messages") {
                return .error(503, code: "service_unavailable", message: "Отправка не подтверждена")
            }
            if request.path.hasSuffix("/read") { return .json(200, "{\"ok\":true}") }
            if request.path.hasSuffix("/messages") { return .json(200, "{\"items\":[\(messageJSON)],\"next_before\":null,\"latest_id\":1}") }
            if calls.next() == 1 { return .data(200, chatData) }
            return .error(status, code: "conversation_access_denied", message: "Чат недоступен")
        }
        let model = ChatModel(id: chat.id)
        await model.load(using: context.app)
        #expect(model.messages.count == 1)
        #expect(await model.send("Давайте сыграем", using: context.app) == false)
        #expect(model.error == "Сервис временно недоступен. Попробуйте через минуту.")
        await model.load(using: context.app, poll: true)
        #expect(model.messages.isEmpty)
        #expect(model.conversation == nil)
        #expect(model.error == "Чат недоступен")
    }

    @Test func successfulPollPreservesUnconfirmedSendFeedbackAndRetryIdentity() async throws {
        let context = CommunityTestContext()
        defer { context.close() }
        let chat = Self.conversation()
        let detail = try JSONCoding.encoder.encode(chat)
        let message = Self.message(conversation: chat.id)
        let confirmed = try JSONCoding.encoder.encode(message)
        let sends = StubCounter()
        StubURLProtocol.register(context.url) { request in
            if request.method == "POST", request.path.hasSuffix("/messages") {
                return sends.next() <= 3
                    ? .error(503, code: "service_unavailable", message: "Отправка не подтверждена")
                    : .data(201, confirmed)
            }
            if request.path.hasSuffix("/messages") { return .json(200, "{\"items\":[]}") }
            return .data(200, detail)
        }
        let model = ChatModel(id: chat.id)
        await model.load(using: context.app)
        #expect(await model.send("Давайте сыграем", using: context.app) == false)
        let failedFeedback = try #require(model.error)
        #expect(model.messages.isEmpty)
        await model.load(using: context.app, poll: true)
        #expect(model.error == failedFeedback)
        #expect(model.conversation?.id == chat.id)
        #expect(model.messages.isEmpty)
        #expect(await model.send("Давайте сыграем", using: context.app) == true)
        #expect(model.error == nil)
        #expect(model.messages.map(\.id) == [message.id])
        let requests = StubURLProtocol.requests(context.url).filter { $0.method == "POST" && $0.path.hasSuffix("/messages") }
        #expect(requests.count == 4)
        let first = try #require(requests.first)
        #expect(first.header("Idempotency-Key") != nil)
        #expect(first.jsonBody()["body"] == "Давайте сыграем")
        #expect(requests.allSatisfy { $0.header("Idempotency-Key") == first.header("Idempotency-Key") && $0.body == first.body })
        #expect(requests.allSatisfy { $0.header("Authorization") != nil })
    }

    @Test func uncertainSendKeepsTheRetryKeyAndDoesNotShowUnconfirmedMessage() async throws {
        let context = CommunityTestContext()
        defer { context.close() }
        let calls = StubCounter()
        let chat = Self.conversation()
        let message = Self.message(conversation: chat.id)
        let data = try JSONCoding.encoder.encode(message)
        StubURLProtocol.register(context.url) { _ in
            if calls.next() == 1 { return .transportFailure(.networkConnectionLost) }
            return .data(201, data)
        }
        let model = ChatModel(id: chat.id)
        #expect(await model.send("Давайте сыграем", using: context.app) == false)
        #expect(model.messages.isEmpty)
        #expect(model.error != nil)
        #expect(await model.send("Давайте сыграем", using: context.app) == true)
        #expect(model.messages.count == 1)
        let requests = StubURLProtocol.requests(context.url)
        #expect(requests.count == 2)
        #expect(requests.first?.header("Idempotency-Key") == requests.last?.header("Idempotency-Key"))
        #expect(requests.allSatisfy { $0.header("Authorization") != nil })
    }

    @Test func pollingRemovesBlockedMessagesAndReplacesModeratedBodies() async throws {
        let context = CommunityTestContext()
        defer { context.close() }
        let chat = Self.conversation()
        let detail = try JSONCoding.encoder.encode(chat)
        let calls = StubCounter()
        let original = [Self.message(conversation: chat.id), Self.message(conversation: chat.id, id: 2)]
        let moderated = Self.message(conversation: chat.id, id: 2, body: "Сообщение скрыто", deleted: true)
        let initialJSON = String(decoding: try JSONCoding.encoder.encode(original), as: UTF8.self)
        let updatedJSON = String(decoding: try JSONCoding.encoder.encode([moderated]), as: UTF8.self)
        StubURLProtocol.register(context.url) { request in
            if request.path.hasSuffix("/read") { return .json(200, "{\"ok\":true}") }
            if request.path.hasSuffix("/messages") {
                let items = calls.next() == 1 ? initialJSON : updatedJSON
                return .json(200, "{\"items\":\(items),\"next_before\":null,\"latest_id\":2}")
            }
            return .data(200, detail)
        }
        let model = ChatModel(id: chat.id)
        await model.load(using: context.app)
        #expect(model.messages.count == 2)
        await model.load(using: context.app, poll: true)
        #expect(model.messages.map(\.id) == [2])
        #expect(model.messages.first?.deleted == true)
        #expect(model.messages.first?.body == "Сообщение скрыто")
        let polls = StubURLProtocol.requests(context.url).filter { $0.path.hasSuffix("/messages") }
        #expect(polls.last?.request.url?.query()?.contains("after_id=0") == true)
    }

    @Test func authoritativeForbiddenClearsPrivateResourceAndItsCache() async throws {
        let context = CommunityTestContext()
        defer { context.close() }
        let chat = Self.conversation()
        let data = try JSONCoding.encoder.encode(chat)
        let key = "private-resource-\(UUID())"
        context.app.cache.activate(userId: UUID())
        defer { context.app.cache.remove(key); context.app.cache.activate(userId: nil) }
        context.app.cache.store(data, for: key)
        StubURLProtocol.register(context.url) { _ in .error(403, code: "forbidden", message: "Недоступно") }
        let resource = Resource<Conversation>(cacheKey: key) { .get("v1/conversations/\(chat.id)") }
        await resource.load(using: context.app)
        #expect(resource.value == nil)
        #expect(resource.error?.status == 403)
        #expect(!resource.isStale)
        #expect(context.app.cache.data(for: key) == nil)
    }

    @Test func groupDiscoveryDecodesTheActualCatalogContract() throws {
        let raw = "{\"items\":[{\"id\":\"\(UUID())\",\"title\":\"Падел по средам\",\"description\":null,\"visibility\":\"public\",\"city_id\":1,\"club_id\":null,\"owner_id\":\"\(UUID())\",\"member_count\":5,\"joined\":false}],\"next_offset\":null}"
        let page = try JSONCoding.decoder.decode(CommunityPage<SocialGroup>.self, from: Data(raw.utf8))
        #expect(page.items.first?.joined == false)
        #expect(page.items.first?.memberCount == 5)
    }

    @Test func followStateUsesTheProfileContractAndKeepsLegacyProfilesCompatible() throws {
        let oldData = try FixtureLoader.data("player_profile")
        let legacy = try JSONCoding.decoder.decode(PlayerProfileResponse.self, from: oldData)
        #expect(legacy.isFollowing == nil)
        var object = try #require(JSONSerialization.jsonObject(with: oldData) as? [String: Any])
        object["is_following"] = true
        let updated = try JSONCoding.decoder.decode(PlayerProfileResponse.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(updated.isFollowing == true)
        #expect(updated.profile.id == legacy.profile.id)
    }

    @Test func competingEventUpdateKeepsUserDraftAndAdoptsUntouchedFields() throws {
        let original = try Self.editableEvent()
        let fresh = try Self.editableEvent(changes: ["title": "Название с другого устройства", "location": "Новый корт",
            "city": ["id": 2, "name": "Казань"], "club": ["id": 20, "name": "Новый клуб"],
            "price_rub": 1200, "metadata_version": 2])
        var draft = SportEventEditDraft(event: original)
        draft.title = "Мой незавершённый перенос"
        draft.reconcile(from: original, to: fresh)
        #expect(draft.title == "Мой незавершённый перенос")
        #expect(draft.location == "Новый корт")
        #expect(draft.city?.id == 2 && draft.club?.id == 20)
        #expect(draft.hasPrice && draft.priceText == "1200")
        #expect(fresh.editingVersion == 2)
    }

    @Test func eventConflictPreservesAllEditedValuesAndCoherentCityClubPair() throws {
        let original = try Self.editableEvent()
        let fresh = try Self.editableEvent(changes: ["title": "Сервер", "description": "Новые условия", "duration_minutes": 120,
            "starts_at": "2026-12-12T10:00:00Z", "location": "Другой корт", "specialization": "Подача",
            "city": ["id": 2, "name": "Казань"], "club": ["id": 20, "name": "Другой клуб"], "price_rub": 2000])
        var draft = SportEventEditDraft(event: original)
        draft.title = "Мой турнир"; draft.description = "Мои условия"; draft.duration = 90
        draft.startsAt = original.startsAt.addingTimeInterval(3600); draft.location = "Моё место"
        draft.specialization = "У сетки"; draft.club = NamedRef(id: 11, name: "Мой клуб")
        draft.hasPrice = true; draft.priceText = "1500"
        let intended = draft
        draft.reconcile(from: original, to: fresh)
        #expect(draft == intended)
        #expect(draft.city?.id == 1 && draft.club?.id == 11)
    }

    private static func editableEvent(changes: [String: Any] = [:]) throws -> SportEvent {
        var raw: [String: Any] = ["id": "883c2d69-b1b2-44c2-9838-38169a20ed66", "kind": "training", "format": "group",
            "title": "Тренировка", "description": "Исходные условия", "organizer": ["id": UUID().uuidString, "username": "coach",
                "display_name": "Тренер", "deleted": false, "is_coach": true],
            "starts_at": "2026-12-10T10:00:00Z", "duration_minutes": 60, "city": ["id": 1, "name": "Москва"],
            "club": ["id": 10, "name": "Клуб"], "location": "Корт 1", "capacity": 4, "min_level": 0, "max_level": 7,
            "round_count": 0, "points_per_game": 21, "current_round": 0, "status": "open", "registered_count": 1,
            "viewer": ["is_organizer": true], "registrations": [], "games": [], "standings": [], "metadata_version": 1]
        raw.merge(changes) { _, new in new }
        return try JSONCoding.decoder.decode(SportEvent.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    private static func player() -> PlayerCard {
        PlayerCard(id: UUID(), username: "tester", displayName: "Игрок", deleted: false, avatarPath: nil, city: nil, club: nil,
                   preferredSide: nil, isCoach: false, level: nil, reliability: nil)
    }
    private static func conversation() -> Conversation {
        Conversation(id: UUID(), kind: "direct", title: "Игрок", description: nil, visibility: "private", gameId: nil,
                     cityId: nil, clubId: nil, ownerId: nil, createdAt: .now, updatedAt: .now, members: [], unreadCount: 0, latestMessage: nil)
    }
    private static func message(conversation id: UUID, id messageId: Int64 = 1, body: String = "Давайте сыграем", deleted: Bool = false) -> ChatMessage {
        ChatMessage(id: messageId, conversationId: id, sender: player(), body: body, createdAt: .now, clientId: UUID(), deleted: deleted)
    }
}

@MainActor
private struct CommunityTestContext {
    let url: URL
    let store: SessionStore
    let app: AppModel
    init() {
        url = StubURLProtocol.makeBaseURL()
        store = SessionStore()
        store.save(Session(accessToken: "community-test-access-0123456789", refreshToken: "community-test-refresh-0123456789",
                           expiresIn: 3600, expiresAt: Int(Date.now.timeIntervalSince1970) + 3600, user: AuthUser(id: UUID(), email: "test@example.test")))
        app = AppModel(api: APIClient(baseURL: url, sessionStore: store, urlSession: StubURLProtocol.makeURLSession()))
    }
    func close() { store.clear(); StubURLProtocol.unregister(url) }
}
