import Foundation
import Observation

// MARK: - Search parameters

/// Sort orders of `GET v1/players/search` (`compatibility` is the server default).
nonisolated enum PlayersSort: String, CaseIterable, Identifiable, Hashable, Sendable {
    case compatibility
    case levelDescending = "level_desc"
    case levelAscending = "level_asc"
    case recent
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compatibility: "Совместимость"
        case .levelDescending: "Уровень по убыванию"
        case .levelAscending: "Уровень по возрастанию"
        case .recent: "Недавняя активность"
        case .name: "По имени"
        }
    }

    var symbol: String {
        switch self {
        case .compatibility: "person.2"
        case .levelDescending: "arrow.down"
        case .levelAscending: "arrow.up"
        case .recent: "clock"
        case .name: "textformat"
        }
    }
}

/// Court side filter. "Любая" means no filter; a concrete side also matches
/// players who play on both sides (server rule).
nonisolated enum PlayersSideFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case any, right, left

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: "Любая"
        case .right: "Справа"
        case .left: "Слева"
        }
    }

    var apiValue: String? {
        switch self {
        case .any: nil
        case .right: CourtSide.right.rawValue
        case .left: CourtSide.left.rawValue
        }
    }
}

/// City filter relative to the current user's city (the default).
nonisolated enum PlayersCityScope: Hashable, Sendable {
    case mine
    case city(NamedRef)
    case all

    init(selection: NamedRef?, myCity: NamedRef?) {
        if let selection {
            self = selection.id == myCity?.id ? .mine : .city(selection)
        } else {
            self = myCity == nil ? .mine : .all
        }
    }

    func resolve(myCity: NamedRef?) -> NamedRef? {
        switch self {
        case .mine: myCity
        case .city(let city): city
        case .all: nil
        }
    }
}

nonisolated struct PlayersFilter: Hashable, Sendable {
    static let levelBounds: ClosedRange<Double> = 0...7

    var cityScope: PlayersCityScope = .mine
    var minLevel: Double = 0
    var maxLevel: Double = 7
    var side: PlayersSideFilter = .any
    var reliableOnly = false
    var coachesOnly = false

    var hasLevelRange: Bool {
        minLevel > Self.levelBounds.lowerBound || maxLevel < Self.levelBounds.upperBound
    }

    /// Number of filters that differ from the defaults.
    func activeCount(myCity: NamedRef?) -> Int {
        var count = 0
        if cityScope.resolve(myCity: myCity)?.id != myCity?.id { count += 1 }
        if hasLevelRange { count += 1 }
        if side != .any { count += 1 }
        if reliableOnly { count += 1 }
        if coachesOnly { count += 1 }
        return count
    }
}

/// A fully resolved search request (also the identity of loaded results).
nonisolated struct PlayersSearchKey: Hashable, Sendable {
    let text: String
    let cityId: Int?
    let minLevel: Double
    let maxLevel: Double
    let side: PlayersSideFilter
    let reliableOnly: Bool
    let coachesOnly: Bool
    let sort: PlayersSort

    init(text: String, filter: PlayersFilter, myCity: NamedRef?, sort: PlayersSort) {
        self.text = text
        cityId = filter.cityScope.resolve(myCity: myCity)?.id
        minLevel = filter.minLevel
        maxLevel = filter.maxLevel
        side = filter.side
        reliableOnly = filter.reliableOnly
        coachesOnly = filter.coachesOnly
        self.sort = sort
    }

    /// Query parameters; only values that differ from the server defaults are sent.
    func queryItems(offset: Int, limit: Int) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if !text.isEmpty { items.append(URLQueryItem(name: "query", value: String(text.prefix(60)))) }
        if let cityId { items.append(URLQueryItem(name: "city_id", value: String(cityId))) }
        if minLevel > PlayersFilter.levelBounds.lowerBound {
            items.append(URLQueryItem(name: "min_level", value: String(minLevel)))
        }
        if maxLevel < PlayersFilter.levelBounds.upperBound {
            items.append(URLQueryItem(name: "max_level", value: String(maxLevel)))
        }
        if let side = side.apiValue { items.append(URLQueryItem(name: "side", value: side)) }
        if reliableOnly { items.append(URLQueryItem(name: "reliable_only", value: "true")) }
        if coachesOnly { items.append(URLQueryItem(name: "coaches_only", value: "true")) }
        if sort != .compatibility { items.append(URLQueryItem(name: "sort", value: sort.rawValue)) }
        items.append(URLQueryItem(name: "limit", value: String(limit)))
        if offset > 0 { items.append(URLQueryItem(name: "offset", value: String(offset))) }
        return items
    }
}

/// Identity of the work PlayersView performs for its current state.
nonisolated enum PlayersTaskID: Hashable, Sendable {
    case browse(cityId: Int?, revision: Int)
    case results(PlayersSearchKey, revision: Int)
}

