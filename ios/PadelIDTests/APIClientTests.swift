import Foundation
import Testing
@testable import PadelID

/// APIClient against an in-memory server (StubURLProtocol). Every test uses its
/// own host and its own SessionStore, and clears the stored session at the end.
@MainActor
@Suite("API client", .timeLimit(.minutes(1)))
struct APIClientTests {
    private let userId = UUID()

    private func makeSession(access: String, refresh: String, expiresIn seconds: TimeInterval) -> Session {
        Session(accessToken: access, refreshToken: refresh, expiresIn: 3600,
                expiresAt: Int(Date().timeIntervalSince1970 + seconds),
                user: AuthUser(id: userId, email: "test@padelid.app"))
    }

    private func sessionJSON(_ session: Session) throws -> Data {
        try JSONCoding.encoder.encode(session)
    }

    private func makeClient(_ baseURL: URL, session: Session?) -> (APIClient, SessionStore) {
        let store = SessionStore()
        if let session {
            store.save(session)
        } else {
            store.clear()
        }
        let client = APIClient(baseURL: baseURL, sessionStore: store, urlSession: StubURLProtocol.makeURLSession())
        return (client, store)
    }

    private func finish(_ baseURL: URL, _ store: SessionStore) {
        store.clear()
        StubURLProtocol.unregister(baseURL)
    }

    // MARK: Headers

