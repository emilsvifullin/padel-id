import Foundation
import Testing
@testable import PadelID

@MainActor
@Suite("Canonical feed and comment windows", .timeLimit(.minutes(1)))
struct CommunityCollectionRefreshTests {
    @Test("Deleted and newly authorized rows reconcile every visited page without resetting pagination")
    func canonicalRemovalAndInsertion() async {
        let context = CollectionTestContext()
        defer { context.close() }
        let phase = StubCounter()
        StubURLProtocol.register(context.url) { request in
            let offset = Self.offset(request)
            let rows = phase.value == 0 ? Array(1...90) : [999] + Array(1...90).filter { $0 != 12 }
            return Self.page(Array(rows.dropFirst(offset).prefix(30)), next: offset + 30 < rows.count ? offset + 30 : nil,
                             body: phase.value == 0 ? "original" : "canonical")
        }
        let collection = CommunityCollection<CollectionRow>("v1/social/feed", windowLimit: 150)
        await collection.load(using: context.app)
        await collection.load(using: context.app, more: true)
        #expect(collection.items.count == 60)
        phase.increment()
        await collection.refreshVisibleWindow(using: context.app)
        #expect(collection.items.map(\.id) == [999] + Array(1...60).filter { $0 != 12 })
        #expect(collection.items.allSatisfy { $0.body == "canonical" })
        #expect(collection.nextOffset == 60)
        #expect(StubURLProtocol.requests(context.url).suffix(2).map(Self.offset) == [0, 30])
    }

    @Test("A denial on a later page clears the entire old window and its paging cursor")
    func secondPageDenialIsAtomic() async {
        let context = CollectionTestContext()
        defer { context.close() }
        let phase = StubCounter()
        StubURLProtocol.register(context.url) { request in
            let offset = Self.offset(request)
            if phase.value > 0 && offset == 30 { return .error(403, code: "forbidden", message: "Access revoked") }
            return Self.page(Array((offset + 1)...(offset + 30)), next: offset + 30)
        }
        let collection = CommunityCollection<CollectionRow>("v1/social/posts/any/comments", windowLimit: 150)
        await collection.load(using: context.app)
        await collection.load(using: context.app, more: true)
        phase.increment()
        await collection.refreshVisibleWindow(using: context.app)
        #expect(collection.items.isEmpty)
        #expect(collection.nextOffset == nil)
        #expect(collection.error?.status == 403)
        #expect(!collection.isLoading)
        #expect(!collection.hasLoaded)
    }

    @Test("A bounded window can visit more than 150 rows and refreshes its current range; pull refresh returns to the newest prefix")
    func slidingHistoryAndExplicitRefresh() async {
        let context = CollectionTestContext()
        defer { context.close() }
        StubURLProtocol.register(context.url) { request in
            let offset = Self.offset(request)
            return Self.page(Array((offset + 1)...(offset + 30)), next: offset + 30)
        }
        let bounded = CommunityCollection<CollectionRow>("v1/social/feed", windowLimit: 150)
        await bounded.load(using: context.app)
        for _ in 0..<5 { await bounded.load(using: context.app, more: true) }
        #expect(bounded.items.map(\.id) == Array(31...180))
        #expect(bounded.nextOffset == 180)
        await bounded.refreshVisibleWindow(using: context.app)
        #expect(StubURLProtocol.requests(context.url).suffix(5).map(Self.offset) == [30, 60, 90, 120, 150])
        #expect(bounded.items.map(\.id) == Array(31...180))
        await bounded.load(using: context.app, more: true)
        #expect(bounded.items.map(\.id) == Array(61...210))
        #expect(bounded.nextOffset == 210)
        await bounded.load(using: context.app)
        #expect(bounded.items.map(\.id) == Array(1...30))
        await bounded.load(using: context.app, more: true)
        #expect(bounded.items.map(\.id) == Array(1...60))
        #expect(Self.offset(StubURLProtocol.requests(context.url).last!) == 30)
    }

    @Test("Other social lists keep unbounded pagination and duplicate rows never produce duplicate IDs")
    func legacyListsAndDeduplication() async {
        let context = CollectionTestContext()
        defer { context.close() }
        StubURLProtocol.register(context.url) { request in
            let offset = Self.offset(request)
            return Self.page(Array((offset + 1)...(offset + 30)) + [offset + 1], next: offset + 30)
        }
        let collection = CommunityCollection<CollectionRow>("v1/social/groups")
        await collection.load(using: context.app)
        for _ in 0..<5 { await collection.load(using: context.app, more: true) }
        #expect(collection.items.map(\.id) == Array(1...180))
        #expect(collection.nextOffset == 180)
    }

