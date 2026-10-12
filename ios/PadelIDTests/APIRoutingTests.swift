import Foundation
import Testing
@testable import PadelID

@MainActor
@Suite("Gateway route selection", .timeLimit(.minutes(1)))
struct APIRoutingTests {
    @Test("A cancelled caller shares route probing without sending its mutation or cancelling another caller")
    func cancellationDuringSharedProbe() async throws {
        let first = StubURLProtocol.makeBaseURL(), second = StubURLProtocol.makeBaseURL()
        defer { StubURLProtocol.unregister(first); StubURLProtocol.unregister(second) }
        let entered = StubCounter()
        StubURLProtocol.register(first) { request in
            if request.path.hasSuffix("/health") {
                entered.increment()
                Thread.sleep(forTimeInterval: 0.2)
                return .json(200, #"{"status":"ok"}"#)
            }
            return .json(200, "{}")
        }
        StubURLProtocol.register(second) { _ in .json(200, #"{"status":"ok"}"#) }
        let api = client(first, second)
        let cancelled = Task { try await api.data(.json(.post, "v1/auth/signup", ["request": "cancelled"], auth: false)) }
        while entered.value == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let active = Task { try await api.data(.json(.post, "v1/auth/signup", ["request": "active"], auth: false)) }
        cancelled.cancel()
        _ = try await active.value
        do { _ = try await cancelled.value; Issue.record("Expected cancelled caller") }
        catch is CancellationError {}
        let mutations = (StubURLProtocol.requests(first) + StubURLProtocol.requests(second)).filter { $0.method == "POST" }
        #expect(mutations.count == 1)
        #expect(mutations.first?.jsonBody()["request"] == "active")
        #expect(entered.value == 1)
    }

    @Test("HTTP307 never forwards signup credentials to a redirect destination")
    func redirects() async throws {
        let first = StubURLProtocol.makeBaseURL(), target = StubURLProtocol.makeBaseURL()
        defer { StubURLProtocol.unregister(first); StubURLProtocol.unregister(target) }
        StubURLProtocol.register(first) { _ in .redirect(target.appending(path: "receive")) }
        StubURLProtocol.register(target) { _ in .json(200, "{}") }
        let api = APIClient(baseURL: first, sessionStore: SessionStore(), urlSession: StubURLProtocol.makeURLSession())
        do {
            _ = try await api.data(.json(.post, "v1/auth/signup", ["password": "Private2026"], auth: false))
            Issue.record("Expected rejected redirect")
        } catch let error as APIError { #expect(error.status == 307) }
        #expect(StubURLProtocol.requests(first).count == 1)
        #expect(StubURLProtocol.requests(target).isEmpty)
    }

    @Test("Fast shallow health cannot rehabilitate a failed route ahead of a slower working fallback")
    func cooldown() async throws {
        let first = StubURLProtocol.makeBaseURL(), second = StubURLProtocol.makeBaseURL()
        defer { StubURLProtocol.unregister(first); StubURLProtocol.unregister(second) }
        StubURLProtocol.register(first) { _ in .json(200, #"{"status":"ok"}"#) }
        StubURLProtocol.register(second) { _ in
            Thread.sleep(forTimeInterval: 0.6)
            return .json(200, #"{"status":"ok"}"#)
        }
        let selector = APIRouteSelector(routes: [first, second], session: StubURLProtocol.makeURLSession())
        #expect(try await selector.select() == first)
        selector.failed(first)
        #expect(try await selector.select() == second)
        #expect(StubURLProtocol.requests(first).count == 1)
    }

    private func client(_ first: URL, _ second: URL) -> APIClient {
        APIClient(baseURL: first, sessionStore: SessionStore(), urlSession: StubURLProtocol.makeURLSession(), fallbackURLs: [second])
    }

    @Test("Unavailable Vercel route is detected before sending account credentials")
    func preflight() async throws {
        let first = StubURLProtocol.makeBaseURL()
        let second = StubURLProtocol.makeBaseURL().appending(path: "functions/v1/gateway")
        defer { StubURLProtocol.unregister(first); StubURLProtocol.unregister(second) }
        StubURLProtocol.register(first) { _ in .transportFailure(.cannotConnectToHost) }
        StubURLProtocol.register(second) { request in
            request.path.hasSuffix("/health") ? .json(200, #"{"status":"ok"}"#) : .json(200, "{}")
        }
        _ = try await client(first, second).data(.json(.post, "v1/auth/signup", ["email": "test@example.com", "password": "Password2026"], auth: false))
        #expect(StubURLProtocol.requests(first).allSatisfy { $0.path == "/v1/health" && $0.body == nil && $0.header("Authorization") == nil })
        let sent = StubURLProtocol.requests(second).filter { $0.method == "POST" }
        #expect(sent.count == 1)
        #expect(sent.first?.path == "/functions/v1/gateway/v1/auth/signup")
        #expect(sent.first?.jsonBody()["email"] == "test@example.com")
    }

    @Test("Lost mutation response is never replayed on another route; user retry preserves key")
    func mutation() async throws {
        let first = StubURLProtocol.makeBaseURL(), second = StubURLProtocol.makeBaseURL()
        defer { StubURLProtocol.unregister(first); StubURLProtocol.unregister(second) }
        StubURLProtocol.register(first) { request in
            request.path.hasSuffix("/health") ? .json(200, #"{"status":"ok"}"#) : .transportFailure(.networkConnectionLost)
        }
        StubURLProtocol.register(second) { request in
            request.path.hasSuffix("/health") ? .json(200, #"{"status":"ok"}"#) : .json(200, "{}")
        }
        let api = client(first, second)
        let key = UUID()
        let endpoint = Endpoint.json(.post, "v1/feed/posts", ["body": "draft"], auth: false, idempotencyKey: key)
        do { _ = try await api.data(endpoint); Issue.record("Expected lost response") }
        catch let error as APIError { #expect(error.isNetwork) }
        #expect(StubURLProtocol.requests(first).filter { $0.method == "POST" }.count == 1)
        #expect(StubURLProtocol.requests(second).filter { $0.method == "POST" }.isEmpty)
        _ = try await api.data(endpoint)
        let retry = try #require(StubURLProtocol.requests(second).first { $0.method == "POST" })
        #expect(retry.header("Idempotency-Key") == key.uuidString.lowercased())
        #expect(retry.jsonBody()["body"] == "draft")
    }

    @Test("A failed read moves to the independent route")
    func read() async throws {
        let first = StubURLProtocol.makeBaseURL(), second = StubURLProtocol.makeBaseURL()
        defer { StubURLProtocol.unregister(first); StubURLProtocol.unregister(second) }
        StubURLProtocol.register(first) { request in
            request.path.hasSuffix("/health") ? .json(200, #"{"status":"ok"}"#) : .transportFailure(.timedOut)
        }
        StubURLProtocol.register(second) { request in
            request.path.hasSuffix("/health") ? .json(200, #"{"status":"ok"}"#) : .json(200, #"{"via":"second"}"#)
        }
        var endpoint = Endpoint.get("v1/feed")
        endpoint.requiresAuth = false
        let data = try await client(first, second).data(endpoint)
        #expect(String(data: data, encoding: .utf8) == #"{"via":"second"}"#)
        #expect(StubURLProtocol.requests(first, path: "/v1/feed").count == 1)
        #expect(StubURLProtocol.requests(second, path: "/v1/feed").count == 1)
    }

    @Test("Neither HTML200 nor invalid health authorize sending a mutation")
    func invalidHealth() async throws {
        let first = StubURLProtocol.makeBaseURL(), second = StubURLProtocol.makeBaseURL()
        defer { StubURLProtocol.unregister(first); StubURLProtocol.unregister(second) }
        StubURLProtocol.register(first) { _ in .json(200, "<html>login</html>") }
        StubURLProtocol.register(second) { _ in .json(200, #"{"status":"degraded"}"#) }
        do {
            _ = try await client(first, second).data(.json(.post, "v1/auth/refresh", ["refresh_token": "private-token"], auth: false))
            Issue.record("Expected no valid route")
        } catch let error as APIError { #expect(error.isNetwork) }
        #expect((StubURLProtocol.requests(first) + StubURLProtocol.requests(second)).allSatisfy { $0.method == "GET" && $0.body == nil })
    }

    @Test("A domain authorization rejection is not routed around")
    func forbidden() async throws {
        let first = StubURLProtocol.makeBaseURL(), second = StubURLProtocol.makeBaseURL()
        defer { StubURLProtocol.unregister(first); StubURLProtocol.unregister(second) }
        StubURLProtocol.register(first) { request in
            request.path.hasSuffix("/health") ? .json(200, #"{"status":"ok"}"#) : .error(403, code: "forbidden", message: "Нет доступа")
        }
        StubURLProtocol.register(second) { _ in .json(200, #"{"status":"ok"}"#) }
        var endpoint = Endpoint.get("v1/feed"); endpoint.requiresAuth = false
        do { _ = try await client(first, second).data(endpoint); Issue.record("Expected denied read") }
        catch let error as APIError { #expect(error.status == 403) }
        #expect(StubURLProtocol.requests(second, path: "/v1/feed").isEmpty)
    }
}
