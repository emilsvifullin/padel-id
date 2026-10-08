import Foundation

/// Outcome of a match mutation (confirm, dispute, cancel, feedback).
nonisolated enum MatchActionResult: Sendable {
    /// The server applied the change; the fresh match and its raw response.
    case updated(MatchDetail, Data)
    /// No connection: the change waits in the outbox and is sent automatically.
    case queued
    /// The match changed in the meantime (`version_conflict`): reload and explain.
    case conflict(APIError)
    case failed(APIError)
}

/// One player's feedback in `PUT v1/matches/{id}/feedback` (empty arrays remove it).
nonisolated struct MatchFeedbackRating: Encodable, Hashable, Sendable {
    let playerId: String
    let strengths: [String]
    let improvements: [String]
}

private nonisolated struct MatchVersionBody: Encodable, Sendable {
    let version: Int
}

private nonisolated struct MatchDisputeBody: Encodable, Sendable {
    let version: Int
    let reason: DisputeReason
    let comment: String?
}

private nonisolated struct MatchFeedbackBody: Encodable, Sendable {
    let ratings: [MatchFeedbackRating]
}

/// Match mutations with the offline fallback required by the architecture:
/// confirmations, disputes and feedback go to the outbox when the device is
/// offline or the request fails for network reasons; cancelling needs a
/// connection.
enum MatchActions {
    static let disputeCommentLimit = 140

    static func confirm(_ match: MatchDetail, app: AppModel) async -> MatchActionResult {
        let endpoint = Endpoint.json(.post, path(match.id, "confirm"), MatchVersionBody(version: match.version), retryable: true)
        return await perform(endpoint, match: match, app: app, offlineKind: .confirmMatch, title: "Подтверждение результата")
    }

    static func dispute(_ match: MatchDetail, reason: DisputeReason, comment: String, app: AppModel) async -> MatchActionResult {
        let trimmed = String(comment.trimmingCharacters(in: .whitespacesAndNewlines).prefix(disputeCommentLimit))
        let body = MatchDisputeBody(version: match.version, reason: reason, comment: trimmed.isEmpty ? nil : trimmed)
        let endpoint = Endpoint.json(.post, path(match.id, "dispute"), body, retryable: true)
        return await perform(endpoint, match: match, app: app, offlineKind: .disputeMatch, title: "Возражение по результату")
    }

    static func cancel(_ match: MatchDetail, app: AppModel) async -> MatchActionResult {
        guard app.isOnline else { return .failed(.offline) }
        let endpoint = Endpoint.json(.post, path(match.id, "cancel"), MatchVersionBody(version: match.version), retryable: true)
        return await perform(endpoint, match: match, app: app, offlineKind: nil, title: "")
    }

    static func submitFeedback(_ match: MatchDetail, ratings: [MatchFeedbackRating], app: AppModel) async -> MatchActionResult {
        let endpoint = Endpoint.json(.put, path(match.id, "feedback"), MatchFeedbackBody(ratings: ratings), retryable: true)
        return await perform(endpoint, match: match, app: app, offlineKind: .submitFeedback, title: "Отметки игрокам")
    }

    /// Whether a confirmation or dispute of this match waits in the outbox.
    static func hasQueuedAnswer(for matchId: UUID, app: AppModel) -> Bool {
        app.outbox.contains(kind: .confirmMatch, matchId: matchId) || app.outbox.contains(kind: .disputeMatch, matchId: matchId)
    }

    /// The failure text of an answer the server rejected after offline delivery.
    static func failedAnswer(for matchId: UUID, app: AppModel) -> String? {
        app.outbox.failed.first { operation in
            operation.matchId == matchId && (operation.kind == .confirmMatch || operation.kind == .disputeMatch)
        }?.failure
    }

    // MARK: - Pipeline

    private static func path(_ id: UUID, _ action: String) -> String {
        "v1/matches/\(id.uuidString.lowercased())/\(action)"
    }

    private static func perform(_ endpoint: Endpoint, match: MatchDetail, app: AppModel,
                                offlineKind: PendingOperation.Kind?, title: String) async -> MatchActionResult {
        if let offlineKind, !app.isOnline {
            enqueue(offlineKind, endpoint: endpoint, match: match, title: title, app: app)
            return .queued
        }
        let data: Data
        do {
            data = try await app.api.data(endpoint)
        } catch let error as APIError {
            if error.isNetwork, let offlineKind {
                enqueue(offlineKind, endpoint: endpoint, match: match, title: title, app: app)
                return .queued
            }
            if error.code == "version_conflict" {
                return .conflict(error)
            }
            return .failed(error)
        } catch {
            return .failed(APIError(kind: .server(status: 0), code: "interrupted",
                                    serverMessage: "Действие прервано. Попробуйте ещё раз."))
        }

        app.dataDidChange()
        guard let updated = try? JSONCoding.decoder.decode(MatchDetail.self, from: data) else {
            return .failed(APIError(kind: .decoding, code: "decoding", serverMessage: nil))
        }
        app.cache.store(data, for: CacheKey.match(match.id))
        return .updated(updated, data)
    }

    private static func enqueue(_ kind: PendingOperation.Kind, endpoint: Endpoint, match: MatchDetail,
                                title: String, app: AppModel) {
        // A newer answer supersedes rejected ones and the opposite answer;
        // newer feedback replaces feedback that has not been sent yet.
        let group: [PendingOperation.Kind] = kind == .submitFeedback ? [.submitFeedback] : [.confirmMatch, .disputeMatch]
        for operation in app.outbox.operations where operation.matchId == match.id && group.contains(operation.kind) {
            let isSamePendingAnswer = operation.kind == kind && operation.failure == nil && kind != .submitFeedback
            if !isSamePendingAnswer {
                app.outbox.discard(operation.id)
            }
        }
        if !app.outbox.contains(kind: kind, matchId: match.id) {
            let operation = PendingOperation(
                id: UUID(),
                kind: kind,
                method: endpoint.method.rawValue,
                path: endpoint.path,
                body: endpoint.body,
                idempotencyKey: nil,
                matchId: match.id,
                title: title,
                subtitle: subtitle(for: match),
                createdAt: .now)
            app.outbox.enqueue(operation)
        }
        if app.isOnline {
            Task { await app.flushOutbox() }
        }
    }

    private static func subtitle(for match: MatchDetail) -> String {
        "\(Format.score(match.sets, perspective: match.viewer.team ?? 1)) · \(Format.shortDate(match.playedAt))"
    }
}

/// Name helpers shared by the match screens.
nonisolated enum MatchesNames {
    /// First name and last initial for long names ("Александра Иванова" → "Александра И.").
    static func short(_ card: PlayerCard) -> String {
        let name = card.displayName
        guard !card.deleted, name.count > 12 else { return name }
        let parts = name.split(separator: " ")
        guard parts.count >= 2, let initial = parts[parts.count - 1].first else { return name }
        return "\(parts[0]) \(initial)."
    }

    /// "Иван П. / Мария С." for compact rows.
    static func shortPair(_ cards: [PlayerCard]) -> String {
        cards.map { short($0) }.joined(separator: " / ")
    }

    /// "Иван Петров и Мария Сидорова" for VoiceOver and explanations.
    static func fullPair(_ cards: [PlayerCard]) -> String {
        cards.map(\.displayName).joined(separator: " и ")
    }
}
