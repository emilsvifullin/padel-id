import Foundation
import Testing
@testable import PadelID

@MainActor
@Suite("Remote resource mutation races", .timeLimit(.minutes(1)))
struct ResourceTests {
    private func environment(path: String = "revision") -> (AppModel, Resource<ResourceRevision>, ResourceReplyGate, URL, String) {
        let baseURL = StubURLProtocol.makeBaseURL()
        let gate = ResourceReplyGate()
        ResourceURLProtocol.register(baseURL, gate: gate)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResourceURLProtocol.self]
        configuration.urlCache = nil
        let client = APIClient(baseURL: baseURL, sessionStore: SessionStore(), urlSession: URLSession(configuration: configuration))
        let app = AppModel(api: client)
        app.cache.activate(userId: UUID())
        let key = "resource-regression-" + UUID().uuidString
        let resource = Resource<ResourceRevision>(cacheKey: key) {
            Endpoint(method: .get, path: path, requiresAuth: false)
        }
        return (app, resource, gate, baseURL, key)
    }

    private func finish(_ app: AppModel, _ baseURL: URL, _ key: String) {
        app.cache.remove(key)
        app.cache.activate(userId: nil)
        ResourceURLProtocol.unregister(baseURL)
    }

    @Test("A delayed GET cannot roll back a successful mutation or its persisted response")
    func replacementWinsOverOlderGET() async throws {
        let (app, resource, gate, baseURL, key) = environment()
        defer { finish(app, baseURL, key) }
        app.cache.store(ResourceRevision(revision: 0), for: key)
        let task = Task { await resource.load(using: app) }
        while !gate.isWaiting { await Task.yield() }
        #expect(resource.value?.revision == 0)
        #expect(resource.isStale)
        #expect(resource.isLoading)

        let mutation = ResourceRevision(revision: 2)
        let mutationData = try JSONCoding.encoder.encode(mutation)
        resource.replace(with: mutation, data: mutationData, app: app)
        gate.reply(.data(200, try JSONCoding.encoder.encode(ResourceRevision(revision: 1))))
        await task.value

        #expect(resource.value == mutation)
        #expect(resource.error == nil)
        #expect(!resource.isLoading)
        #expect(!resource.isStale)
        #expect(app.cache.data(for: key) == mutationData)
        #expect(app.cache.value(ResourceRevision.self, for: key) == mutation)
    }

    @Test("An older GET failure cannot mark a successful mutation as failed or stale")
    func replacementWinsOverOlderFailure() async throws {
        let (app, resource, gate, baseURL, key) = environment()
        defer { finish(app, baseURL, key) }
        let task = Task { await resource.load(using: app) }
        while !gate.isWaiting { await Task.yield() }
        let mutation = ResourceRevision(revision: 2)
        let mutationData = try JSONCoding.encoder.encode(mutation)
        resource.replace(with: mutation, data: mutationData, app: app)
        gate.reply(.error(503, code: "service_unavailable", message: "Сервис временно недоступен."))
        await task.value

        #expect(resource.value == mutation)
        #expect(resource.error == nil)
        #expect(!resource.isLoading)
        #expect(!resource.isStale)
        #expect(app.cache.data(for: key) == mutationData)
    }

    @Test("Cancelling a GET ignores its late response and retains cached data without a new error")
    func cancelledReplyDoesNotPublish() async throws {
        let (app, resource, gate, baseURL, key) = environment()
        defer { finish(app, baseURL, key) }
        let cached = ResourceRevision(revision: 0)
        let cachedData = try JSONCoding.encoder.encode(cached)
        app.cache.store(cachedData, for: key)
        let task = Task { await resource.load(using: app) }
        while !gate.isWaiting { await Task.yield() }
        gate.reply(.data(200, try JSONCoding.encoder.encode(ResourceRevision(revision: 1))))
        // Complete the transport and cancel before yielding MainActor back to
        // the suspended loader. A queued successful reply must not publish.
        task.cancel()
        await task.value

        #expect(resource.value == cached)
        #expect(resource.error == nil)
        #expect(!resource.isLoading)
        #expect(resource.isStale)
        #expect(app.cache.data(for: key) == cachedData)
        #expect(!resource.hasLoaded)
    }

    @Test("A hidden-player access denial removes visible data and every persisted analytics cache for that player")
    func deniedPlayerPurgesAnalytics() async throws {
        let playerId = UUID()
        let (app, resource, gate, baseURL, key) = environment(path: "v1/players/" + playerId.uuidString.lowercased() + "/dna")
        let cacheUserId = UUID()
        app.cache.activate(userId: cacheUserId)
        let unrelatedKey = CacheKey.player(UUID())
        defer {
            app.cache.remove(unrelatedKey)
            finish(app, baseURL, key)
        }
        let cachedData = try JSONCoding.encoder.encode(ResourceRevision(revision: 1))
        let periods: [Int?] = [30, 90, 365, nil]
        let analyticsKeys = [CacheKey.player(playerId), "\(CacheKey.player(playerId)).matches", CacheKey.dna(playerId)] +
            periods.map { CacheKey.ratingHistory(playerId, days: $0) }
        for cacheKey in analyticsKeys + [key, unrelatedKey] { app.cache.store(cachedData, for: cacheKey) }
        let task = Task { await resource.load(using: app) }
        while !gate.isWaiting { await Task.yield() }
        #expect(resource.value?.revision == 1)
        gate.reply(.error(404, code: "player_not_found", message: "Профиль недоступен."))
        await task.value

        #expect(resource.value == nil)
        #expect(resource.error?.code == "player_not_found")
        #expect(!resource.isLoading)
        #expect(!resource.isStale)
        #expect(app.cache.data(for: key) == nil)
        #expect(analyticsKeys.allSatisfy { app.cache.data(for: $0) == nil })
        #expect(app.cache.data(for: unrelatedKey) == cachedData)
        // A new cache instance reads the disk, so memory-only invalidation
        // cannot satisfy this privacy regression.
        let restored = ResponseCache()
        restored.activate(userId: cacheUserId)
        #expect(analyticsKeys.allSatisfy { restored.data(for: $0) == nil })
        #expect(restored.data(for: key) == nil)
    }

    @Test("A temporary failure still retains the visible and persisted player data")
    func temporaryFailureKeepsAuthorizedCache() async throws {
        let playerId = UUID()
        let (app, resource, gate, baseURL, key) = environment(path: "v1/players/" + playerId.uuidString.lowercased())
        defer { finish(app, baseURL, key) }
        let cached = ResourceRevision(revision: 1)
        let cachedData = try JSONCoding.encoder.encode(cached)
        app.cache.store(cachedData, for: key)
        let task = Task { await resource.load(using: app) }
        while !gate.isWaiting { await Task.yield() }
        gate.reply(.error(503, code: "service_unavailable", message: "Сервис временно недоступен."))
        await task.value

        #expect(resource.value == cached)
        #expect(resource.error?.code == "service_unavailable")
        #expect(resource.isStale)
        #expect(!resource.isLoading)
        #expect(app.cache.data(for: key) == cachedData)
    }
}

