import Foundation

/// HTTP client for the Padel ID API gateway.
///
/// * Adds the bearer token and refreshes it ahead of expiry. Concurrent
///   requests share a single in-flight refresh (refresh tokens rotate, so two
///   parallel refreshes would invalidate each other).
/// * Retries a request once after a `session_expired` response (the token may
///   have been revoked or expired in flight).
/// * Retries idempotent requests after transient failures with backoff.
/// * Never logs request bodies or tokens.
final class APIClient {
    static let shared = APIClient(sessionStore: .shared)

    let baseURL: URL
    let sessionStore: SessionStore
    private let urlSession: URLSession
    private var refreshTask: Task<Session, Error>?

    /// Called when the session can no longer be refreshed.
    var onSessionInvalidated: (() -> Void)?

    init(baseURL: URL = AppEnvironment.apiBaseURL, sessionStore: SessionStore, urlSession: URLSession? = nil) {
        self.baseURL = baseURL
        self.sessionStore = sessionStore
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 60
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpAdditionalHeaders = ["Accept-Language": "ru"]
            self.urlSession = URLSession(configuration: configuration)
        }
    }

    // MARK: - Public API

    func send<T: Decodable>(_ endpoint: Endpoint, as type: T.Type = T.self) async throws -> T {
        let data = try await perform(endpoint)
        do {
            return try JSONCoding.decoder.decode(T.self, from: data)
        } catch {
            throw APIError(kind: .decoding, code: "decoding", serverMessage: nil)
        }
    }

    func sendVoid(_ endpoint: Endpoint) async throws {
        _ = try await perform(endpoint)
    }

    /// Raw response data (used by the response cache).
    func data(_ endpoint: Endpoint) async throws -> Data {
        try await perform(endpoint)
    }

    // MARK: - Pipeline

    private func perform(_ endpoint: Endpoint) async throws -> Data {
        var attempt = 0
        var refreshedAfterRejection = false
        while true {
            try Task.checkCancellation()
            do {
                let token = endpoint.requiresAuth ? try await validAccessToken() : nil
                return try await execute(endpoint, token: token)
            } catch let error as APIError {
                if endpoint.requiresAuth, error.code == "session_expired", !refreshedAfterRejection {
                    refreshedAfterRejection = true
                    _ = try await refreshSession(force: true)
                    continue
                }
                if endpoint.retryable, error.isTransient, attempt < 2 {
                    attempt += 1
                    try await Task.sleep(for: .milliseconds(attempt == 1 ? 600 : 1800))
                    continue
                }
                throw error
            }
        }
    }

    private func execute(_ endpoint: Endpoint, token: String?) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: endpoint.path), resolvingAgainstBaseURL: false)!
        if !endpoint.query.isEmpty { components.queryItems = endpoint.query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = endpoint.method.rawValue
        request.httpBody = endpoint.body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppEnvironment.buildNumber, forHTTPHeaderField: "X-Padelid-Build")
        if let contentType = endpoint.contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let key = endpoint.idempotencyKey {
            request.setValue(key.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError.offline
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError(kind: .decoding, code: "decoding", serverMessage: nil)
        }
        if (200..<300).contains(http.statusCode) {
            return data
        }
        let envelope = try? JSONCoding.decoder.decode(ErrorEnvelope.self, from: data)
        throw APIError(kind: .server(status: http.statusCode),
                       code: envelope?.error.code ?? (http.statusCode >= 500 ? "service_unavailable" : "internal"),
                       serverMessage: envelope?.error.message)
    }

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable { let code: String; let message: String? }
        let error: Body
    }

    // MARK: - Tokens

    private func validAccessToken() async throws -> String {
        guard let session = sessionStore.session else {
            throw APIError(kind: .server(status: 401), code: "not_authenticated", serverMessage: nil)
        }
        if session.expiryDate.timeIntervalSinceNow > 60 {
            return session.accessToken
        }
        return try await refreshSession(force: false).accessToken
    }

    /// Refreshes the session; concurrent callers await the same task.
    @discardableResult
    func refreshSession(force: Bool) async throws -> Session {
        if let refreshTask {
            return try await refreshTask.value
        }
        guard let current = sessionStore.session else {
            throw APIError(kind: .server(status: 401), code: "not_authenticated", serverMessage: nil)
        }
        if !force, current.expiryDate.timeIntervalSinceNow > 60 {
            return current
        }
        let task = Task<Session, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            let endpoint = Endpoint.json(.post, "v1/auth/refresh", ["refresh_token": current.refreshToken], auth: false, retryable: true)
            do {
                let data = try await self.perform(endpoint)
                let session = try JSONCoding.decoder.decode(Session.self, from: data)
                self.sessionStore.save(session)
                return session
            } catch let error as APIError where error.code == "session_expired" || error.code == "not_authenticated" {
                // The refresh token is no longer valid unless another refresh
                // already replaced it in the meantime.
                if self.sessionStore.session?.refreshToken == current.refreshToken {
                    self.sessionStore.clear()
                    self.onSessionInvalidated?()
                }
                throw error
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }
}
