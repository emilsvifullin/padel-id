import Foundation
import Testing
@testable import PadelID

/// The offline outbox: persistence per user and delivery through APIClient
/// against the in-memory server. Every test activates a random user and purges
/// its file at the end.
@MainActor
@Suite("Offline outbox", .timeLimit(.minutes(1)))
struct OutboxTests {
    private func confirmation(of matchId: UUID, version: Int = 1) throws -> PendingOperation {
        PendingOperation(
            id: UUID(),
            kind: .confirmMatch,
            method: "POST",
            path: "v1/matches/\(matchId.uuidString.lowercased())/confirm",
            body: try JSONCoding.encoder.encode(["version": version]),
            idempotencyKey: nil,
            matchId: matchId,
            title: "Подтверждение матча",
            subtitle: "Михаил Орлов и Дмитрий Соколов",
            createdAt: Date()
        )
    }

    private func makeClient(_ baseURL: URL) -> (APIClient, SessionStore) {
        let store = SessionStore()
        store.save(Session(accessToken: "access-token-outbox-0123456789", refreshToken: "refresh-token-outbox",
                           expiresIn: 3600, expiresAt: Int(Date().timeIntervalSince1970) + 3600,
                           user: AuthUser(id: UUID(), email: "test@padelid.app")))
        let client = APIClient(baseURL: baseURL, sessionStore: store, urlSession: StubURLProtocol.makeURLSession())
        return (client, store)
    }

    @Test("Operations persist per user and reload in a new instance")
    func persistence() throws {
        let userId = UUID()
        let outbox = Outbox()
        outbox.activate(userId: userId)
        defer { outbox.purge() }
        #expect(outbox.operations.isEmpty)

        let matchId = UUID()
        let operation = try confirmation(of: matchId)
        outbox.enqueue(operation)
        #expect(outbox.pending.count == 1)
        #expect(outbox.contains(kind: .confirmMatch, matchId: matchId))
        #expect(!outbox.contains(kind: .disputeMatch, matchId: matchId))

        let reloaded = Outbox()
        reloaded.activate(userId: userId)
        #expect(reloaded.operations.count == 1)
        let stored = try #require(reloaded.operations.first)
        #expect(stored.id == operation.id)
        #expect(stored.kind == .confirmMatch)
        #expect(stored.method == "POST")
        #expect(stored.path == operation.path)
        #expect(stored.body == operation.body)
        #expect(stored.matchId == matchId)
        #expect(stored.title == operation.title)
        #expect(stored.attempts == 0)
        #expect(stored.failure == nil)
        #expect(abs(stored.createdAt.timeIntervalSince(operation.createdAt)) < 0.01)

        // Another user never sees these operations.
        let other = Outbox()
        other.activate(userId: UUID())
        #expect(other.operations.isEmpty)
        other.purge()

        reloaded.discard(operation.id)
        let afterDiscard = Outbox()
        afterDiscard.activate(userId: userId)
        #expect(afterDiscard.operations.isEmpty)
        afterDiscard.purge()

        // Signing out deactivates the outbox.
        reloaded.enqueue(try confirmation(of: matchId))
        reloaded.activate(userId: nil)
        #expect(reloaded.operations.isEmpty)
    }

