import Foundation
import Testing
@testable import PadelID

@Suite("Club metadata, maps and official booking")
struct ClubDetailsTests {
    @Test func legacyPublicationDecodesWithoutInventedClubAttribution() throws {
        let post = try JSONCoding.decoder.decode(CommunityPost.self, from: Data(publication.utf8))
        #expect(post.clubId == nil)
        #expect(post.club == nil)
        #expect(post.author.displayName == "Автор")
    }

    @Test func clubNewsUsesCanonicalCatalogAttributionAndKeepsActualAuthor() throws {
        let linked = String(publication.dropLast()) + #", "club_id":7,"club":{"id":7,"name":"Настоящее имя клуба"}}"#
        let post = try JSONCoding.decoder.decode(CommunityPost.self, from: Data(linked.utf8))
        #expect(post.clubId == 7)
        #expect(post.club == NamedRef(id: 7, name: "Настоящее имя клуба"))
        #expect(post.author.displayName == "Автор")
    }

    @Test func legacyDirectoryStillDecodesWithoutInventedMetadata() throws {
        let value = try decode(#"{"id":7,"name":"Старый клуб","city_id":1,"players_count":12}"#)
        #expect(value.club == Club(id: 7, name: "Старый клуб", cityId: 1, playersCount: 12))
        #expect(value.coordinates == nil)
        #expect(value.photos.isEmpty)
        #expect(value.officialBookingURL == nil)
        #expect(value.viewer == nil)
    }

    @Test func halfMissingAndInvalidCoordinatesNeverBecomeMapPins() throws {
        for fields in [#""latitude":55.7"#, #""latitude":91,"longitude":37.6"#,
                       #""latitude":55.7,"longitude":181"#, #""latitude":null,"longitude":37.6"#] {
            #expect(try decode(base + "," + fields + "}").coordinates == nil)
        }
        let valid = try decode(base + #","latitude":0,"longitude":0}"#)
        #expect(valid.coordinates == ClubCoordinates(latitude: 0, longitude: 0))
    }

    @Test func bookingNeedsVerifiedTimestampAndPublicHTTPS() throws {
        let unverified = try decode(base + #","booking_url":"https://courts.club.ru/book"}"#)
        #expect(unverified.officialBookingURL == nil)
        let verified = try decode(base + #","booking_url":"https://courts.club.ru/book","booking_verified_at":"2026-10-11T15:00:00Z"}"#)
        #expect(verified.officialBookingURL?.host == "courts.club.ru")
        let bad = try decode(base + #","booking_url":"https://127.0.0.1/","booking_verified_at":"2026-10-11T15:00:00Z"}"#)
        #expect(bad.officialBookingURL == nil)
    }

    @Test func externalLinksDoNotOpenCredentialURLsLocalHostsOrCleartext() {
        for raw in ["http://club.ru/", "https://user:password@club.ru/", "https://club.local/", "https://127.0.0.1/",
                    "https://[::1]/", "https://club.ru:443/", "https://club.test/", "file:///tmp/photo", "https://club.ru/a b"] {
            #expect(ClubExternalURL.publicHTTPS(raw) == nil)
        }
        #expect(ClubExternalURL.publicHTTPS("https://images.club.ru/photo.jpg") != nil)
    }

    @Test func removingMetadataEncodesExplicitNullAndKeepsExpectedVersion() throws {
        let value = try decode(base + #","metadata_version":7,"address":"Москва","latitude":55,"longitude":37,"website_url":"https://club.ru/","booking_url":"https://club.ru/book","booking_verified_at":"2026-10-11T15:00:00Z"}"#)
        var draft = ClubMetadataDraft(club: value)
        draft.address = ""; draft.latitude = ""; draft.longitude = ""; draft.website = ""; draft.booking = ""
        draft.reason = "Проверены сведения клуба"
        #expect(draft.validationMessage == nil)
        let data = try JSONCoding.encoder.encode(draft.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["version"] as? Int == 7)
        for key in ["address", "latitude", "longitude", "website_url", "booking_url", "contact_phone"] {
            #expect(body[key] is NSNull)
        }
        #expect(body["booking_verified"] as? Bool == false)
    }

    @Test func administratorCannotSaveHalfCoordinatesOrUnverifiedBooking() throws {
        var draft = ClubMetadataDraft(club: try decode(base + #","metadata_version":1}"#))
        draft.reason = "Проверено клубом"
        #expect(draft.validationMessage == nil)
        draft.latitude = "55,75"
        #expect(draft.validationMessage != nil)
        draft.longitude = "37,6"
        #expect(draft.validationMessage == nil)
        #expect(draft.body.latitude == 55.75)
        draft.booking = "https://club.ru/book"
        #expect(draft.validationMessage != nil)
        draft.bookingVerified = true
        #expect(draft.validationMessage == nil)
    }

    @Test func inactiveCourtAndVersionDecodeForAdministrativeReactivation() throws {
        let value = try decode(base + #","viewer":{"can_edit":true},"courts":[{"id":"11111111-1111-1111-1111-111111111111","club_id":7,"name":"Корт 1","indoor":true,"surface":"Искусственная трава","description":"","is_active":false,"version":3,"updated_at":"2026-10-11T15:00:00Z"}]}"#)
        #expect(value.viewer?.canEdit == true)
        #expect(value.courts?.first?.version == 3)
        #expect(value.courts?.first?.isActive == false)
    }

    @MainActor
    @Test func deletedClubClearsPreviouslyVisibleMetadataAndAdministrativeRights() async throws {
        let url = StubURLProtocol.makeBaseURL()
        defer { StubURLProtocol.unregister(url) }
        let client = APIClient(baseURL: url, sessionStore: SessionStore(), urlSession: StubURLProtocol.makeURLSession())
        let app = AppModel(api: client)
        let resource = Resource<ClubCatalogEntry>(cacheKey: nil) { Endpoint(method: .get, path: "v1/clubs/7", requiresAuth: false) }
        StubURLProtocol.register(url) { _ in .json(200, self.base + #","viewer":{"can_edit":true},"description":"Реальные сведения"}"#) }
        await resource.load(using: app)
        #expect(resource.value?.viewer?.canEdit == true)
        StubURLProtocol.register(url) { _ in .error(404, code: "club_not_found", message: "Клуб не найден") }
        await resource.load(using: app)
        #expect(resource.value == nil)
        #expect(!resource.isStale)
        #expect(resource.error?.code == "club_not_found")
    }

    @MainActor
    @Test func revokedAdministratorRoleReplacesEditingPermissionWithCurrentServerValue() async throws {
        let url = StubURLProtocol.makeBaseURL()
        defer { StubURLProtocol.unregister(url) }
        let client = APIClient(baseURL: url, sessionStore: SessionStore(), urlSession: StubURLProtocol.makeURLSession())
        let app = AppModel(api: client)
        let resource = Resource<ClubCatalogEntry>(cacheKey: nil) { Endpoint(method: .get, path: "v1/clubs/7", requiresAuth: false) }
        StubURLProtocol.register(url) { _ in .json(200, self.base + #","viewer":{"can_edit":true}}"#) }
        await resource.load(using: app)
        #expect(resource.value?.viewer?.canEdit == true)
        StubURLProtocol.register(url) { _ in .json(200, self.base + #","viewer":{"can_edit":false}}"#) }
        await resource.load(using: app)
        #expect(resource.value?.viewer?.canEdit == false)
        #expect(!resource.isStale)
    }

    private var base: String { #"{"id":7,"name":"Клуб","city_id":1,"players_count":12"# }
    private var publication: String {
        #"{"id":"11111111-1111-1111-1111-111111111111","author":{"id":"22222222-2222-2222-2222-222222222222","display_name":"Автор","deleted":false,"is_coach":false},"body":"Клубная публикация","visibility":"public","created_at":"2026-10-12T07:30:00Z","reaction_count":0,"comment_count":0}"#
    }
    private func decode(_ raw: String) throws -> ClubCatalogEntry {
        try JSONCoding.decoder.decode(ClubCatalogEntry.self, from: Data(raw.utf8))
    }
}
