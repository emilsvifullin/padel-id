import Foundation
import Testing
@testable import PadelID

@MainActor
@Suite("Remote push registration", .serialized, .timeLimit(.minutes(1)))
struct RemotePushTests {
    private func harness() -> (APIClient, SessionStore, URL, UserDefaults, String) {
        let base = StubURLProtocol.makeBaseURL()
        let store = SessionStore()
        store.save(Session(accessToken: "push-test-access-token-0123456789", refreshToken: "push-test-refresh", expiresIn: 3600,
                           expiresAt: Int(Date.now.timeIntervalSince1970 + 3600), user: AuthUser(id: UUID(), email: "push@example.com")))
        let api = APIClient(baseURL: base, sessionStore: store, urlSession: StubURLProtocol.makeURLSession())
        let name = "push.tests.\(UUID())"
        return (api, store, base, UserDefaults(suiteName: name)!, name)
    }

    private func finish(_ store: SessionStore, _ base: URL, _ defaults: UserDefaults, _ name: String) {
        store.clear(); StubURLProtocol.unregister(base); defaults.removePersistentDomain(forName: name)
    }

    private nonisolated static func registration(_ request: StubRecordedRequest) -> StubResponse {
        .json(200, "{\"installation_id\":\"\(request.request.url!.lastPathComponent)\",\"enabled\":true,\"environment\":\"production\",\"topic\":\"app.padelid.ios\"}")
    }

    @Test("Unprovisioned builds never register tokens or call the device API")
    func disabledBuild() async {
        let (api, store, base, defaults, name) = harness()
        defer { finish(store, base, defaults, name) }
        let calls = StubCounter()
        StubURLProtocol.register(base) { _ in calls.increment(); return .json(200, "{}") }
        let push = RemotePushService(api: api, defaults: defaults, supported: false, enabled: { true },
                                     authorizationAllowed: { true }, registerWithAPNs: { calls.increment() }, unregisterFromAPNs: { calls.increment() })
        await push.sessionStarted(); await push.receivedDeviceToken(Data([1, 2]))
        #expect(push.state == .unavailable && calls.value == 0)
    }

