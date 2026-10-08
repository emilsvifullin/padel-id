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

    init(cacheKey: String?, endpoint: @escaping () -> Endpoint) {
        self.cacheKey = cacheKey
        self.endpoint = endpoint
    }

    func load(using app: AppModel) async {
        if value == nil, let cacheKey, let cached = app.cache.value(Value.self, for: cacheKey) {
            value = cached
            isStale = true
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await app.api.data(endpoint())
            let decoded = try JSONCoding.decoder.decode(Value.self, from: data)
            value = decoded
            if let cacheKey { app.cache.store(data, for: cacheKey) }
            error = nil
            isStale = false
            loadedOnce = true
        } catch is CancellationError {
            return
        } catch let apiError as APIError {
            error = apiError
            isStale = value != nil
        } catch {
            self.error = APIError(kind: .decoding, code: "decoding", serverMessage: nil)
            isStale = value != nil
        }
    }

    /// Replaces the current value (e.g. with the response of a mutation).
    func replace(with value: Value, data: Data? = nil, app: AppModel? = nil) {
        self.value = value
        error = nil
        isStale = false
        if let data, let cacheKey, let app { app.cache.store(data, for: cacheKey) }
    }

    var hasLoaded: Bool { loadedOnce }
}
