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
    /// Called once after a pass with the number of delivered operations.
    var onFinished: ((Int) -> Void)?
    /// The operation being sent right now (it cannot be discarded meanwhile).
    private(set) var inFlightId: UUID?

    /// Attempts after which a failing (server-side) delivery is given up.
    static let maxAttempts = 5

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
        guard id != inFlightId else { return }
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

    /// Delivers pending operations in order. Stops while the device cannot
    /// reach the server (or must sign in / update); a temporary server error
    /// keeps that operation for later and moves on; a rejection is recorded.
    func process(with api: APIClient) async {
        guard !isProcessing else { return }
        isProcessing = true
        var delivered = 0
        defer {
            isProcessing = false
            inFlightId = nil
            onFinished?(delivered)
        }
        var attempted = Set<UUID>()
        // Operations queued while sending are picked up in the same pass.
        while let operation = operations.first(where: { $0.failure == nil && !attempted.contains($0.id) }) {
            attempted.insert(operation.id)
            inFlightId = operation.id
            do {
                let data = try await api.data(operation.endpoint)
                inFlightId = nil
                operations.removeAll { $0.id == operation.id }
                persist()
                delivered += 1
                onDelivered?(operation, data)
            } catch let error as APIError {
                inFlightId = nil
                guard let index = operations.firstIndex(where: { $0.id == operation.id }) else { continue }
                operations[index].attempts += 1
                if error.isNetwork || error.code == "not_authenticated" || error.code == "client_outdated" {
                    persist()
                    return
                }
                if !error.isTransient || operations[index].attempts >= Self.maxAttempts {
                    operations[index].failure = error.message
                }
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
