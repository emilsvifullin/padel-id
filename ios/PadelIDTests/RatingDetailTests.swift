import Foundation
import Testing
import UIKit
@testable import PadelID

@MainActor
@Suite("Rating history switching", .timeLimit(.minutes(1)))
struct RatingDetailTests {
    private func point(at: Date, level: Double = 3, kind: String = "match", won: Bool = true,
                       delta: Double = 0.1) -> RatingPoint {
        RatingPoint(at: at, mu: level, sigma: 0.4, delta: delta, kind: kind,
                    matchId: kind == "match" ? UUID() : nil, won: kind == "match" ? won : nil,
                    expectedWin: 0.5)
    }

    private func response(level: Double) throws -> Data {
        try JSONCoding.encoder.encode(RatingHistory(points: [point(at: .now, level: level)], peakMu: level))
    }

    @Test("Returning to a loaded period reuses data; revision and explicit refresh fetch again")
    func cacheUntilMutationOrRefresh() async throws {
        let history = RatingDetailHistory(playerId: UUID(), range: .month)
        let data = try response(level: 3)
        var fetches = 0
        var stores = 0
        let fetch: () async throws -> Data = { fetches += 1; return data }
        let store: (Data) -> Void = { _ in stores += 1 }
        await history.load(revision: 1, cached: { nil }, fetch: fetch, store: store)
        await history.load(revision: 1, cached: { nil }, fetch: fetch, store: store)
        #expect(fetches == 1)
        #expect(stores == 1)
        #expect(history.value?.history.points.first?.mu == 3)
        await history.load(revision: 2, cached: { nil }, fetch: fetch, store: store)
        await history.load(revision: 2, force: true, cached: { nil }, fetch: fetch, store: store)
        #expect(fetches == 3)
        #expect(stores == 3)
    }

    @Test("An older response cannot overwrite a newer refresh or its persisted cache")
    func newestReplyWins() async throws {
        let history = RatingDetailHistory(playerId: UUID(), range: .all)
        let gate = RatingReplyGate()
        let oldData = try response(level: 2)
        let newData = try response(level: 4)
        var stored: [Data] = []
        let old = Task {
            await history.load(revision: 1, cached: { nil }, fetch: { await gate.wait() }, store: { stored.append($0) })
        }
        while !gate.isWaiting { await Task.yield() }
        await history.load(revision: 2, force: true, cached: { nil }, fetch: { newData }, store: { stored.append($0) })
        gate.resume(oldData)
        await old.value
        #expect(history.value?.history.points.first?.mu == 4)
        #expect(stored == [newData])
        #expect(!history.isLoading)
    }

    @Test("A cancelled transport that still replies cannot publish or cache its response")
    func cancelledReplyIgnored() async throws {
        let history = RatingDetailHistory(playerId: UUID(), range: .quarter)
        let gate = RatingReplyGate()
        let data = try response(level: 4)
        var stored = false
        let task = Task {
            await history.load(revision: 1, cached: { nil }, fetch: { await gate.wait() }, store: { _ in stored = true })
        }
        while !gate.isWaiting { await Task.yield() }
        task.cancel()
        gate.resume(data)
        await task.value
        #expect(history.value == nil)
        #expect(history.error == nil)
        #expect(!history.isLoading)
        #expect(!stored)
    }

    @Test("Cached data survives a network failure; the failed revision can be retried")
    func offlineCacheAndRetry() async throws {
        let history = RatingDetailHistory(playerId: UUID(), range: .year)
        let cached = try response(level: 2)
        await history.load(revision: 1, cached: { cached }, fetch: { throw APIError.offline }, store: { _ in })
        #expect(history.value?.history.points.first?.mu == 2)
        #expect(history.isStale)
        #expect(history.error?.isNetwork == true)
        let fresh = try response(level: 3)
        await history.load(revision: 1, cached: { nil }, fetch: { fresh }, store: { _ in })
        #expect(history.value?.history.points.first?.mu == 3)
        #expect(!history.isStale)
        #expect(history.error == nil)
    }