    @Test("A delivered operation is removed and reported")
    func delivery() async throws {
        let baseURL = StubURLProtocol.makeBaseURL()
        let (client, store) = makeClient(baseURL)
        defer {
            store.clear()
            StubURLProtocol.unregister(baseURL)
        }
        let confirmed = try FixtureLoader.data("match_action_confirmed")
        StubURLProtocol.register(baseURL) { request in
            if request.method == "POST" && request.path.hasSuffix("/confirm") {
                return StubResponse.data(200, confirmed)
            }
            return StubResponse.error(404, code: "not_found", message: "Не найдено.")
        }

        let userId = UUID()
        let outbox = Outbox()
        outbox.activate(userId: userId)
        defer { outbox.purge() }
        var delivered: [(UUID, Data)] = []
        outbox.onDelivered = { operation, data in delivered.append((operation.id, data)) }

        let operation = try confirmation(of: UUID(), version: 3)
        outbox.enqueue(operation)
        await outbox.process(with: client)

        #expect(outbox.operations.isEmpty)
        #expect(!outbox.isProcessing)
        #expect(delivered.count == 1)
        #expect(delivered.first?.0 == operation.id)
        let detail = try JSONCoding.decoder.decode(MatchDetail.self, from: try #require(delivered.first?.1))
        #expect(detail.status == .confirmed)

        let request = try #require(StubURLProtocol.requests(baseURL).first)
        #expect(request.path == "/" + operation.path)
        #expect(request.header("Authorization") == "Bearer access-token-outbox-0123456789")
        #expect(request.jsonBody()["version"] == "3")

        let reloaded = Outbox()
        reloaded.activate(userId: userId)
        #expect(reloaded.operations.isEmpty)
    }

    @Test("A temporary server error keeps the operations for a later pass")
    func transientFailure() async throws {
        let baseURL = StubURLProtocol.makeBaseURL()
        let (client, store) = makeClient(baseURL)
        defer {
            store.clear()
            StubURLProtocol.unregister(baseURL)
        }
        StubURLProtocol.register(baseURL) { _ in
            StubResponse.error(503, code: "service_unavailable", message: "Сервис временно недоступен.")
        }

        let userId = UUID()
        let outbox = Outbox()
        outbox.activate(userId: userId)
        defer { outbox.purge() }
        var deliveries = 0
        outbox.onDelivered = { _, _ in deliveries += 1 }

        let first = try confirmation(of: UUID())
        let second = try confirmation(of: UUID())
        outbox.enqueue(first)
        outbox.enqueue(second)
        await outbox.process(with: client)

        #expect(deliveries == 0)
        #expect(outbox.operations.map(\.id) == [first.id, second.id])
        #expect(outbox.operations.allSatisfy { $0.attempts == 1 })
        #expect(outbox.failed.isEmpty)
        #expect(outbox.pending.count == 2)
        // One failing operation does not hold back the others.
        #expect(StubURLProtocol.requests(baseURL).count == 2)

        let reloaded = Outbox()
        reloaded.activate(userId: userId)
        #expect(reloaded.operations.first?.attempts == 1)

        // After repeated server errors the operation is given up with a reason.
        for _ in 1..<Outbox.maxAttempts {
            await outbox.process(with: client)
        }
        #expect(outbox.failed.count == 2)
        #expect(outbox.pending.isEmpty)
    }

    @Test("A permanent failure marks the operation and moves on")
    func permanentFailure() async throws {
        let baseURL = StubURLProtocol.makeBaseURL()
        let (client, store) = makeClient(baseURL)
        defer {
            store.clear()
            StubURLProtocol.unregister(baseURL)
        }
        let conflicting = UUID()
        let confirmed = try FixtureLoader.data("match_action_confirmed")
        StubURLProtocol.register(baseURL) { request in
            if request.path.contains(conflicting.uuidString.lowercased()) {
                return StubResponse.error(409, code: "version_conflict", message: "Матч изменён.")
            }
            return StubResponse.data(200, confirmed)
        }

        let outbox = Outbox()
        outbox.activate(userId: UUID())
        defer { outbox.purge() }
        var delivered: [UUID] = []
        outbox.onDelivered = { operation, _ in delivered.append(operation.id) }

        let failing = try confirmation(of: conflicting)
        let fine = try confirmation(of: UUID())
        outbox.enqueue(failing)
        outbox.enqueue(fine)
        await outbox.process(with: client)

        #expect(delivered == [fine.id])
        #expect(outbox.operations.count == 1)
        let failed = try #require(outbox.failed.first)
        #expect(failed.id == failing.id)
        #expect(failed.attempts == 1)
        #expect(failed.failure == APIError(kind: .server(status: 409), code: "version_conflict", serverMessage: nil).message)
        #expect(outbox.pending.isEmpty)
        #expect(!outbox.contains(kind: .confirmMatch, matchId: conflicting))

        // Failed operations are not retried by the next run.
        await outbox.process(with: client)
        #expect(StubURLProtocol.requests(baseURL).count == 2)
    }
}
