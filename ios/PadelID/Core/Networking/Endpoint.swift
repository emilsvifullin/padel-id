import Foundation

/// A single API request description.
nonisolated struct Endpoint: Sendable {
    enum Method: String, Sendable { case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE" }

    var method: Method
    var path: String
    var query: [URLQueryItem] = []
    var body: Data? = nil
    var contentType: String? = nil
    var requiresAuth: Bool = true
    var idempotencyKey: UUID? = nil
    /// Whether the request may be retried automatically after a transient
    /// failure. GETs always may; mutations only when they are idempotent.
    var retryable: Bool = false

    static func get(_ path: String, query: [URLQueryItem] = []) -> Endpoint {
        Endpoint(method: .get, path: path, query: query, retryable: true)
    }

    static func json<Body: Encodable>(_ method: Method, _ path: String, _ body: Body, auth: Bool = true,
                                      idempotencyKey: UUID? = nil, retryable: Bool = false) -> Endpoint {
        Endpoint(method: method, path: path, body: try? JSONCoding.encoder.encode(body),
                 contentType: "application/json", requiresAuth: auth, idempotencyKey: idempotencyKey,
                 retryable: retryable || idempotencyKey != nil)
    }

    static func empty(_ method: Method, _ path: String, retryable: Bool = false) -> Endpoint {
        Endpoint(method: method, path: path, retryable: retryable)
    }
}

/// Encodable wrapper for arbitrary JSON dictionaries.
nonisolated struct AnyEncodable: Encodable, Sendable {
    let value: JSONValue
    init(_ value: JSONValue) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
