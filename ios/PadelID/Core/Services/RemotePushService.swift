import Foundation
import Observation
import UIKit
import UserNotifications

nonisolated enum NotificationDestination: Hashable, Identifiable, Sendable {
    case inbox
    case match(UUID)

    var id: String {
        switch self {
        case .inbox: "inbox"
        case .match(let id): "match-\(id)"
        }
    }

    static func parse(_ payload: [AnyHashable: Any]) -> Self? {
        // Remote payloads carry only an opaque inbox ID. Resource IDs and URLs
        // are never trusted as navigation instructions from a push.
        if let raw = payload["notification_id"] as? String, UUID(uuidString: raw) != nil { return .inbox }
        if let raw = payload["matchId"] as? String, let id = UUID(uuidString: raw) { return .match(id) }
        if let raw = payload["resourceId"] as? String, UUID(uuidString: raw) != nil,
           payload["kind"] is String { return .inbox }
        return nil
    }
}

/// Device tokens remain in memory and are requested from APNs on every launch.
/// A stable installation ID identifies revocation, never the account itself.
@Observable
final class RemotePushService {
    static let shared = RemotePushService()

    enum State: Equatable { case unavailable, disabled, waitingForToken, syncing, registered, pending }
    private(set) var state: State = .unavailable
    var destination: NotificationDestination?
    var usesRemoteDelivery: Bool { state == .registered }

    private let api: APIClient
    private let installationID: UUID
    private let supported: Bool
    private let enabled: () -> Bool
    private let authorizationAllowed: () async -> Bool
    private let registerWithAPNs: () -> Void
    private let unregisterFromAPNs: () -> Void
    private var deviceToken: String?
    private var suspended = false
    private var needsSync = false
    private var syncTask: Task<Void, Never>?

    init(api: APIClient = .shared, defaults: UserDefaults = .standard,
         supported: Bool = AppEnvironment.remotePushEnabled && !AppEnvironment.isUITesting,
         enabled: @escaping () -> Bool = { NotificationService.shared.isEnabled },
         authorizationAllowed: @escaping () async -> Bool = {
             let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
             return status == .authorized || status == .provisional
         },
         registerWithAPNs: @escaping () -> Void = { UIApplication.shared.registerForRemoteNotifications() },
         unregisterFromAPNs: @escaping () -> Void = { UIApplication.shared.unregisterForRemoteNotifications() }) {
        self.api = api
        self.supported = supported
        self.enabled = enabled
        self.authorizationAllowed = authorizationAllowed
        self.registerWithAPNs = registerWithAPNs
        self.unregisterFromAPNs = unregisterFromAPNs
        let key = "push.installationID.v1"
        if let raw = defaults.string(forKey: key), let id = UUID(uuidString: raw) {
            installationID = id
        } else {
            installationID = UUID()
            defaults.set(installationID.uuidString, forKey: key)
        }
    }

    func sessionStarted() async {
        suspended = false
        await synchronize()
    }

    func receivedDeviceToken(_ data: Data) async {
        guard !data.isEmpty, data.count <= 512 else { return }
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        await synchronize()
    }

    func registrationFailed() { state = supported ? .pending : .unavailable }

    func preferenceChanged() {
        if supported, !enabled() {
            // Do not wait for an in-flight server request to stop OS delivery.
            unregisterFromAPNs()
            state = .disabled
        }
        Task { await synchronize() }
    }

    /// Serialize mutations: a slow old token registration must finish before
    /// the latest token/preference is sent, otherwise it can overwrite it.
    func synchronize() async {
        guard supported else { state = .unavailable; return }
        needsSync = true
        if let syncTask { await syncTask.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.syncTask = nil }
            while self.needsSync {
                self.needsSync = false
                await self.syncOnce()
            }
        }
        syncTask = task
        await task.value
    }

    private func syncOnce() async {
        guard let userID = api.sessionStore.userId else {
            unregisterFromAPNs()
            state = .disabled
            return
        }
        let allowed = await authorizationAllowed()
        let wantsPush = enabled() && allowed && !suspended
        guard api.sessionStore.userId == userID else { needsSync = true; return }
        let path = "v1/me/push-devices/\(installationID.uuidString)"
        if !wantsPush {
            unregisterFromAPNs()
            do {
                try await api.sendVoid(.init(method: .delete, path: path))
                if api.sessionStore.userId == userID { state = .disabled }
            } catch {
                if api.sessionStore.userId == userID { state = .pending }
            }
            return
        }
        guard let token = deviceToken else {
            state = .waitingForToken
            registerWithAPNs()
            return
        }
        state = .syncing
        do {
            let result = try await api.send(.json(.put, path, Registration(deviceToken: token, enabled: true)), as: RegistrationResult.self)
            guard api.sessionStore.userId == userID, deviceToken == token, !suspended, enabled() else { needsSync = true; return }
            guard result.installationId == installationID, result.enabled,
                  ["production", "sandbox"].contains(result.environment), result.topic == "app.padelid.ios" else {
                state = .pending
                return
            }
            state = .registered
        } catch {
            if api.sessionStore.userId == userID { state = .pending }
        }
    }

    /// Called before local sign-out clears the authorization needed by DELETE.
    /// Failed revocation is retried on a future authorized synchronization;
    /// unregistering at the OS takes effect immediately on this device.
    func revokeCurrentDevice() async {
        suspended = true
        if supported { unregisterFromAPNs() }
        await synchronize()
    }

    func reset() {
        suspended = true
        deviceToken = nil
        destination = nil
        needsSync = true
        if supported { unregisterFromAPNs() }
        state = supported ? .disabled : .unavailable
    }

    nonisolated private struct Registration: Encodable {
        let deviceToken: String
        let enabled: Bool
    }
    nonisolated private struct RegistrationResult: Decodable {
        let installationId: UUID
        let enabled: Bool
        let environment: String
        let topic: String
    }
}
