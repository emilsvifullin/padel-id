import Foundation
import Observation

/// Cursor-paginated match list (`next_before`): the first page is a cache-first
/// `Resource`, further pages are appended on demand.
@Observable
final class MatchesListPager {
    let type: MatchType?
    let firstPage: Resource<MatchPage>

    private(set) var isLoadingMore = false
    private(set) var loadMoreError: APIError?

    private var extraItems: [MatchListItem] = []
    private var extraNextBefore: String?
    private var extraNextBeforeId: UUID?
    private var hasExtraPages = false
    private var generation = 0
    private var loadRequestID = UUID()
    private var moreRequestID = UUID()

    private let path: String
    private let query: [URLQueryItem]

    init(path: String, query: [URLQueryItem] = [], type: MatchType? = nil, cacheKey: String?) {
        var fullQuery = query
        if let type {
            fullQuery.append(URLQueryItem(name: "type", value: type.rawValue))
        }
        let endpointQuery = fullQuery
        self.path = path
        self.query = fullQuery
        self.type = type
        self.firstPage = Resource<MatchPage>(cacheKey: cacheKey) {
            Endpoint.get(path, query: endpointQuery)
        }
    }

    /// The current user's confirmed matches (`v1/matches?scope=history`).
    static func history(type: MatchType?) -> MatchesListPager {
        let cacheKey = type.map { "\(CacheKey.history).\($0.rawValue)" } ?? CacheKey.history
        return MatchesListPager(path: "v1/matches", query: [URLQueryItem(name: "scope", value: "history")],
                                type: type, cacheKey: cacheKey)
    }

    /// Confirmed matches of any player (`v1/players/{id}/matches`).
    static func player(_ id: UUID) -> MatchesListPager {
        MatchesListPager(path: "v1/players/\(id.uuidString.lowercased())/matches",
                         cacheKey: "\(CacheKey.player(id)).matches")
    }

    var hasValue: Bool { firstPage.value != nil }

    var items: [MatchListItem] {
        guard let base = firstPage.value?.items else { return [] }
        guard hasExtraPages, !extraItems.isEmpty else { return base }
        let known = Set(base.map(\.id))
        return base + extraItems.filter { !known.contains($0.id) }
    }

    var nextBefore: String? {
        guard hasValue else { return nil }
        return hasExtraPages ? extraNextBefore : firstPage.value?.nextBefore
    }

    /// Tie-breaker of the cursor: matches with the same `played_at` are ordered by id.
    private var nextBeforeId: UUID? {
        hasExtraPages ? extraNextBeforeId : firstPage.value?.nextBeforeId
    }

    var canLoadMore: Bool { !firstPage.isLoading && nextBefore != nil }

    /// Reloads the first page. Pages appended below it stay while the fresh
    /// first page still ends where they begin (a background refresh after a
    /// change elsewhere); they are dropped when it does not, or on `reset`
    /// (pull to refresh).
    func load(using app: AppModel, reset: Bool = false) async {
        let id = UUID()
        loadRequestID = id
        invalidateLoadMore()
        let previous = firstPage.value
        await firstPage.load(using: app)
        guard loadRequestID == id, !Task.isCancelled else { return }
        if firstPage.error?.code == "player_not_found" {
            clearExtraPages()
            return
        }
        guard firstPage.error == nil, !firstPage.isStale else { return }
        if !reset, hasExtraPages, let previous, let fresh = firstPage.value,
           fresh.nextBefore == previous.nextBefore, fresh.nextBeforeId == previous.nextBeforeId {
            return
        }
        clearExtraPages()
    }

    private func invalidateLoadMore() {
        generation += 1
        moreRequestID = UUID()
        isLoadingMore = false
    }

    private func clearExtraPages() {
        invalidateLoadMore()
        extraItems = []
        extraNextBefore = nil
        extraNextBeforeId = nil
        hasExtraPages = false
        loadMoreError = nil
    }

    func loadMore(using app: AppModel) async {
        guard let before = nextBefore, !firstPage.isLoading, !isLoadingMore else { return }
        let started = generation
        let id = UUID()
        moreRequestID = id
        isLoadingMore = true
        loadMoreError = nil
        defer { if moreRequestID == id { isLoadingMore = false } }
        do {
            var cursor = [URLQueryItem(name: "before", value: before)]
            if let id = nextBeforeId {
                cursor.append(URLQueryItem(name: "before_id", value: id.uuidString.lowercased()))
            }
            let endpoint = Endpoint.get(path, query: query + cursor)
            let page = try await app.api.send(endpoint, as: MatchPage.self)
            guard started == generation, moreRequestID == id, !Task.isCancelled else { return }
            let known = Set(items.map(\.id))
            extraItems.append(contentsOf: page.items.filter { !known.contains($0.id) })
            extraNextBefore = page.nextBefore
            extraNextBeforeId = page.nextBeforeId
            hasExtraPages = true
        } catch is CancellationError {
            return
        } catch let error as APIError {
            guard started == generation, moreRequestID == id, !Task.isCancelled else { return }
            if error.code == "player_not_found" {
                loadRequestID = UUID()
                firstPage.revokeAccess(error, using: app)
                clearExtraPages()
            } else {
                loadMoreError = error
            }
        } catch {
            guard started == generation, moreRequestID == id, !Task.isCancelled else { return }
            loadMoreError = APIError(kind: .decoding, code: "decoding", serverMessage: nil)
        }
    }
}