    @Test("A temporary offline response retains the window and uses only the client's bounded GET retries")
    func offlineRetainsWindow() async {
        let context = CollectionTestContext()
        defer { context.close() }
        let calls = StubCounter()
        StubURLProtocol.register(context.url) { _ in
            if calls.next() == 1 { return Self.page([1, 2], next: nil) }
            return .transportFailure(.notConnectedToInternet)
        }
        let collection = CommunityCollection<CollectionRow>("v1/social/feed", windowLimit: 150)
        await collection.load(using: context.app)
        await collection.refreshVisibleWindow(using: context.app)
        #expect(collection.items.map(\.id) == [1, 2])
        #expect(collection.error?.isNetwork == true)
        #expect(!collection.isLoading)
        // One initial success and three attempts in APIClient's existing GET
        // retry policy; the collection must not add another retry loop.
        #expect(calls.value == 4)
    }

    @Test("A delayed authorized page cannot restore content after a newer 404")
    func lateResponseCannotUndoDenial() async {
        let context = CollectionTestContext(gated: true)
        defer { context.close() }
        let collection = CommunityCollection<CollectionRow>("v1/social/feed", windowLimit: 150)
        let initial = Task { await collection.load(using: context.app) }
        await context.waitForResponses(1)
        context.gate.reply(Self.page([1], next: 30))
        await initial.value
        let old = Task { await collection.refreshVisibleWindow(using: context.app) }
        await context.waitForResponses(1)
        let fresh = Task { await collection.load(using: context.app) }
        await context.waitForResponses(2)
        context.gate.reply(.error(404, code: "post_not_found", message: "Removed"), at: 1)
        await fresh.value
        #expect(collection.items.isEmpty)
        context.gate.reply(Self.page([1, 2], next: 30))
        await old.value
        #expect(collection.items.isEmpty)
        #expect(collection.error?.status == 404)
        #expect(collection.nextOffset == nil)
        #expect(!collection.isLoading)
    }

    @Test("Cancelling a foreground refresh after transport delivery does not publish its page")
    func cancellationRetainsVisibleWindow() async {
        let context = CollectionTestContext(gated: true)
        defer { context.close() }
        let collection = CommunityCollection<CollectionRow>("v1/social/feed", windowLimit: 150)
        let initial = Task { await collection.load(using: context.app) }
        await context.waitForResponses(1)
        context.gate.reply(Self.page([1], next: nil))
        await initial.value
        let refresh = Task { await collection.refreshVisibleWindow(using: context.app) }
        await context.waitForResponses(1)
        context.gate.reply(Self.page([2], next: nil))
        refresh.cancel()
        await refresh.value
        #expect(collection.items.map(\.id) == [1])
        #expect(collection.error == nil)
        #expect(!collection.isLoading)
    }

    private nonisolated static func offset(_ request: StubRecordedRequest) -> Int {
        Int(URLComponents(url: request.request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "offset" }!.value!)!
    }
    private nonisolated static func page(_ ids: [Int], next: Int?, body: String = "private") -> StubResponse {
        let rows = ids.map { ["id": $0, "body": body] as [String: Any] }
        return .data(200, try! JSONSerialization.data(withJSONObject: ["items": rows, "next_offset": next.map { $0 as Any } ?? NSNull()]))
    }
}

private nonisolated struct CollectionRow: Codable, Sendable, Identifiable {
    let id: Int
    let body: String
}

@MainActor
private struct CollectionTestContext {
    let url = StubURLProtocol.makeBaseURL()
    let store = SessionStore()
    let gate = CollectionReplyGate()
    let app: AppModel
    init(gated: Bool = false) {
        store.save(Session(accessToken: "collection-test-access-0123456789", refreshToken: "collection-test-refresh-0123456789",
                           expiresIn: 3600, expiresAt: Int(Date.now.timeIntervalSince1970) + 3600, user: AuthUser(id: UUID(), email: "test@example.test")))
        let session: URLSession
        if gated {
            CollectionURLProtocol.register(url, gate: gate)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CollectionURLProtocol.self]
            configuration.urlCache = nil
            session = URLSession(configuration: configuration)
        } else { session = StubURLProtocol.makeURLSession() }
        app = AppModel(api: APIClient(baseURL: url, sessionStore: store, urlSession: session))
    }
    func waitForResponses(_ count: Int) async { while gate.count < count { await Task.yield() } }
    func close() { store.clear(); StubURLProtocol.unregister(url); CollectionURLProtocol.unregister(url) }
}

private nonisolated final class CollectionReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@Sendable (StubResponse) -> Void] = []
    var count: Int { lock.withLock { callbacks.count } }
    func attach(_ callback: @escaping @Sendable (StubResponse) -> Void) { lock.withLock { callbacks.append(callback) } }
    func reply(_ response: StubResponse, at index: Int = 0) {
        let callback = lock.withLock { callbacks.remove(at: index) }
        callback(response)
    }
}

private nonisolated final class CollectionURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gates: [String: CollectionReplyGate] = [:]
    static func register(_ baseURL: URL, gate: CollectionReplyGate) { lock.withLock { gates[baseURL.host()!] = gate } }
    static func unregister(_ baseURL: URL) { _ = lock.withLock { gates.removeValue(forKey: baseURL.host()!) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let gate = Self.lock.withLock { Self.gates[request.url!.host()!] }
        gate?.attach { [self] response in
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
