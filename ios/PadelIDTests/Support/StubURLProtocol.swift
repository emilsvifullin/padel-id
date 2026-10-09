import Foundation

/// A canned HTTP answer (or a transport failure) for the stub protocol.
nonisolated struct StubResponse: Sendable {
    var status: Int
    var body: Data
    var failure: URLError?

    static func json(_ status: Int, _ text: String) -> StubResponse {
        StubResponse(status: status, body: Data(text.utf8), failure: nil)
    }

    static func data(_ status: Int, _ body: Data) -> StubResponse {
        StubResponse(status: status, body: body, failure: nil)
    }

    /// The gateway's error envelope.
    static func error(_ status: Int, code: String, message: String) -> StubResponse {
        let envelope = ["error": ["code": code, "message": message]]
        let body = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        return StubResponse(status: status, body: body, failure: nil)
    }

    static func transportFailure(_ code: URLError.Code) -> StubResponse {
        StubResponse(status: 0, body: Data(), failure: URLError(code))
    }
}

/// A request as the server would have received it.
nonisolated struct StubRecordedRequest: Sendable {
    let request: URLRequest
    let body: Data?

    var method: String { request.httpMethod ?? "GET" }
    var path: String { request.url?.path() ?? "" }

    func header(_ name: String) -> String? {
        request.value(forHTTPHeaderField: name)
    }

    /// The JSON body as a dictionary of strings (enough for assertions).
    func jsonBody() -> [String: String] {
        guard let body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object {
            result[key] = "\(value)"
        }
        return result
    }
}

/// Thread-safe counter for use inside `@Sendable` stub handlers.
nonisolated final class StubCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0

    func increment() {
        lock.withLock { current += 1 }
    }

    /// Increments and returns the new value.
    func next() -> Int {
        lock.withLock {
            current += 1
            return current
        }
    }

    var value: Int {
        lock.withLock { current }
    }
}

/// URL protocol that answers every request of a URLSession from in-memory
/// handlers. Handlers and recordings are keyed by host, so tests that run in
/// parallel never see each other's traffic: every test uses its own host.
nonisolated final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (StubRecordedRequest) -> StubResponse

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var recordings: [String: [StubRecordedRequest]] = [:]

    /// A fresh host and its base URL for one test.
    static func makeBaseURL() -> URL {
        let host = "stub-\(UUID().uuidString.lowercased()).padelid.test"
        return URL(string: "https://\(host)")!
    }

    static func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    static func register(_ baseURL: URL, handler: @escaping Handler) {
        let host = baseURL.host() ?? ""
        lock.withLock {
            handlers[host] = handler
            recordings[host] = []
        }
    }

    static func unregister(_ baseURL: URL) {
        let host = baseURL.host() ?? ""
        lock.withLock {
            handlers[host] = nil
            recordings[host] = nil
        }
    }

    static func requests(_ baseURL: URL) -> [StubRecordedRequest] {
        let host = baseURL.host() ?? ""
        return lock.withLock { recordings[host] ?? [] }
    }

    static func requests(_ baseURL: URL, path: String) -> [StubRecordedRequest] {
        requests(baseURL).filter { $0.path == path }
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let current = request
        let host = current.url?.host() ?? ""
        let recorded = StubRecordedRequest(request: current, body: Self.readBody(of: current))
        let handler: Handler? = Self.lock.withLock {
            Self.recordings[host, default: []].append(recorded)
            return Self.handlers[host]
        }
        let response = handler?(recorded)
            ?? StubResponse.error(404, code: "not_found", message: "Не найдено.")

        if let failure = response.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let url = current.url,
              let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
                                         headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands the body to protocols as a stream.
    private static func readBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        let capacity = 4096
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: capacity)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: capacity)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }
}
