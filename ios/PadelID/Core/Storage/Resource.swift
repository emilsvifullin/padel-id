import Foundation
import Observation

/// A remote value with cache-first loading: cached data is shown instantly
/// (and kept on failure), fresh data replaces it when the request succeeds.
@Observable
final class Resource<Value: Decodable> {
    private(set) var value: Value?
    private(set) var error: APIError?
    private(set) var isLoading = false
    /// True while the visible value comes from the cache and could not be refreshed.
    private(set) var isStale = false

    private let cacheKey: String?
    private let endpoint: () -> Endpoint
    private var loadedOnce = false
    private var requestID = UUID()

    init(cacheKey: String?, endpoint: @escaping () -> Endpoint) {
        self.cacheKey = cacheKey
        self.endpoint = endpoint
    }

    func load(using app: AppModel) async {
        let id = UUID()
        let request = endpoint()
        requestID = id
        if value == nil, let cacheKey, let cached = app.cache.value(Value.self, for: cacheKey) {
            value = cached
            isStale = true
        }
        isLoading = true
        defer { if requestID == id { isLoading = false } }
        do {
            let data = try await app.api.data(request)
            guard requestID == id, !Task.isCancelled else { return }
            let decoded = try JSONCoding.decoder.decode(Value.self, from: data)
            value = decoded
            if let cacheKey { app.cache.store(data, for: cacheKey) }
            error = nil
            isStale = false
            loadedOnce = true
        } catch is CancellationError {
            return
        } catch let apiError as APIError {
            guard requestID == id, !Task.isCancelled else { return }
            error = apiError
            if apiError.code == "player_not_found" {
                revokeAccess(apiError, using: app, path: request.path)
            } else {
                isStale = value != nil
            }
        } catch {
            guard requestID == id, !Task.isCancelled else { return }
            self.error = APIError(kind: .decoding, code: "decoding", serverMessage: nil)
            isStale = value != nil
        }
    }

    /// Pagination can receive the same authoritative denial independently of
    /// its first-page request. It must invalidate that first page as well.
    func revokeAccess(_ error: APIError, using app: AppModel, path: String? = nil) {
        guard error.code == "player_not_found" else { return }
        requestID = UUID()
        value = nil
        self.error = error
        isLoading = false
        isStale = false
        loadedOnce = false
        if let cacheKey { app.cache.remove(cacheKey) }
        let components = (path ?? endpoint().path).split(separator: "/")
        if components.count >= 3, components[0] == "v1", components[1] == "players",
           let playerId = UUID(uuidString: String(components[2])) {
            app.cache.removePlayerData(playerId)
        }
    }

    /// Replaces the current value (e.g. with the response of a mutation).
    func replace(with value: Value, data: Data? = nil, app: AppModel? = nil) {
        requestID = UUID()
        isLoading = false
        self.value = value
        error = nil
        isStale = false
        if let data, let cacheKey, let app { app.cache.store(data, for: cacheKey) }
    }

    var hasLoaded: Bool { loadedOnce }
}
