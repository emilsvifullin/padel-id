import XCTest

@MainActor
final class ClubsUITests: PadelIDUITestCase {
    private let clubName = "Падел Арена Лужники"
    private var details: [String: Any] {
        ["id": 1, "name": clubName, "city_id": 1, "city_name": "Москва", "players_count": 5,
         "description": "Клуб для игроков города", "address": "Москва, Лужники",
         "latitude": NSNull(), "longitude": NSNull(), "photo_urls": [], "amenities": ["Раздевалки"],
         "contact_phone": "+7 495 123-45-67", "metadata_version": 2, "courts_count": 1,
         "courts": [["id": "11111111-1111-1111-1111-111111111111", "club_id": 1, "name": "Корт 1",
                     "indoor": true, "surface": "Искусственная трава", "description": "Крытый корт",
                     "is_active": true, "version": 1, "updated_at": "2026-10-11T15:00:00Z"]],
         "viewer": ["can_edit": false]]
    }

    func testClubMetadataAndEventPreserveNavigationWithoutInventedCoordinates() throws {
        var detail = details
        detail["booking_url"] = "https://club.ru/book"
        detail["booking_verified_at"] = "2026-10-11T15:00:00Z"
        let detailData = try JSONSerialization.data(withJSONObject: detail)
        let eventID = "f8e49ac8-4f8c-4d88-8b6e-cb7ff3198a30"
        let event: [String: Any] = ["id": eventID, "kind": "training", "format": "individual", "title": "Занятие в клубе",
            "description": "Работа у сетки", "organizer": ["id": StubServer.partnerID, "username": "d_sokolov", "display_name": "Дмитрий Соколов", "deleted": false, "is_coach": true],
            "starts_at": "2026-12-10T10:00:00Z", "duration_minutes": 60, "city": ["id": 1, "name": "Москва"],
            "club": ["id": 1, "name": clubName], "location": "Корт 1", "capacity": 1, "min_level": 0, "max_level": 7,
            "round_count": 0, "points_per_game": 21, "current_round": 0, "status": "open", "registered_count": 0,
            "viewer": ["is_organizer": false], "registrations": [], "games": [], "standings": []]
        let page = try JSONSerialization.data(withJSONObject: ["items": [event]])
        let eventData = try JSONSerialization.data(withJSONObject: event)
        try launch(.existingUser) { server in
            server.setOverride("GET", "v1/clubs/1", .json(detailData))
            server.setOverride("GET", "v1/clubs/1/events", .json(page))
            server.setOverride("GET", "v1/events/" + eventID, .json(eventData))
            server.setOverride("GET", "v1/events/" + UUID(uuidString: eventID)!.uuidString, .json(eventData))
        }
        signIn(); waitForHome(); selectTab("Клубы")
        open(row("clubs.row", containing: clubName, timeout: 15), screen: "Клуб")
        waitForRequest("GET", "v1/clubs/1")
        require(app.staticTexts["Клуб для игроков города"], "club description")
        XCTAssertFalse(element("club.map").exists, "Missing coordinates must not create a synthetic map")
        XCTAssertFalse(element("club.edit").exists, "Public viewer cannot edit metadata")
        scrollIntoView(element("club.booking"))
        require(element("club.booking"), "verified official booking link")
        open(element("club.events"), screen: clubName)
        let request = waitForRequest("GET", "v1/clubs/1/events")
        XCTAssertEqual(request?.query["scope"], "upcoming")
        open(element("club.event"), screen: "Тренировка")
        tap(require(app.navigationBars["Тренировка"].buttons.firstMatch, "back to club events"))
        requireScreen(clubName)
        tap(require(app.navigationBars[clubName].buttons.firstMatch, "back to club"))
        requireScreen("Клуб")
        scrollIntoView(element("club.details"), searchBelow: false)
        require(element("club.details"), "club navigation retained")
        snap("club-details")
    }