nonisolated struct PlayersBrowseStamp: Hashable, Sendable {
    let cityId: Int?
    let revision: Int
}

// MARK: - Model

/// City used by the "Подходят вам" request, read when the request is built.
final class PlayersSuggestionScope {
    var cityId: Int?

    var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "sort", value: PlayersSort.compatibility.rawValue),
                     URLQueryItem(name: "limit", value: "20")]
        if let cityId { items.append(URLQueryItem(name: "city_id", value: String(cityId))) }
        return items
    }
}

/// Data of the players tab: suggestions and recent partners for the default
/// state, and paginated search results.
@Observable
final class PlayersDirectoryModel {
    static let pageSize = 30
    /// The gateway accepts offsets up to 1000.
    private static let maxOffset = 1000

    let suggested: Resource<SearchResult>
    let recent: Resource<[PlayerCard]>
    private let suggestionScope: PlayersSuggestionScope

    private(set) var key: PlayersSearchKey?
    private(set) var loadedKey: PlayersSearchKey?
    private(set) var items: [PlayerCard] = []
    private(set) var total = 0
    private(set) var nextOffset: Int?
    private(set) var error: APIError?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var loadMoreError: APIError?

    @ObservationIgnored private var loadedRevision: Int?
    @ObservationIgnored private var browseStamp: PlayersBrowseStamp?

    init() {
        let scope = PlayersSuggestionScope()
        suggestionScope = scope
        suggested = Resource(cacheKey: "players.suggested") {
            .get("v1/players/search", query: scope.queryItems)
        }
        recent = Resource(cacheKey: CacheKey.recentPlayers) {
            .get("v1/players/recent", query: [URLQueryItem(name: "limit", value: "20")])
        }
    }

    // MARK: Browse

    func loadBrowse(cityId: Int?, revision: Int, using app: AppModel, force: Bool) async {
        let stamp = PlayersBrowseStamp(cityId: cityId, revision: revision)
        if !force, browseStamp == stamp, suggested.error == nil, recent.error == nil {
            return
        }
        suggestionScope.cityId = cityId
        let suggestedResource = suggested
        let recentResource = recent
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await suggestedResource.load(using: app) }
            group.addTask { await recentResource.load(using: app) }
        }
        if !Task.isCancelled, suggested.error == nil, recent.error == nil {
            browseStamp = stamp
        }
    }

    // MARK: Results

    /// Whether results for this key and data revision are already shown.
    func isCurrent(_ key: PlayersSearchKey, revision: Int) -> Bool {
        self.key == key && loadedKey == key && loadedRevision == revision && error == nil
    }

    func search(_ key: PlayersSearchKey, revision: Int, using app: AppModel) async {
        if self.key != key {
            self.key = key
            error = nil
            loadMoreError = nil
        }
        isLoading = true
        do {
            let page = try await app.api.send(
                .get("v1/players/search", query: key.queryItems(offset: 0, limit: Self.pageSize)),
                as: SearchResult.self)
            guard self.key == key else { return }
            items = page.items
            total = page.total
            nextOffset = Self.validOffset(page.nextOffset)
            error = nil
            loadMoreError = nil
            loadedKey = key
            loadedRevision = revision
            isLoading = false
        } catch is CancellationError {
            if self.key == key { isLoading = false }
        } catch let apiError as APIError {
            guard self.key == key else { return }
            isLoading = false
            error = apiError
            if loadedKey != key {
                // Visible rows belong to another query: do not keep them.
                items = []
                total = 0
                nextOffset = nil
            }
        } catch {
            if self.key == key { isLoading = false }
        }
    }

    func loadMore(using app: AppModel) async {
        guard let key, loadedKey == key, let offset = nextOffset, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        loadMoreError = nil
        defer { isLoadingMore = false }
        do {
            let page = try await app.api.send(
                .get("v1/players/search", query: key.queryItems(offset: offset, limit: Self.pageSize)),
                as: SearchResult.self)
            guard self.key == key else { return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !known.contains($0.id) })
            total = page.total
            nextOffset = Self.validOffset(page.nextOffset)
        } catch is CancellationError {
            return
        } catch let apiError as APIError {
            guard self.key == key else { return }
            loadMoreError = apiError
        } catch {
            return
        }
    }

    func clearResults() {
        guard key != nil || !items.isEmpty || error != nil else { return }
        key = nil
        loadedKey = nil
        loadedRevision = nil
        items = []
        total = 0
        nextOffset = nil
        error = nil
        isLoading = false
        isLoadingMore = false
        loadMoreError = nil
    }

    private static func validOffset(_ offset: Int?) -> Int? {
        guard let offset, offset <= maxOffset else { return nil }
        return offset
    }
}
