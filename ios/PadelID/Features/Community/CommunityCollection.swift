import Foundation
import Observation

/// Private social content lives only in memory. An authoritative denial
/// clears it immediately; pagination never grants access on cached membership.
@Observable
final class CommunityCollection<Item: Decodable & Sendable & Identifiable> where Item.ID: Hashable {
    private(set) var items: [Item] = []
    private(set) var nextOffset: Int?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var error: APIError?
    private var revision = UUID()
    private let path: String
    private let query: [URLQueryItem]
    private let windowLimit: Int?
    private let pageSize = 30
    private var windowStartOffset = 0
    private var windowEndOffset = 0

    /// A bounded sliding window is opt-in for feeds/comments. Other social
    /// lists keep their existing pagination behavior.
    init(_ path: String, query: [URLQueryItem] = [], windowLimit: Int? = nil) {
        self.path = path; self.query = query
        self.windowLimit = windowLimit.map { max(30, min($0, 150)) }
    }

    /// An explicit first-page load (including pull to refresh) returns to the
    /// newest prefix. Loading older rows can slide the opt-in window forward.
    func load(using app: AppModel, more: Bool = false) async {
        guard !more || (!isLoading && nextOffset != nil) else { return }
        let id = UUID(); revision = id; isLoading = true
        defer { if id == revision { isLoading = false } }
        let offset = more ? nextOffset ?? 0 : 0
        do {
            let page = try await fetch(using: app, offset: offset, limit: pageSize)
            guard id == revision, !Task.isCancelled else { return }
            let old = more ? items : []
            items = deduplicated(old + page.items)
            if !more { windowStartOffset = 0 }
            windowEndOffset = page.nextOffset ?? (offset + page.items.count)
            if let windowLimit {
                let drop = max(0, windowEndOffset - windowStartOffset - windowLimit)
                if drop > 0 {
                    items.removeFirst(min(drop, items.count))
                    windowStartOffset += drop
                }
                if items.count > windowLimit { items = Array(items.suffix(windowLimit)) }
            }
            nextOffset = page.nextOffset; hasLoaded = true; error = nil
        } catch let failure as APIError { fail(failure, revision: id) }
        catch is CancellationError { }
        catch {
            fail(APIError(kind: .decoding, code: "decoding", serverMessage: nil), revision: id)
        }
    }

    /// Reconcile the canonical currently visited range, atomically. A deleted
    /// or hidden item is removed even when no new item arrived. Stable IDs keep
    /// the List's visible rows and pagination instead of resetting every poll.
    /// Offset APIs can move as others insert/delete; this is not a DB snapshot.
    func refreshVisibleWindow(using app: AppModel) async {
        guard let windowLimit else { await load(using: app); return }
        guard !isLoading else { return }
        let id = UUID(); revision = id; isLoading = true
        defer { if id == revision { isLoading = false } }
        let start = windowStartOffset
        let count = min(windowLimit, max(pageSize, windowEndOffset - start))
        var staged: [Item] = []
        var offset = start
        var remaining = count
        var actualNext: Int?
        var end = start
        do {
            while remaining > 0 {
                let requested = min(pageSize, remaining)
                let page = try await fetch(using: app, offset: offset, limit: requested)
                guard id == revision, !Task.isCancelled else { return }
                staged += page.items
                actualNext = page.nextOffset
                end = page.nextOffset ?? (offset + page.items.count)
                remaining -= requested
                guard let next = page.nextOffset, next > offset else { break }
                offset = next
            }
            guard id == revision, !Task.isCancelled else { return }
            items = Array(deduplicated(staged).prefix(windowLimit))
            nextOffset = actualNext; windowEndOffset = end
            hasLoaded = true; error = nil
        } catch let failure as APIError { fail(failure, revision: id) }
        catch is CancellationError { }
        catch {
            fail(APIError(kind: .decoding, code: "decoding", serverMessage: nil), revision: id)
        }
    }

    /// A post denial also revokes its associated comment window immediately.
    func revokeAccess(_ failure: APIError) {
        guard Self.deniesAccess(failure) else { return }
        revision = UUID()
        items = []; nextOffset = nil; windowStartOffset = 0; windowEndOffset = 0
        error = failure; isLoading = false; hasLoaded = false
    }

    private func fetch(using app: AppModel, offset: Int, limit: Int) async throws -> CommunityPage<Item> {
        try await app.api.send(.get(path, query: query + [
            URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: String(limit))
        ]), as: CommunityPage<Item>.self)
    }
    private func deduplicated(_ rows: [Item]) -> [Item] {
        var seen: Set<Item.ID> = []
        return rows.filter { seen.insert($0.id).inserted }
    }
    private func fail(_ failure: APIError, revision id: UUID) {
        guard id == revision, !Task.isCancelled else { return }
        error = failure
        if Self.deniesAccess(failure) { revokeAccess(failure) }
    }
    static func deniesAccess(_ failure: APIError) -> Bool {
        failure.status == 401 || failure.status == 403 || failure.status == 404
    }
}
