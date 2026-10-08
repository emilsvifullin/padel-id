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
    private var hasExtraPages = false
    private var generation = 0

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
        let base = firstPage.value?.items ?? []
        guard hasExtraPages, !extraItems.isEmpty else { return base }
        let known = Set(base.map(\.id))
        return base + extraItems.filter { !known.contains($0.id) }
    }

    var nextBefore: String? {
        hasExtraPages ? extraNextBefore : firstPage.value?.nextBefore
    }

    var canLoadMore: Bool { nextBefore != nil }

    /// Reloads the first page; appended pages are dropped once fresh data arrives.
    func load(using app: AppModel) async {
        await firstPage.load(using: app)
        guard firstPage.error == nil, !firstPage.isStale else { return }
        generation += 1
        extraItems = []
        extraNextBefore = nil
        hasExtraPages = false
        loadMoreError = nil
    }

    func loadMore(using app: AppModel) async {
        guard let before = nextBefore, !isLoadingMore else { return }
        let started = generation
        isLoadingMore = true
        loadMoreError = nil
        defer { isLoadingMore = false }
        do {
            let endpoint = Endpoint.get(path, query: query + [URLQueryItem(name: "before", value: before)])
            let page = try await app.api.send(endpoint, as: MatchPage.self)
            guard started == generation else { return }
            let known = Set(items.map(\.id))
            extraItems.append(contentsOf: page.items.filter { !known.contains($0.id) })
            extraNextBefore = page.nextBefore
            hasExtraPages = true
        } catch is CancellationError {
            return
        } catch let error as APIError {
            guard started == generation else { return }
            loadMoreError = error
        } catch {
            guard started == generation else { return }
            loadMoreError = APIError(kind: .decoding, code: "decoding", serverMessage: nil)
        }
    }
}