    func testUnverifiedBookingIsHiddenAndClubGameFilterIsSent() throws {
        var detail = details
        detail["booking_url"] = "https://club.ru/book"
        let data = try JSONSerialization.data(withJSONObject: detail)
        try launch(.existingUser) { $0.setOverride("GET", "v1/clubs/1", .json(data)) }
        signIn(); waitForHome(); selectTab("Клубы")
        open(row("clubs.row", containing: clubName, timeout: 15), screen: "Клуб")
        waitForRequest("GET", "v1/clubs/1")
        XCTAssertFalse(element("club.booking").exists, "Unverified URL is not a booking integration")
        XCTAssertTrue(waitUntil(timeout: 10) {
            server.recorded("GET", "v1/upcoming-matches").contains { $0.query["club_id"] == "1" }
        }, "Club games must request the server filter")
        open(element("club.game"), screen: "Открытая игра")
        tap(require(app.navigationBars["Открытая игра"].buttons.firstMatch, "back to club"))
        requireScreen("Клуб")
    }

    func testPublishedCoordinatesShowMapAndCatalogKeepsAccessibleList() throws {
        var detail = details
        detail["latitude"] = 55.715
        detail["longitude"] = 37.553
        let data = try JSONSerialization.data(withJSONObject: detail)
        let list = try JSONSerialization.data(withJSONObject: [detail])
        try launch(.existingUser) { server in
            server.setOverride("GET", "v1/clubs", .json(list))
            server.setOverride("GET", "v1/clubs/1", .json(data))
        }
        signIn(); waitForHome(); selectTab("Клубы")
        tap(app.switches["Клубы на карте"])
        // The list is the accessible alternative to spatial map controls.
        open(row("clubs.row", containing: clubName, timeout: 15), screen: "Клуб")
        waitForRequest("GET", "v1/clubs/1")
        scrollIntoView(element("club.map"))
        require(element("club.map"), "published map coordinates")
        scrollIntoView(button(label: "Открыть в Картах"))
        require(button(label: "Открыть в Картах"), "native map destination")
        snap("club-map")
    }

    func testMetadataConflictDoesNotDismissOrReportUnconfirmedSuccess() throws {
        var detail = details
        detail["viewer"] = ["can_edit": true]
        let data = try JSONSerialization.data(withJSONObject: detail)
        let bundle = Bundle(for: Self.self)
        let fixture = try XCTUnwrap(bundle.url(forResource: "me", withExtension: "json", subdirectory: "Fixtures")
                                   ?? bundle.url(forResource: "me", withExtension: "json"))
        var me = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        me["is_admin"] = true
        let meData = try JSONSerialization.data(withJSONObject: me)
        try launch(.existingUser) { server in
            server.setOverride("GET", "v1/me", .json(meData))
            server.setOverride("GET", "v1/clubs/1", .json(data))
            server.setOverride("PATCH", "v1/admin/clubs/1", .error(409, code: "version_conflict", message: "Данные изменились"))
        }
        signIn(); waitForHome(); selectTab("Клубы")
        open(row("clubs.row", containing: clubName, timeout: 15), screen: "Клуб")
        open(element("club.edit"), screen: "Информация о клубе")
        let reason = scrollIntoView(element("clubEditor.reason"))
        enter("Проверено по сведениям клуба", into: reason)
        tap(button(label: "Сохранить"))
        let request = waitForRequest("PATCH", "v1/admin/clubs/1")
        XCTAssertEqual(request?.jsonObject?["version"] as? Int, 2)
        XCTAssertTrue(request?.jsonObject?["latitude"] is NSNull)
        XCTAssertTrue(request?.jsonObject?["longitude"] is NSNull)
        requireScreen("Информация о клубе")
        scrollIntoView(button(label: "Загрузить текущую информацию"))
        require(button(label: "Загрузить текущую информацию"), "conflict requires canonical reload")
        XCTAssertFalse(button(label: "Сохранить").isEnabled)
        XCTAssertEqual(server.recorded("PATCH", "v1/admin/clubs/1").count, 1, "Versioned admin mutation is not automatically retried")
    }
}
