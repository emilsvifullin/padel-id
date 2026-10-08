import Foundation
import Observation

/// Holds the current auth session and persists it in the Keychain.
@Observable
final class SessionStore {
    /// Shared by the UI and background refresh so that rotating refresh
    /// tokens are never used by two independent clients.
    static let shared = SessionStore()
    private static let account = "session.v1"

    private(set) var session: Session?

    init() {
        if AppEnvironment.shouldResetState {
            Keychain.delete(account: Self.account)
        }
        if let data = Keychain.load(account: Self.account),
           let stored = try? JSONCoding.decoder.decode(Session.self, from: data) {
            session = stored
        }
    }

    var userId: UUID? { session?.user.id }

    func save(_ session: Session) {
        self.session = session
        if let data = try? JSONCoding.encoder.encode(session) {
            _ = Keychain.save(data, account: Self.account)
        }
    }

    func clear() {
        session = nil
        Keychain.delete(account: Self.account)
    }
}