    @Test("Bearer token, build number and idempotency key are sent")
    func headers() async throws {
        let baseURL = StubURLProtocol.makeBaseURL()
        let session = makeSession(access: "access-token-headers-0123456789", refresh: "refresh-token-headers", expiresIn: 3600)
        let (client, store) = makeClient(baseURL, session: session)
        defer { finish(baseURL, store) }
        StubURLProtocol.register(baseURL) { _ in StubResponse.json(201, #"{"ok": true}"#) }

        let key = UUID()
        let endpoint = Endpoint.json(.post, "v1/matches", ["match_type": "ranked"], idempotencyKey: key)
        _ = try await client.data(endpoint)

        let requests = StubURLProtocol.requests(baseURL)
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/matches")
        #expect(request.header("Authorization") == "Bearer access-token-headers-0123456789")
        #expect(request.header("X-Padelid-Build") == AppEnvironment.buildNumber)
        #expect(request.header("Idempotency-Key") == key.uuidString.lowercased())
        #expect(request.header("Content-Type") == "application/json")
        #expect(request.header("Accept") == "application/json")
        #expect(request.jsonBody()["match_type"] == "ranked")
    }

    @Test("Requests without authentication carry no token")
    func unauthenticated() async throws {
        let baseURL = StubURLProtocol.makeBaseURL()
        let (client, store) = makeClient(baseURL, session: nil)
        defer { finish(baseURL, store) }
        StubURLProtocol.register(baseURL) { _ in StubResponse.json(200, "{}") }

        _ = try await client.data(.json(.post, "v1/auth/login", ["email": "m.orlov@padelid.app", "password": "padel2026"], auth: false))
        let request = try #require(StubURLProtocol.requests(baseURL).first)
        #expect(request.header("Authorization") == nil)
        #expect(request.header("X-Padelid-Build") != nil)
        #expect(request.header("Idempotency-Key") == nil)
        #expect(request.jsonBody()["email"] == "m.orlov@padelid.app")
    }

    // MARK: Errors

    @Test("Error envelope maps to status, code and message")
    func errorEnvelope() async throws {
        let baseURL = StubURLProtocol.makeBaseURL()
        let session = makeSession(access: "access-token-errors-0123456789", refresh: "refresh-token-errors", expiresIn: 3600)
        let (client, store) = makeClient(baseURL, session: session)
        defer { finish(baseURL, store) }
        StubURLProtocol.register(baseURL) { request in
            switch request.path {
            case "/v1/matches/conflict/confirm":
                return StubResponse.error(409, code: "version_conflict", message: "Матч изменён.")
            case "/v1/clubs":
                return StubResponse.error(400, code: "club_name_invalid", message: "Название клуба: от 2 до 60 символов.")
            default:
                return StubResponse.json(500, "upstream exploded")
            }
        }

        do {
            _ = try await client.data(.json(.post, "v1/matches/conflict/confirm", ["version": 1]))
            Testing.Issue.record("Expected version_conflict")
        } catch let error as APIError {
            #expect(error.status == 409)
            #expect(error.code == "version_conflict")
            #expect(error.serverMessage == "Матч изменён.")
            #expect(error.message == "Матч только что изменили. Проверьте актуальный счёт.")
            #expect(!error.isNetwork)
            #expect(!error.isTransient)
        }

        do {
            _ = try await client.data(.json(.post, "v1/clubs", ["name": "X"]))
            Testing.Issue.record("Expected club_name_invalid")
        } catch let error as APIError {
            #expect(error.status == 400)
            #expect(error.code == "club_name_invalid")
            // Codes without client copy fall back to the server's Russian text.
            #expect(error.message == "Название клуба: от 2 до 60 символов.")
        }

        do {
            _ = try await client.data(.json(.post, "v1/matches/preview", ["format": "best_of_3"]))
            Testing.Issue.record("Expected a server error")
        } catch let error as APIError {
            #expect(error.status == 500)
            #expect(error.code == "service_unavailable")
            #expect(error.isTransient)
            #expect(!error.message.isEmpty)
        }
        // Mutations without an idempotency key are never retried.
        #expect(StubURLProtocol.requests(baseURL).count == 3)
    }

    @Test("A transport failure is a network error")
    func networkError() async throws {
        let baseURL = StubURLProtocol.makeBaseURL()
        let session = makeSession(access: "access-token-network-0123456789", refresh: "refresh-token-network", expiresIn: 3600)
        let (client, store) = makeClient(baseURL, session: session)
        defer { finish(baseURL, store) }
        StubURLProtocol.register(baseURL) { _ in StubResponse.transportFailure(.notConnectedToInternet) }

        do {
            _ = try await client.data(.json(.post, "v1/matches/preview", ["format": "best_of_3"]))
            Testing.Issue.record("Expected a network error")
        } catch let error as APIError {
            #expect(error.isNetwork)
            #expect(error.kind == .network)
            #expect(error.status == nil)
            #expect(error.isTransient)
            #expect(error.message == APIError.offline.message)
        }
        #expect(StubURLProtocol.requests(baseURL).count == 1)
    }

    // MARK: Retries

    @Test("A GET is retried after 503 and then succeeds")
    func retriesTransientGet() async throws {
        let baseURL = StubURLProtocol.makeBaseURL()
        let session = makeSession(access: "access-token-retry-0123456789", refresh: "refresh-token-retry", expiresIn: 3600)
        let (client, store) = makeClient(baseURL, session: session)
        defer { finish(baseURL, store) }
        let meData = try FixtureLoader.data("me")
        let attempts = StubCounter()
        StubURLProtocol.register(baseURL) { _ in
            if attempts.next() == 1 {
                return StubResponse.error(503, code: "service_unavailable", message: "Сервис временно недоступен.")
            }
            return StubResponse.data(200, meData)
        }

        let started = Date()
        let me = try await client.send(.get("v1/me"), as: Me.self)
        #expect(me.profile?.username == "m_orlov")
        #expect(attempts.value == 2)
        #expect(Date().timeIntervalSince(started) < 2.4)
        #expect(StubURLProtocol.requests(baseURL, path: "/v1/me").count == 2)
    }

    // MARK: Session refresh

    @Test("Concurrent requests with an expired session share one refresh")
    func singleFlightRefresh() async throws {
        let baseURL = StubURLProtocol.makeBaseURL()
        let expired = makeSession(access: "access-token-expired-0123456789", refresh: "refresh-token-expired", expiresIn: -120)
        let fresh = makeSession(access: "access-token-fresh-0123456789", refresh: "refresh-token-fresh", expiresIn: 3600)
        let freshData = try sessionJSON(fresh)
        let (client, store) = makeClient(baseURL, session: expired)
        defer { finish(baseURL, store) }
        let refreshes = StubCounter()
        StubURLProtocol.register(baseURL) { request in
            if request.path == "/v1/auth/refresh" {
                refreshes.increment()
                return StubResponse.data(200, freshData)
            }
            if request.header("Authorization") == "Bearer access-token-fresh-0123456789" {
                return StubResponse.json(200, "{}")
            }
            return StubResponse.error(401, code: "session_expired", message: "Сессия истекла. Войдите снова.")
        }

        let first = Task { try await client.data(.get("v1/me")) }
        let second = Task { try await client.data(.get("v1/home")) }
        let third = Task { try await client.data(.get("v1/matches")) }
        _ = try await first.value
        _ = try await second.value
        _ = try await third.value

        #expect(refreshes.value == 1)
        #expect(store.session?.accessToken == "access-token-fresh-0123456789")
        let refresh = try #require(StubURLProtocol.requests(baseURL, path: "/v1/auth/refresh").first)
        #expect(refresh.method == "POST")
        #expect(refresh.header("Authorization") == nil)
        #expect(refresh.jsonBody()["refresh_token"] == "refresh-token-expired")
        let apiCalls = StubURLProtocol.requests(baseURL).filter { $0.path != "/v1/auth/refresh" }
        #expect(apiCalls.count == 3)
        #expect(apiCalls.allSatisfy { $0.header("Authorization") == "Bearer access-token-fresh-0123456789" })
    }

    @Test("A 401 session_expired answer refreshes and retries once")
    func refreshAfterRejection() async throws {
        let baseURL = StubURLProtocol.makeBaseURL()
        let revoked = makeSession(access: "access-token-revoked-0123456789", refresh: "refresh-token-revoked", expiresIn: 3600)
        let fresh = makeSession(access: "access-token-renewed-0123456789", refresh: "refresh-token-renewed", expiresIn: 3600)
        let freshData = try sessionJSON(fresh)
        let meData = try FixtureLoader.data("me")
        let (client, store) = makeClient(baseURL, session: revoked)
        defer { finish(baseURL, store) }
        let refreshes = StubCounter()
        StubURLProtocol.register(baseURL) { request in
            if request.path == "/v1/auth/refresh" {
                refreshes.increment()
                return StubResponse.data(200, freshData)
            }
            if request.header("Authorization") == "Bearer access-token-renewed-0123456789" {
                return StubResponse.data(200, meData)
            }
            return StubResponse.error(401, code: "session_expired", message: "Сессия истекла. Войдите снова.")
        }

        let me = try await client.send(.get("v1/me"), as: Me.self)
        #expect(me.email == "m.orlov@padelid.app")
        #expect(refreshes.value == 1)
        #expect(StubURLProtocol.requests(baseURL).map(\.path) == ["/v1/me", "/v1/auth/refresh", "/v1/me"])
        #expect(store.session == fresh)
    }

    @Test("A rejected refresh clears the session and reports it")
    func refreshFailure() async throws {
        let baseURL = StubURLProtocol.makeBaseURL()
        let expired = makeSession(access: "access-token-dead-0123456789", refresh: "refresh-token-dead", expiresIn: -120)
        let (client, store) = makeClient(baseURL, session: expired)
        defer { finish(baseURL, store) }
        let invalidations = StubCounter()
        client.onSessionInvalidated = { invalidations.increment() }
        StubURLProtocol.register(baseURL) { request in
            if request.path == "/v1/auth/refresh" {
                return StubResponse.error(401, code: "session_expired", message: "Сессия истекла. Войдите снова.")
            }
            return StubResponse.json(200, "{}")
        }

        do {
            _ = try await client.data(.get("v1/me"))
            Testing.Issue.record("Expected the request to fail")
        } catch let error as APIError {
            #expect(error.status == 401)
            #expect(error.code == "session_expired" || error.code == "not_authenticated")
        }
        #expect(store.session == nil)
        #expect(invalidations.value == 1)
        #expect(StubURLProtocol.requests(baseURL, path: "/v1/auth/refresh").count == 1)
        #expect(StubURLProtocol.requests(baseURL, path: "/v1/me").isEmpty)
    }
}
