import Foundation

/// All routes must serve the same gateway contract and database. Probes carry
/// no account data; mutations are sent once, after a route has been selected.
@MainActor
final class APIRouteSelector {
    private let routes: [URL]
    private let session: URLSession
    private let freshFor: TimeInterval
    private let probeTimeout: TimeInterval
    private var current: URL?
    private var verifiedAt = Date.distantPast
    private var demotedUntil: [URL: Date] = [:]
    private var failures: [URL: Int] = [:]
    private var probing: Task<URL, Error>?
    private var probeFailures: [URL: Int] = [:]

    init(routes: [URL], session: URLSession, freshFor: TimeInterval = 60, probeTimeout: TimeInterval = 6) {
        precondition(!routes.isEmpty)
        self.routes = routes.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        self.session = session
        self.freshFor = freshFor
        self.probeTimeout = probeTimeout
    }

    func select() async throws -> URL {
        // Preserve the single-origin pipeline (including offline outbox behavior).
        if routes.count == 1 { return routes[0] }
        try Task.checkCancellation()
        if let current, Date.now.timeIntervalSince(verifiedAt) < freshFor { return current }
        if let probing {
            let observed = probeFailures
            let route = try await probing.value
            try Task.checkCancellation()
            guard failures[route] == observed[route] else { throw APIError.offline }
            return route
        }
        let preferred = current.map { [$0] + routes.filter { $0 != current } } ?? routes
        let available = preferred.filter { (demotedUntil[$0] ?? .distantPast) <= .now }
        let resting = preferred.filter { (demotedUntil[$0] ?? .distantPast) > .now }
        // A working shallow probe cannot rehabilitate a route whose actual
        // response just failed. Try cooldown routes only if all live ones fail.
        let stages = available.isEmpty ? [resting] : [available, resting]
        let session = session
        let timeout = probeTimeout
        let observedFailures = failures
        let task = Task<URL, Error> {
            for candidates in stages where !candidates.isEmpty {
                let winner = await withTaskGroup(of: URL?.self, returning: URL?.self) { group in
                    for (index, route) in candidates.enumerated() {
                        group.addTask {
                            do {
                                if index > 0 { try await Task.sleep(for: .milliseconds(350 * index)) }
                                try Task.checkCancellation()
                                return await Self.probe(route, session: session, timeout: timeout) ? route : nil
                            } catch { return nil }
                        }
                    }
                    for await result in group {
                        if let result { group.cancelAll(); return result }
                    }
                    return nil
                }
                try Task.checkCancellation()
                if let winner, failures[winner] == observedFailures[winner] { return winner }
            }
            throw APIError.offline
        }
        probeFailures = observedFailures
        probing = task
        defer { probing = nil }
        let winner = try await task.value
        try Task.checkCancellation()
        guard failures[winner] == observedFailures[winner] else { throw APIError.offline }
        current = winner
        verifiedAt = .now
        demotedUntil.removeValue(forKey: winner)
        return winner
    }

    func failed(_ route: URL) {
        failures[route, default: 0] += 1
        demotedUntil[route] = .now.addingTimeInterval(300)
        if current == route { current = nil; verifiedAt = .distantPast }
    }

    private nonisolated static func probe(_ route: URL, session: URLSession, timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                var request = URLRequest(url: route.appending(path: "v1/health"), cachePolicy: .reloadIgnoringLocalCacheData)
                request.timeoutInterval = timeout
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                do {
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse, http.url == request.url, http.statusCode == 200,
                          http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("application/json") == true,
                          let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                    return body["status"] as? String == "ok"
                } catch { return false }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