    @Test("One denied rating period invalidates all periods and blocks an older successful reply")
    func denialRevokesAllPeriodsAndPendingReply() async throws {
        let playerId = UUID()
        let userId = UUID()
        let histories = RatingDetailHistories(playerId: playerId)
        let baseURL = StubURLProtocol.makeBaseURL()
        let store = SessionStore()
        store.save(Session(accessToken: "access-token-rating-test-0123456789", refreshToken: "refresh-token-rating-test",
                           expiresIn: 3_600, expiresAt: Int(Date().timeIntervalSince1970) + 3_600,
                           user: AuthUser(id: userId, email: "test@padelid.app")))
        let app = AppModel(api: APIClient(baseURL: baseURL, sessionStore: store, urlSession: StubURLProtocol.makeURLSession()))
        app.cache.activate(userId: userId)
        defer {
            app.cache.removePlayerData(playerId)
            app.cache.activate(userId: nil)
            store.clear()
            StubURLProtocol.unregister(baseURL)
        }
        let previous = try response(level: 3)
        for range in RatingDetailRange.allCases {
            await histories[range].load(revision: 1, cached: { nil }, fetch: { previous }, store: {
                app.cache.store($0, for: CacheKey.ratingHistory(playerId, days: range.days))
            })
        }
        app.cache.store(previous, for: CacheKey.player(playerId))
        app.cache.store(previous, for: CacheKey.dna(playerId))
        let gate = RatingReplyGate()
        let older = Task {
            await histories[.all].load(revision: 1, force: true, cached: { nil }, fetch: { await gate.wait() }, store: {
                app.cache.store($0, for: CacheKey.ratingHistory(playerId, days: nil))
            })
        }
        while !gate.isWaiting { await Task.yield() }
        StubURLProtocol.register(baseURL) { _ in
            .error(404, code: "player_not_found", message: "Профиль недоступен.")
        }
        await histories.load(.quarter, using: app, revision: 1, force: true)
        gate.resume(previous)
        await older.value

        for range in RatingDetailRange.allCases {
            #expect(histories[range].value == nil)
            #expect(histories[range].error?.code == "player_not_found")
            #expect(!histories[range].isLoading)
            #expect(!histories[range].isStale)
            #expect(app.cache.data(for: CacheKey.ratingHistory(playerId, days: range.days)) == nil)
        }
        #expect(app.cache.data(for: CacheKey.player(playerId)) == nil)
        #expect(app.cache.data(for: CacheKey.dna(playerId)) == nil)

        // An accepted friendship can restore access later. The same domain
        // revision must fetch again instead of reusing its old loaded marker.
        let restored = try response(level: 4)
        StubURLProtocol.register(baseURL) { _ in .data(200, restored) }
        await histories.load(.quarter, using: app, revision: 1)
        #expect(StubURLProtocol.requests(baseURL).count == 1)
        #expect(histories[.quarter].value?.history.points.first?.mu == 4)
        #expect(histories[.quarter].error == nil)
    }

    @Test("Revocation from the player resource invalidates periods even when no rating request failed")
    func playerDenialInvalidatesLoadedPeriods() async throws {
        let playerId = UUID()
        let histories = RatingDetailHistories(playerId: playerId)
        let previous = try response(level: 3)
        for range in RatingDetailRange.allCases {
            await histories[range].load(revision: 1, cached: { nil }, fetch: { previous }, store: { _ in })
        }
        let denied = APIError(kind: .server(status: 404), code: "player_not_found", serverMessage: nil)
        histories.revokeAccess(denied, cache: ResponseCache())
        #expect(RatingDetailRange.allCases.allSatisfy { histories[$0].value == nil })
        #expect(RatingDetailRange.allCases.allSatisfy { histories[$0].error?.code == "player_not_found" })
    }

    @Test("Period totals exclude the predecessor, include the boundary, and use only match changes")
    func periodBoundary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let boundary = now.addingTimeInterval(-30 * 86_400)
        let before = point(at: boundary.addingTimeInterval(-1), delta: 0.9)
        let atBoundary = point(at: boundary, delta: 0.2)
        let calibration = point(at: boundary.addingTimeInterval(1), kind: "calibration", delta: 1)
        let loss = point(at: now, won: false, delta: -0.1)
        let input = RatingHistory(points: [before, atBoundary, calibration, loss], peakMu: 3)
        let month = RatingDetailSnapshot(history: input, range: .month, now: now)
        #expect(month.matchPoints.count == 2)
        #expect(month.wins == 1)
        #expect(abs(month.periodChange - 0.1) < 0.00001)
        #expect(month.changes == [loss, calibration, atBoundary])
        #expect(month.chart.samples.count == 4)
        #expect(month.chart.samples.first?.at == before.at)
        let all = RatingDetailSnapshot(history: input, range: .all, now: now)
        #expect(all.matchPoints.count == 3)
    }

    @Test("Vectorized chart retains every point and bounded uncertainty at both scale limits")
    func completeChart() {
        let now = Date.now
        let points = (0..<5_000).map { index in
            point(at: now.addingTimeInterval(Double(index)), level: Double(index % 8), won: index.isMultiple(of: 2))
        }
        let data = RatingChartData(points: points)
        #expect(data.samples.count == points.count)
        #expect(data.matchCount == points.count)
        #expect(data.wins.count == 2_500)
        #expect(data.losses.count == 2_500)
        #expect(data.samples.allSatisfy { $0.lower >= 0 && $0.upper <= 7 })
        #expect(data.yDomain == 0...7)
    }

    @Test("The native racket symbol exists in the target SDK")
    func racketSymbol() {
        #expect(UIImage(systemName: "tennis.racket") != nil)
    }
}

@MainActor
private final class RatingReplyGate {
    private var continuation: CheckedContinuation<Data, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait() async -> Data {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume(_ data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}
