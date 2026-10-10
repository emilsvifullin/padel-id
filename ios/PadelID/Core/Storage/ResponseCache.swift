import Foundation

/// On-disk cache of API responses, namespaced per user, so the app can show the
/// last known state instantly and while offline.
final class ResponseCache {
    private let fileManager = FileManager.default
    private var namespace: String?
    private var memory: [String: Data] = [:]

    private var root: URL? {
        guard let namespace else { return nil }
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appending(path: "api-cache", directoryHint: .isDirectory).appending(path: namespace, directoryHint: .isDirectory)
    }

    func activate(userId: UUID?) {
        let next = userId?.uuidString.lowercased()
        if next != namespace {
            memory.removeAll()
            namespace = next
        }
        if let root {
            try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    private func fileURL(_ key: String) -> URL? {
        let safe = key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "?", with: "_")
        return root?.appending(path: safe + ".json")
    }

    func data(for key: String) -> Data? {
        if let cached = memory[key] { return cached }
        guard let url = fileURL(key), let data = try? Data(contentsOf: url) else { return nil }
        memory[key] = data
        return data
    }

    func value<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        guard let data = data(for: key) else { return nil }
        return try? JSONCoding.decoder.decode(T.self, from: data)
    }

    func store(_ data: Data, for key: String) {
        memory[key] = data
        guard let url = fileURL(key) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func store<T: Encodable>(_ value: T, for key: String) {
        if let data = try? JSONCoding.encoder.encode(value) {
            store(data, for: key)
        }
    }

    func remove(_ key: String) {
        memory[key] = nil
        if let url = fileURL(key) { try? fileManager.removeItem(at: url) }
    }

    /// An authoritative access denial invalidates every cached view of a
    /// player, including periods that are not currently on screen.
    func removePlayerData(_ playerId: UUID) {
        remove(CacheKey.player(playerId))
        remove("\(CacheKey.player(playerId)).matches")
        remove(CacheKey.dna(playerId))
        let periods: [Int?] = [30, 90, 365, nil]
        for days in periods {
            remove(CacheKey.ratingHistory(playerId, days: days))
        }
    }

    /// Removes every cached response of every user (sign-out, account deletion).
    func purgeAll() {
        memory.removeAll()
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "api-cache")
        try? fileManager.removeItem(at: base)
        namespace = nil
    }
}
