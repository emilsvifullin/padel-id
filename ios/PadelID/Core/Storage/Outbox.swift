import Foundation
import Observation

/// A mutation recorded while offline (or interrupted by a network failure) and
/// delivered later. Every operation is idempotent on the server: match
/// creation carries an idempotency key; confirmations, disputes and feedback
/// are state-based.
nonisolated struct PendingOperation: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case createMatch, confirmMatch, disputeMatch, submitFeedback
    }

    let id: UUID
    let kind: Kind
    let method: String
    let path: String
    let body: Data?
    let idempotencyKey: UUID?
    let matchId: UUID?
    let title: String
    let subtitle: String
    let createdAt: Date
    var attempts: Int = 0
    var failure: String? = nil

    var endpoint: Endpoint {
        Endpoint(method: Endpoint.Method(rawValue: method) ?? .post, path: path, body: body,
                 contentType: body == nil ? nil : "application/json", requiresAuth: true,
                 idempotencyKey: idempotencyKey, retryable: false)
    }
}

@Observable
final class Outbox {
    private(set) var operations: [PendingOperation] = []
    private(set) var isProcessing = false
    private var fileURL: URL?

    /// Called on the main actor after an operation was delivered.
    var onDelivered: ((PendingOperation, Data) -> Void)?

    var pending: [PendingOperation] { operations.filter { $0.failure == nil } }
    var failed: [PendingOperation] { operations.filter { $0.failure != nil } }

    func activate(userId: UUID?) {
        guard let userId else {
            operations = []
            fileURL = nil
            return
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "outbox", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appending(path: userId.uuidString.lowercased() + ".json")
        if AppEnvironment.shouldResetState, let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONCoding.decoder.decode([PendingOperation].self, from: data) {
            operations = stored
        } else {
            operations = []
        }
    }

    func enqueue(_ operation: PendingOperation) {
        operations.append(operation)
        persist()
    }

    func discard(_ id: UUID) {
        operations.removeAll { $0.id == id }
        persist()
    }

    func contains(kind: PendingOperation.Kind, matchId: UUID) -> Bool {
        operations.contains { $0.kind == kind && $0.matchId == matchId && $0.failure == nil }
    }

    func purge() {
        operations = []
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
    }

    /// Delivers pending operations in order. Stops at the first transient
    /// failure (the network is likely still unavailable).
    func process(with api: APIClient) async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        var attempted = Set<UUID>()
        // Operations queued while sending are picked up in the next pass.
        while let operation = operations.first(where: { $0.failure == nil && !attempted.contains($0.id) }) {
            attempted.insert(operation.id)
            do {
                let data = try await api.data(operation.endpoint)
                operations.removeAll { $0.id == operation.id }
                persist()
                onDelivered?(operation, data)
            } catch let error as APIError {
                guard let index = operations.firstIndex(where: { $0.id == operation.id }) else { continue }
                operations[index].attempts += 1
                if error.isTransient || error.code == "not_authenticated" {
                    persist()
                    return
                }
                operations[index].failure = error.message
                persist()
            } catch {
                return
            }
        }
    }

    private func persist() {
        guard let fileURL else { return }
        if let data = try? JSONCoding.encoder.encode(operations) {
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
