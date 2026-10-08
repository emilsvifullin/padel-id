import Foundation
import Observation
import SwiftUI

/// Root application state: authentication phase, the current user and the
/// shared infrastructure (API client, cache, offline outbox, connectivity).
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case unavailable
        case signedOut
        case onboarding
        case ready
    }

    enum Tab: Hashable {
        case padelID, matches, players
    }

    private(set) var phase: Phase = .launching
    private(set) var me: Me?
    private(set) var launchError: APIError?
    var selectedTab: Tab = .padelID
    /// Bumped after any mutation so that visible screens reload.
    private(set) var dataRevision = 0
    /// Matches needing the user's action (badge on the Matches tab).
    var actionCount = 0
    /// A recovery key that must be shown to the user (after sign-up or recovery).
    var recoveryKeyToShow: String?
    /// Explains why the user was signed out (expired session, deleted account).
    var signOutNotice: String?
    /// Presents the match editor sheet (new match or edit) above the tabs.
    var matchEditor: MatchEditorRequest?
    /// Presents the account & settings sheet.
    var isAccountPresented = false

    let sessionStore: SessionStore
    let api: APIClient
    let cache = ResponseCache()
    let outbox = Outbox()
    let connectivity = Connectivity()

    init(api: APIClient = .shared) {
        self.api = api
        sessionStore = api.sessionStore
        if AppEnvironment.shouldResetState {
            cache.purgeAll()
        }
        api.onSessionInvalidated = { [weak self] in
            self?.handleSessionInvalidated()
        }
        outbox.onDelivered = { [weak self] _, _ in
            self?.dataDidChange()
        }
        connectivity.whenReconnected { [weak self] in
            guard let self else { return }
            Task { await self.flushOutbox() }
            self.dataDidChange()
        }
    }

    var isOnline: Bool { connectivity.isOnline }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard let session = sessionStore.session else {
            phase = .signedOut
            return
        }
        activateStorage(for: session.user.id)
        if let cached = cache.value(Me.self, for: CacheKey.me) {
            apply(me: cached)
        }
        await refreshMe()
        await flushOutbox()
    }

    func refreshMe() async {
        do {
            let data = try await api.data(.get("v1/me"))
            let fresh = try JSONCoding.decoder.decode(Me.self, from: data)
            cache.store(data, for: CacheKey.me)
            launchError = nil
            apply(me: fresh)
        } catch let error as APIError {
            if me == nil {
                if sessionStore.session == nil {
                    phase = .signedOut
                } else {
                    launchError = error
                    phase = .unavailable
                }
            }
        } catch {
            if me == nil { phase = .unavailable }
        }
    }

    func retryLaunch() async {
        phase = .launching
        await refreshMe()
    }

    func apply(me: Me) {
        self.me = me
        withAnimation(.smooth) {
            phase = me.needsOnboarding ? .onboarding : .ready
        }
    }

    func dataDidChange() {
        dataRevision += 1
    }

    // MARK: - Authentication

    func signIn(email: String, password: String) async throws {
        let session = try await api.send(
            .json(.post, "v1/auth/login", ["email": email, "password": password], auth: false),
            as: Session.self)
        await startSession(session)
    }

    func signUp(email: String, password: String) async throws {
        let response = try await api.send(
            .json(.post, "v1/auth/signup", ["email": email, "password": password], auth: false),
            as: SignupResponse.self)
        recoveryKeyToShow = response.recoveryKey
        if let session = response.session {
            await startSession(session)
        } else {
            try await signIn(email: email, password: password)
        }
    }

    func recover(email: String, recoveryKey: String, newPassword: String) async throws {
        let response = try await api.send(
            .json(.post, "v1/auth/recover",
                  ["email": email, "recovery_key": recoveryKey, "new_password": newPassword], auth: false),
            as: SignupResponse.self)
        recoveryKeyToShow = response.recoveryKey
        if let session = response.session {
            await startSession(session)
        } else {
            try await signIn(email: email, password: newPassword)
        }
    }

    private func startSession(_ session: Session) async {
        sessionStore.save(session)
        signOutNotice = nil
        activateStorage(for: session.user.id)
        await refreshMe()
    }

    private func activateStorage(for userId: UUID) {
        cache.activate(userId: userId)
        outbox.activate(userId: userId)
    }

    func signOut(everywhere: Bool = false) async {
        if sessionStore.session != nil {
            try? await api.sendVoid(.json(.post, "v1/auth/logout", ["scope": everywhere ? "global" : "local"]))
        }
        resetLocalState()
    }

    /// Called after account deletion or when the session cannot be refreshed.
    func resetLocalState(notice: String? = nil) {
        sessionStore.clear()
        cache.purgeAll()
        outbox.purge()
        me = nil
        actionCount = 0
        selectedTab = .padelID
        signOutNotice = notice
        withAnimation(.smooth) { phase = .signedOut }
        Task { await NotificationService.shared.clearBadge() }
    }

    private func handleSessionInvalidated() {
        guard phase != .signedOut else { return }
        resetLocalState(notice: "Сессия истекла. Войдите снова.")
    }

    // MARK: - Offline outbox

    func flushOutbox() async {
        guard sessionStore.session != nil, !outbox.operations.isEmpty else { return }
        await outbox.process(with: api)
    }
}

enum CacheKey {
    static let me = "me"
    static let home = "home"
    static let openMatches = "matches.open"
    static let history = "matches.history"
    static let recentPlayers = "players.recent"
    static let cities = "cities"
    static func match(_ id: UUID) -> String { "match.\(id.uuidString.lowercased())" }
    static func player(_ id: UUID) -> String { "player.\(id.uuidString.lowercased())" }
    static func ratingHistory(_ id: UUID, days: Int?) -> String { "rating.\(id.uuidString.lowercased()).\(days ?? 0)" }
    static func dna(_ id: UUID) -> String { "dna.\(id.uuidString.lowercased())" }
    static func clubs(_ city: Int) -> String { "clubs.\(city)" }
}