    @Test("Registration uses an authenticated stable installation and opaque variable-length token")
    func actualContract() async throws {
        let (api, store, base, defaults, name) = harness()
        defer { finish(store, base, defaults, name) }
        StubURLProtocol.register(base) { Self.registration($0) }
        let push = RemotePushService(api: api, defaults: defaults, supported: true, enabled: { true }, authorizationAllowed: { true }, registerWithAPNs: {}, unregisterFromAPNs: {})
        await push.receivedDeviceToken(Data([0, 0xff, 0x12]))
        #expect(push.state == .registered)
        let first = try #require(StubURLProtocol.requests(base).first)
        #expect(first.method == "PUT" && first.path.hasPrefix("/v1/me/push-devices/"))
        #expect(first.header("Authorization") == "Bearer push-test-access-token-0123456789")
        let body = try #require(first.body).jsonObject
        #expect(body?["device_token"] as? String == "00ff12")
        #expect(body?["enabled"] as? Bool == true)
        #expect(body?.count == 2)
        let again = RemotePushService(api: api, defaults: defaults, supported: true, enabled: { true }, authorizationAllowed: { true }, registerWithAPNs: {}, unregisterFromAPNs: {})
        await again.receivedDeviceToken(Data([0x01]))
        #expect(StubURLProtocol.requests(base).last?.path == first.path)
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("push.") }.count == 1)
    }

    @Test("Lost registration response stays pending and is not replayed automatically")
    func lostResponse() async {
        let (api, store, base, defaults, name) = harness()
        defer { finish(store, base, defaults, name) }
        let count = StubCounter()
        StubURLProtocol.register(base) { request in
            count.next() == 1 ? .transportFailure(.networkConnectionLost) : Self.registration(request)
        }
        let push = RemotePushService(api: api, defaults: defaults, supported: true, enabled: { true }, authorizationAllowed: { true }, registerWithAPNs: {}, unregisterFromAPNs: {})
        await push.receivedDeviceToken(Data([1]))
        #expect(push.state == .pending && count.value == 1)
        await push.synchronize()
        #expect(push.state == .registered && count.value == 2)
        #expect(Set(StubURLProtocol.requests(base).map(\.path)).count == 1)
    }

    @Test("New token waits for an old registration so late writes cannot restore an old token")
    func tokenOrdering() async throws {
        let (api, store, base, defaults, name) = harness()
        defer { finish(store, base, defaults, name) }
        let entered = StubCounter()
        StubURLProtocol.register(base) { request in
            if entered.next() == 1 { Thread.sleep(forTimeInterval: 0.2) }
            return Self.registration(request)
        }
        let push = RemotePushService(api: api, defaults: defaults, supported: true, enabled: { true }, authorizationAllowed: { true }, registerWithAPNs: {}, unregisterFromAPNs: {})
        let first = Task { await push.receivedDeviceToken(Data([1])) }
        while entered.value == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let second = Task { await push.receivedDeviceToken(Data([2])) }
        await first.value; await second.value
        #expect(StubURLProtocol.requests(base).map { $0.jsonBody()["device_token"] } == ["01", "02"])
        #expect(push.state == .registered)
    }

    @Test("Sign-out during registration discards success and sends no anonymous revocation")
    func logoutWhileRegistering() async throws {
        let (api, store, base, defaults, name) = harness()
        defer { finish(store, base, defaults, name) }
        let entered = StubCounter()
        StubURLProtocol.register(base) { request in entered.increment(); Thread.sleep(forTimeInterval: 0.2); return Self.registration(request) }
        let push = RemotePushService(api: api, defaults: defaults, supported: true, enabled: { true }, authorizationAllowed: { true }, registerWithAPNs: {}, unregisterFromAPNs: {})
        let work = Task { await push.receivedDeviceToken(Data([1])) }
        while entered.value == 0 { try await Task.sleep(for: .milliseconds(5)) }
        store.clear(); push.reset()
        await work.value
        #expect(push.state != .registered && entered.value == 1)
    }

    @Test("Revocation unregisters from APNs and removes this installation before sign-out")
    func revoke() async {
        let (api, store, base, defaults, name) = harness()
        defer { finish(store, base, defaults, name) }
        let unregister = StubCounter()
        StubURLProtocol.register(base) { request in request.method == "DELETE" ? .json(200, "{\"ok\":true}") : Self.registration(request) }
        let push = RemotePushService(api: api, defaults: defaults, supported: true, enabled: { true }, authorizationAllowed: { true }, registerWithAPNs: {}, unregisterFromAPNs: { unregister.increment() })
        await push.receivedDeviceToken(Data([1])); await push.revokeCurrentDevice()
        #expect(push.state == .disabled && unregister.value > 0)
        #expect(StubURLProtocol.requests(base).map(\.method) == ["PUT", "DELETE"])
    }

    @Test("Notification payload IDs open authenticated views and never arbitrary URLs")
    func destinations() {
        let id = UUID()
        #expect(NotificationDestination.parse(["notification_id": id.uuidString, "url": "https://untrusted.example"]) == .inbox)
        #expect(NotificationDestination.parse(["matchId": id.uuidString]) == .match(id))
        #expect(NotificationDestination.parse(["notification_id": "invalid", "url": "https://example.com"]) == nil)
        #expect(NotificationDestination.parse(["resourceId": id.uuidString]) == nil)
    }

    @Test("Disabling during a slow registration stops OS delivery immediately and revokes the late registration")
    func disableDuringRegistration() async throws {
        let (api, store, base, defaults, name) = harness()
        defer { finish(store, base, defaults, name) }
        var enabled = true
        let entered = StubCounter(), unregistered = StubCounter()
        StubURLProtocol.register(base) { request in
            if request.method == "DELETE" { return .json(200, "{\"ok\":true}") }
            entered.increment(); Thread.sleep(forTimeInterval: 0.2)
            return Self.registration(request)
        }
        let push = RemotePushService(api: api, defaults: defaults, supported: true, enabled: { enabled }, authorizationAllowed: { true }, registerWithAPNs: {}, unregisterFromAPNs: { unregistered.increment() })
        let work = Task { await push.receivedDeviceToken(Data([1])) }
        while entered.value == 0 { try await Task.sleep(for: .milliseconds(5)) }
        enabled = false
        push.preferenceChanged()
        #expect(unregistered.value == 1 && push.state == .disabled)
        await work.value
        #expect(push.state == .disabled)
        #expect(StubURLProtocol.requests(base).map(\.method) == ["PUT", "DELETE"])
    }
}

private nonisolated extension Data {
    var jsonObject: [String: Any]? { try? JSONSerialization.jsonObject(with: self) as? [String: Any] }
}
