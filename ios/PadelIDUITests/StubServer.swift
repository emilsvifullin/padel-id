import Foundation
import Network

/// A request as the stub server received it.
struct StubRequest: Sendable {
    let method: String
    /// The path without the leading slash and without the query ("v1/home").
    let path: String
    let query: [String: String]
    /// Header names are lowercased.
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    var bodyText: String {
        String(decoding: body, as: UTF8.self)
    }

    /// The body as a JSON object (dictionary), if it is one.
    var jsonObject: [String: Any]? {
        guard !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

/// A canned HTTP answer.
struct StubResponse: Sendable {
    var status: Int
    var body: Data

    static func json(_ body: Data, status: Int = 200) -> StubResponse {
        StubResponse(status: status, body: body)
    }

    /// The gateway's error envelope: {"error":{"code":…,"message":…}}.
    static func error(_ status: Int, code: String, message: String) -> StubResponse {
        let envelope: [String: [String: String]] = ["error": ["code": code, "message": message]]
        let body = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        return StubResponse(status: status, body: body)
    }

    static let noContent = StubResponse(status: 204, body: Data())

    static let notFound = StubResponse.error(404, code: "not_found", message: "Не найдено.")

    static let serviceUnavailable = StubResponse.error(
        503, code: "service_unavailable", message: "Сервис временно недоступен. Попробуйте через минуту.")

    /// The full HTTP/1.1 response: status line, headers and body.
    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        if status != 204 {
            head += "Content-Type: application/json; charset=utf-8\r\n"
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        if status != 204 {
            data.append(body)
        }
        return data
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 409: "Conflict"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}

enum StubServerError: Error, CustomStringConvertible {
    case listenerFailed(String)
    case notReady

    var description: String {
        switch self {
        case .listenerFailed(let reason): "The stub server could not listen: \(reason)"
        case .notReady: "The stub server did not become ready in time"
        }
    }
}

/// Minimal HTTP/1.1 request parsing (request line, headers, Content-Length body).
private enum StubHTTPParser {
    enum Result {
        /// More bytes are needed.
        case incomplete
        case request(StubRequest)
        case invalid
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    static func parse(_ data: Data) -> Result {
        guard let terminator = data.range(of: headerTerminator) else {
            return data.count > 64 * 1024 ? .invalid : .incomplete
        }
        let head = String(decoding: data[data.startIndex..<terminator.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let length = max(0, Int(headers["content-length"] ?? "") ?? 0)
        let bodyStart = terminator.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return .incomplete }
        let bodyEnd = data.index(bodyStart, offsetBy: length)
        let body = Data(data[bodyStart..<bodyEnd])

        let target = String(requestLine[1])
        let components = URLComponents(string: "http://localhost" + (target.hasPrefix("/") ? target : "/" + target))
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        let rawPath = components?.path ?? String(target.split(separator: "?").first ?? "")
        return .request(StubRequest(
            method: String(requestLine[0]).uppercased(),
            path: StubServer.normalized(rawPath),
            query: query,
            headers: headers,
            body: body))
    }
}

private enum StubListenerEvent: Sendable {
    case ready
    case failed(String)
    case other
}

/// Carries a connection from Network's callback into main-actor code; every
/// callback runs on the main queue, so the connection never crosses threads.
private struct StubConnectionBox: @unchecked Sendable {
    let connection: NWConnection
}

/// In-process HTTP/1.1 server for UI tests. Network.framework delivers every
/// callback on the main queue; handler bodies hop into main-actor code with
/// `MainActor.assumeIsolated`. Each response is sent with `Connection: close`
/// and the connection is closed afterwards.
@MainActor
final class StubServer {
    enum Scenario: Sendable {
        /// Signs up; `v1/me` reports `needs_onboarding` until onboarding is sent.
        case newUser
        /// Signs in as Михаил Орлов with full history.
        case existingUser
    }

    static let currentUserID = "03eed36a-a8a4-4767-9dd6-b1f89bf7267b"
    static let partnerID = "d8b58bd9-8f8c-4732-a129-148692946aed"
    static let pendingMatchID = "cd3a6439-4648-41e4-8ed1-799cff17bb62"

    let scenario: Scenario
    private(set) var port: UInt16 = 0
    private(set) var requests: [StubRequest] = []
    /// Fixtures that were requested but are not part of the test bundle.
    private(set) var missingFixtures: [String] = []
    private(set) var isOnboarded = false

    private var listener: NWListener?
    private var listenerFailure: String?
    private var connections: [Int: NWConnection] = [:]
    private var buffers: [Int: Data] = [:]
    private var nextConnectionID = 0
    private var overrides: [String: StubResponse] = [:]
    private var fixtureCache: [String: Data] = [:]
    private var confirmedMatchIDs: Set<String> = []

    init(scenario: Scenario) {
        self.scenario = scenario
    }

    // MARK: - Lifecycle

    /// Starts listening on a free port (all interfaces, IPv4 and IPv6) and
    /// waits until the port is known.
    func start(timeout: TimeInterval = 10) throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            let event: StubListenerEvent
            switch state {
            case .ready:
                event = .ready
            case .failed(let error):
                event = .failed("\(error)")
            default:
                event = .other
            }
            MainActor.assumeIsolated {
                if let self {
                    self.handleListenerEvent(event)
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            let box = StubConnectionBox(connection: connection)
            MainActor.assumeIsolated {
                if let self {
                    self.accept(box.connection)
                } else {
                    box.connection.cancel()
                }
            }
        }
        self.listener = listener
        listener.start(queue: .main)

        let deadline = Date().addingTimeInterval(timeout)
        while port == 0 && listenerFailure == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let listenerFailure {
            stop()
            throw StubServerError.listenerFailed(listenerFailure)
        }
        guard port != 0 else {
            stop()
            throw StubServerError.notReady
        }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connections.removeAll()
        buffers.removeAll()
    }

    private func handleListenerEvent(_ event: StubListenerEvent) {
        switch event {
        case .ready:
            port = listener?.port?.rawValue ?? 0
        case .failed(let reason):
            listenerFailure = reason
        case .other:
            break
        }
    }

    // MARK: - Per-test configuration

    /// Answers `method path` with `response` until the override is removed.
    func setOverride(_ method: String, _ path: String, _ response: StubResponse) {
        overrides[Self.routeKey(method, path)] = response
    }

    func removeOverride(_ method: String, _ path: String) {
        overrides.removeValue(forKey: Self.routeKey(method, path))
    }

    /// Recorded requests for a method and path (query ignored).
    func recorded(_ method: String, _ path: String) -> [StubRequest] {
        let normalizedPath = Self.normalized(path)
        return requests.filter { $0.method == method.uppercased() && $0.path == normalizedPath }
    }

    nonisolated static func normalized(_ path: String) -> String {
        var value = path
        while value.hasPrefix("/") { value.removeFirst() }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func routeKey(_ method: String, _ path: String) -> String {
        method.uppercased() + " " + normalized(path)
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        nextConnectionID += 1
        let id = nextConnectionID
        connections[id] = connection
        buffers[id] = Data()
        connection.stateUpdateHandler = { [weak self] state in
            let finished: Bool
            switch state {
            case .failed, .cancelled:
                finished = true
            default:
                finished = false
            }
            guard finished else { return }
            MainActor.assumeIsolated {
                if let self {
                    self.forget(id)
                }
            }
        }
        connection.start(queue: .main)
        receive(on: id)
    }

    private func receive(on id: Int) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
            let failed = error != nil
            MainActor.assumeIsolated {
                if let self {
                    self.didReceive(content, on: id, isComplete: isComplete, failed: failed)
                }
            }
        }
    }

    private func didReceive(_ content: Data?, on id: Int, isComplete: Bool, failed: Bool) {
        guard connections[id] != nil else { return }
        if let content, !content.isEmpty {
            buffers[id, default: Data()].append(content)
        }
        switch StubHTTPParser.parse(buffers[id] ?? Data()) {
        case .request(let request):
            buffers[id] = Data()
            requests.append(request)
            send(response(for: request), on: id)
        case .invalid:
            buffers[id] = Data()
            send(.error(400, code: "bad_request", message: "Некорректный запрос."), on: id)
        case .incomplete:
            if isComplete || failed {
                close(id)
            } else {
                receive(on: id)
            }
        }
    }

    private func send(_ response: StubResponse, on id: Int) {
        guard let connection = connections[id] else { return }
        connection.send(content: response.serialized(), completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                if let self {
                    self.close(id)
                }
            }
        })
    }

    private func close(_ id: Int) {
        buffers.removeValue(forKey: id)
        if let connection = connections.removeValue(forKey: id) {
            connection.cancel()
        }
    }

    private func forget(_ id: Int) {
        buffers.removeValue(forKey: id)
        connections.removeValue(forKey: id)
    }

    // MARK: - Routing

    private func response(for request: StubRequest) -> StubResponse {
        if let override = overrides[Self.routeKey(request.method, request.path)] {
            return override
        }
        let segments = request.path.split(separator: "/").map(String.init)
        guard segments.first == "v1" else { return .notFound }
        let parts = Array(segments.dropFirst())
        let method = request.method

        switch (method, parts.joined(separator: "/")) {
        // Authentication
        case ("POST", "auth/signup"):
            return fixture("signup")
        case ("POST", "auth/login"), ("POST", "auth/refresh"):
            return fixture(scenario == .newUser ? "new_user_session" : "session")
        case ("POST", "auth/logout"):
            return .noContent

        // Current user
        case ("GET", "me"):
            if scenario == .newUser && !isOnboarded {
                return fixture("me_new")
            }
            return fixture("me")
        case ("POST", "me/onboarding"):
            isOnboarded = true
            return fixture("me")
        case ("PATCH", "me"):
            return fixture("me")
        case ("GET", "me/username-check"):
            return fixture("username_check")
        case ("PUT", "me/dna-self"):
            return fixture("dna")
        case ("GET", "home"):
            return fixture(scenario == .newUser ? "home_new" : "home")

        // Matches
        case ("GET", "matches"):
            return fixture(request.query["scope"] == "open" ? "matches_open" : "matches_history")
        case ("POST", "matches"):
            return fixture("match_created", status: 201)
        case ("POST", "matches/preview"):
            return fixture("preview")

        // Players, places, coaches
        case ("GET", "players/search"):
            return fixture("search")
        case ("GET", "players/recent"):
            return fixture("recent_players")
        case ("GET", "cities"):
            return fixture("cities")
        case ("GET", "clubs"):
            return fixture("clubs")
        case ("GET", "coach/application"):
            return fixture("coach_application")
        default:
            break
        }

        if parts.count >= 2, parts[0] == "matches" {
            let matchID = parts[1].lowercased()
            if parts.count == 2, method == "GET" {
                if matchID == Self.pendingMatchID {
                    return fixture(confirmedMatchIDs.contains(matchID) ? "match_action_confirmed" : "match_action")
                }
                return fixture("match_confirmed")
            }
            if parts.count == 3 {
                switch (method, parts[2]) {
                case ("POST", "confirm"):
                    confirmedMatchIDs.insert(matchID)
                    return fixture("match_action_confirmed")
                case ("POST", "dispute"):
                    return fixture("match_action")
                case ("PUT", "feedback"):
                    return fixture("match_confirmed")
                default:
                    break
                }
            }
        }

        if parts.count >= 2, parts[0] == "players", method == "GET" {
            // The current user's own profile and history have fixtures of
            // their own when the bundle contains them.
            let isCurrentUser = parts[1].lowercased() == Self.currentUserID
            if parts.count == 2 {
                return fixture(isCurrentUser ? preferredFixture("player_profile_me", fallback: "player_profile") : "player_profile")
            }
            if parts.count == 3 {
                switch parts[2] {
                case "rating-history": return fixture("rating_history")
                case "dna": return fixture("dna")
                case "matches":
                    return fixture(isCurrentUser ? preferredFixture("player_matches_me", fallback: "player_matches") : "player_matches")
                default: break
                }
            }
        }

        return .notFound
    }

    // MARK: - Fixtures

    /// `name` if the test bundle contains that fixture, otherwise `fallback`.
    private func preferredFixture(_ name: String, fallback: String) -> String {
        fixtureURL(name) == nil ? fallback : name
    }

    private func fixtureURL(_ name: String) -> URL? {
        let bundle = Bundle(for: StubServer.self)
        return bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "json")
    }

    private func fixture(_ name: String, status: Int = 200) -> StubResponse {
        if let cached = fixtureCache[name] {
            return .json(cached, status: status)
        }
        guard let url = fixtureURL(name), let data = try? Data(contentsOf: url) else {
            if !missingFixtures.contains(name) {
                missingFixtures.append(name)
            }
            return .error(500, code: "internal", message: "Фикстура \(name) не найдена.")
        }
        fixtureCache[name] = data
        return .json(data, status: status)
    }
}