@MainActor
@Suite("Player match history access", .timeLimit(.minutes(1)))
struct PlayerMatchHistoryAccessTests {
    @Test("A denial on a later page removes the first page, extra matches and their cache")
    func paginationDenialClearsEntireHistory() async throws {
        let source = try FixtureLoader.decode(MatchPage.self, "player_matches")
        let first = try #require(source.items.first)
        let second = try #require(source.items.dropFirst().first)
        let firstPage = MatchPage(items: [first], nextBefore: JSONCoding.formatDate(first.playedAt), nextBeforeId: first.id)
        let secondPage = MatchPage(items: [second], nextBefore: JSONCoding.formatDate(second.playedAt), nextBeforeId: second.id)
        let firstData = try JSONCoding.encoder.encode(firstPage)
        let secondData = try JSONCoding.encoder.encode(secondPage)
        let baseURL = StubURLProtocol.makeBaseURL()
        let playerId = UUID()
        let userId = UUID()
        let store = SessionStore()
        store.save(Session(accessToken: "access-token-history-test-0123456789", refreshToken: "refresh-token-history-test",
                           expiresIn: 3_600, expiresAt: Int(Date().timeIntervalSince1970) + 3_600,
                           user: AuthUser(id: userId, email: "test@padelid.app")))
        let app = AppModel(api: APIClient(baseURL: baseURL, sessionStore: store, urlSession: StubURLProtocol.makeURLSession()))
        app.cache.activate(userId: userId)
        let pager = MatchesListPager.player(playerId)
        let cacheKey = "\(CacheKey.player(playerId)).matches"
        defer {
            app.cache.removePlayerData(playerId)
            app.cache.activate(userId: nil)
            store.clear()
            StubURLProtocol.unregister(baseURL)
        }
        let calls = StubCounter()
        StubURLProtocol.register(baseURL) { _ in
            switch calls.next() {
            case 1: .data(200, firstData)
            case 2: .data(200, secondData)
            default: .error(404, code: "player_not_found", message: "Профиль недоступен.")
            }
        }
        await pager.load(using: app)
        await pager.loadMore(using: app)
        #expect(pager.items.map(\.id) == [first.id, second.id])
        #expect(pager.canLoadMore)
        #expect(app.cache.data(for: cacheKey) == firstData)

        // The friendship can be removed while the viewer is browsing an
        // already-open history, before the next pagination request.
        await pager.loadMore(using: app)
        #expect(!pager.hasValue)
        #expect(pager.items.isEmpty)
        #expect(pager.nextBefore == nil)
        #expect(!pager.canLoadMore)
        #expect(!pager.isLoadingMore)
        #expect(pager.firstPage.error?.code == "player_not_found")
        #expect(app.cache.data(for: cacheKey) == nil)
        await pager.loadMore(using: app)
        #expect(calls.value == 3)
    }
}

private nonisolated struct ResourceRevision: Codable, Equatable, Sendable {
    let revision: Int
}

/// Holds an HTTP response until the test performs a mutation or cancellation.
/// Hosts isolate concurrently running tests, and no timing delays are needed.
private nonisolated final class ResourceReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var respond: (@Sendable (StubResponse) -> Void)?

    var isWaiting: Bool { lock.withLock { respond != nil } }

    func attach(_ callback: @escaping @Sendable (StubResponse) -> Void) {
        lock.withLock { respond = callback }
    }

    func reply(_ response: StubResponse) {
        let callback = lock.withLock {
            let callback = respond
            respond = nil
            return callback
        }
        callback?(response)
    }
}

private nonisolated final class ResourceURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gates: [String: ResourceReplyGate] = [:]

    static func register(_ baseURL: URL, gate: ResourceReplyGate) {
        lock.withLock { gates[baseURL.host() ?? ""] = gate }
    }

    static func unregister(_ baseURL: URL) {
        _ = lock.withLock { gates.removeValue(forKey: baseURL.host() ?? "") }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let gate = Self.lock.withLock { Self.gates[request.url?.host() ?? ""] }
        guard let gate else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        gate.attach { [self] response in
            guard let url = request.url,
                  let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
