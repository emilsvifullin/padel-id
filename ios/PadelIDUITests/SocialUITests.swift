import XCTest

@MainActor
final class SocialUITests: PadelIDUITestCase {
    private var socialPlayer: [String: Any] {
        ["id": StubServer.partnerID, "username": "d_sokolov", "display_name": "Дмитрий Соколов", "deleted": false, "is_coach": false]
    }

    func testChatMemberProfilePreservesMembersAndConversation() throws {
        let chatID = "df0340e8-cf65-476c-83f0-6a7068cde8af"
        let path = "v1/conversations/" + chatID
        let conversation: [String: Any] = ["id": chatID, "kind": "direct", "title": "Чат с Дмитрием", "visibility": "private",
            "created_at": "2026-10-10T10:00:00Z", "updated_at": "2026-10-10T10:00:00Z",
            "members": [["player": socialPlayer, "role": "member"]], "unread_count": 0]
        let detail = try JSONSerialization.data(withJSONObject: conversation)
        let page = try JSONSerialization.data(withJSONObject: ["items": [conversation]])
        try launch(.existingUser) { server in
            server.setOverride("GET", "v1/conversations", .json(page))
            server.setOverride("GET", path, .json(detail))
            server.setOverride("GET", path + "/messages", .json(Data("{\"items\":[]}".utf8)))
            server.setOverride("POST", path + "/read", .noContent)
        }
        signIn(); waitForHome(); selectTab("Сообщество")
        open(element("community.chats"), screen: "Сообщения")
        open(button(labelPrefix: "Чат с Дмитрием"), screen: "Чат с Дмитрием")
        open(button(label: "Участники чата"), screen: "Участники")
        tap(button(labelPrefix: "Дмитрий Соколов"))
        require(element("profile.newMatch"), timeout: 15, "member profile")
        waitForRequest("GET", "v1/players/" + StubServer.partnerID)
        tap(require(app.navigationBars.firstMatch.buttons.firstMatch, "back from member profile"))
        requireScreen("Участники")
        tap(require(app.navigationBars["Участники"].buttons.firstMatch, "back to conversation"))
        requireScreen("Чат с Дмитрием")
        require(element("chat.draft"), "conversation stays usable")
    }

    func testFollowProfilePreservesPrivacyNavigation() throws {
        let page = try JSONSerialization.data(withJSONObject: ["items": [socialPlayer]])
        try launch(.existingUser) { server in
            server.setOverride("GET", "v1/social/settings", .json(Data("{\"messages_from\":\"friends\",\"notify_messages\":true,\"notify_activity\":true}".utf8)))
            server.setOverride("GET", "v1/social/follows", .json(page))
        }
        signIn(); waitForHome(); selectTab("Профиль")
        open(element("account.privacy"), screen: "Приватность")
        open(button(label: "Мои подписки"), screen: "Подписки")
        tap(button(labelPrefix: "Дмитрий Соколов"))
        require(element("profile.newMatch"), timeout: 15, "followed player profile")
        waitForRequest("GET", "v1/players/" + StubServer.partnerID)
        tap(require(app.navigationBars.firstMatch.buttons.firstMatch, "back to follows"))
        requireScreen("Подписки")
        tap(require(app.navigationBars["Подписки"].buttons.firstMatch, "back to privacy"))
        requireScreen("Приватность")
    }

    func testClubGamePreservesClubNavigation() throws {
        let detail: [String: Any] = ["id": 1, "name": "Падел Арена Лужники", "city_id": 1, "players_count": 5,
            "description": "Реальные сведения", "address": "Москва", "photo_urls": [], "amenities": [],
            "metadata_version": 1, "courts": [], "viewer": ["can_edit": false]]
        let data = try JSONSerialization.data(withJSONObject: detail)
        try launch(.existingUser) { $0.setOverride("GET", "v1/clubs/1", .json(data)) }
        signIn(); waitForHome(); selectTab("Клубы")
        let club = row("clubs.row", containing: "Падел Арена Лужники", timeout: 15)
        open(club, screen: "Клуб")
        open(element("club.game"), screen: "Открытая игра")
        waitForRequest("GET", "v1/upcoming-matches/0b997649-0569-46fc-9111-972f456e861a")
        tap(require(app.navigationBars["Открытая игра"].buttons.firstMatch, "back to club"))
        requireScreen("Клуб")
        scrollIntoView(element("club.details"), searchBelow: false)
        require(element("club.details"), "club details retained")
    }

    func testEventOrganizerProfilePreservesEventNavigation() throws {
        let eventID = "f8e49ac8-4f8c-4d88-8b6e-cb7ff3198a30"
        let event: [String: Any] = ["id": eventID, "kind": "training", "format": "individual", "title": "Тренировка с Дмитрием",
            "description": "Работа у сетки", "organizer": socialPlayer, "starts_at": "2026-12-10T10:00:00Z", "duration_minutes": 60,
            "city": ["id": 1, "name": "Москва"], "location": "Корт 2", "capacity": 1, "min_level": 0, "max_level": 7,
            "round_count": 0, "points_per_game": 21, "current_round": 0, "status": "open", "registered_count": 0,
            "viewer": ["is_organizer": false], "registrations": [], "games": [], "standings": []]
        let detail = try JSONSerialization.data(withJSONObject: event)
        let page = try JSONSerialization.data(withJSONObject: ["items": [event]])
        try launch(.existingUser) { server in
            server.setOverride("GET", "v1/events", .json(page))
            server.setOverride("GET", "v1/events/" + eventID, .json(detail))
            server.setOverride("GET", "v1/events/" + UUID(uuidString: eventID)!.uuidString, .json(detail))
        }
        signIn(); waitForHome(); selectTab("Матчи")
        open(element("matches.events"), screen: "Тренировки и турниры")
        open(button(labelPrefix: "Тренировка с Дмитрием"), screen: "Тренировка")
        tap(button(labelPrefix: "Дмитрий Соколов"))
        require(element("profile.newMatch"), timeout: 15, "organizer profile")
        waitForRequest("GET", "v1/players/" + StubServer.partnerID)
        tap(require(app.navigationBars.firstMatch.buttons.firstMatch, "back to event"))
        requireScreen("Тренировка")
        tap(require(app.navigationBars["Тренировка"].buttons.firstMatch, "back to event catalog"))
        requireScreen("Тренировки и турниры")
    }

    func testDirectChatPreservesSourceAndMemberProfileNavigation() throws {
        try verifyProgrammaticChatNavigation(game: false)
    }

    func testGameChatPreservesSourceAndMemberProfileNavigation() throws {
        try verifyProgrammaticChatNavigation(game: true)
    }

    private func verifyProgrammaticChatNavigation(game: Bool) throws {
        let chatID = "df0340e8-cf65-476c-83f0-6a7068cde8af"
        let path = "v1/conversations/" + chatID
        let conversation: [String: Any] = ["id": chatID, "kind": game ? "game" : "direct", "title": "Проверяемый чат", "visibility": "private",
            "created_at": "2026-10-10T10:00:00Z", "updated_at": "2026-10-10T10:00:00Z",
            "members": [["player": socialPlayer, "role": "member"]], "unread_count": 0]
        let detail = try JSONSerialization.data(withJSONObject: conversation)
        try launch(.existingUser) { server in
            server.setOverride("POST", "v1/conversations", .json(detail, status: 201))
            server.setOverride("GET", path, .json(detail))
            server.setOverride("GET", path + "/messages", .json(Data("{\"items\":[]}".utf8)))
            server.setOverride("POST", path + "/read", .noContent)
        }
        signIn(); waitForHome()
        if game {
            open(element("home.upcoming"), screen: "Открытая игра")
            open(button(label: "Чат участников"), screen: "Проверяемый чат")
        } else {
            openFriends(); open(element("friends.search"), screen: "Найти игроков")
            tap(row("playerRow", containing: "Соколов", timeout: 15))
            require(element("profile.newMatch"), "source profile")
            open(element("profile.message"), screen: "Проверяемый чат")
        }
        let creation = try XCTUnwrap(waitForRequest("POST", "v1/conversations"))
        XCTAssertEqual(creation.jsonObject?["kind"] as? String, game ? "game" : "direct")
        XCTAssertNotNil(creation.header("Idempotency-Key"))
        open(button(label: "Участники чата"), screen: "Участники")
        tap(button(labelPrefix: "Дмитрий Соколов"))
        require(element("profile.newMatch"), "chat member profile")
        tap(require(app.navigationBars.firstMatch.buttons.firstMatch, "back to members"))
        requireScreen("Участники")
        tap(require(app.navigationBars["Участники"].buttons.firstMatch, "back to created chat"))
        requireScreen("Проверяемый чат")
        tap(require(app.navigationBars["Проверяемый чат"].buttons.firstMatch, "back to chat source"))
        if game { requireScreen("Открытая игра") }
        else { require(element("profile.newMatch"), "source profile remains on path") }
    }

    func testPersistentTabsFriendRequestsAndSearch() throws {
        try launch(.existingUser)
        signIn()
        waitForHome()
        for title in ["Главная", "Матчи", "Клубы", "Сообщество", "Профиль"] {
            XCTAssertTrue(app.tabBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch.exists)
        }
        openFriends()
        waitForRequest("GET", "v1/friends")
        require(element("friends.row"), "friend row")
        snap("friends-requests")
        let accept = button(label: "Принять")
        scrollIntoView(accept)
        tap(accept)
        waitForRequest("POST", "v1/friends/72b11bd9-f270-4ae2-b104-25a132d48204/respond")
        let sent = try XCTUnwrap(server.recorded("POST", "v1/friends/72b11bd9-f270-4ae2-b104-25a132d48204/respond").last)
        XCTAssertEqual(sent.jsonObject?["decision"] as? String, "accepted")
        // Accepting a request can move the current lazy-list position below
        // the search row, which must be brought back from above.
        let search = element("friends.search")
        scrollIntoView(search, searchBelow: false)
        open(search, screen: "Найти игроков")
        require(element("playerRow"), "player search preserved")
        selectTab("Матчи")
        requireScreen("Матчи")
        selectTab("Сообщество")
        requireScreen("Найти игроков")
        // A child destination must keep Friends in the navigation path.
        // Mixing view and value links used to leave this screen unreachable.
        tap(require(app.navigationBars["Найти игроков"].buttons.firstMatch, "back to friends"))
        requireScreen("Друзья")
        require(element("friends.search"), "friend search remains available after returning")
    }

    func testUpcomingCancellationSendsCancelAndNeverLeave() throws {
        try launch(.existingUser)
        signIn()
        waitForHome()
        open(element("home.upcoming"), screen: "Открытая игра")
        snap("upcoming-detail")
        let cancel = button(label: "Отменить игру")
        scrollIntoView(cancel)
        tap(cancel)
        let alert = require(app.alerts.firstMatch, "game cancellation alert")
        snap("upcoming-cancel-confirmation")
        alert.buttons["Отменить игру"].tap()
        let path = "v1/upcoming-matches/0b997649-0569-46fc-9111-972f456e861a"
        waitForRequest("POST", path + "/cancel")
        XCTAssertTrue(server.recorded("POST", path + "/leave").isEmpty)
    }

    func testGamePublicationPreservesProfileClubAndIdempotency() throws {
        try launch(.existingUser) { server in
            server.setOverride("POST", "v1/upcoming-matches", .serviceUnavailable)
        }
        signIn()
        waitForHome()
        selectTab("Матчи")
        open(element("matches.upcoming"), screen: "Предстоящие игры")
        tap(require(element("upcoming.create"), "create game"))
        requireScreen("Новая игра")
        let place = require(element("upcoming.location"), "meeting place")
        scrollIntoView(place)
        place.tap()
        place.typeText("Корт 2, вход у рецепции")
        dismissKeyboard()
        snap("upcoming-publication")
        tap(require(element("upcoming.publish"), "publish"))
        waitForRequest("POST", "v1/upcoming-matches")
        let retry = require(button(label: "Повторить"), timeout: 30, "retry the same publication")
        XCTAssertFalse(element("upcoming.location").isEnabled, "An uncertain response must retain the originally submitted parameters")
        server.removeOverride("POST", "v1/upcoming-matches")
        tap(retry)
        XCTAssertTrue(waitUntil(timeout: 15) { !app.navigationBars["Новая игра"].exists })
        let requests = server.recorded("POST", "v1/upcoming-matches")
        XCTAssertGreaterThan(requests.count, 1)
        XCTAssertEqual(Set(requests.compactMap { $0.header("Idempotency-Key") }).count, 1)
        XCTAssertTrue(requests.allSatisfy { $0.jsonObject?["location"] as? String == "Корт 2, вход у рецепции" })
        let sent = try XCTUnwrap(server.recorded("POST", "v1/upcoming-matches").last)
        XCTAssertNotNil(sent.jsonObject?["club_id"], "The initial city must not clear the profile's club")
        let bodyKey = try XCTUnwrap(sent.jsonObject?["client_id"] as? String)
        XCTAssertEqual(bodyKey.lowercased(), sent.header("Idempotency-Key"))
        XCTAssertEqual(sent.jsonObject?["location"] as? String, "Корт 2, вход у рецепции")
        XCTAssertNil(sent.jsonObject?["sets"], "Scheduling must not invent a played score")
    }

    func testScheduledGameEntersResultWithAdmittedLineup() throws {
        try launch(.existingUser)
        signIn()
        waitForHome()
        selectTab("Матчи")
        open(element("matches.upcoming"), screen: "Предстоящие игры")
        tap(require(app.segmentedControls.buttons["Мои"], "my scheduled games"))
        let game = row("upcoming.row", containing: "Ожидает результата", timeout: 15)
        scrollIntoView(game)
        open(game, screen: "Открытая игра")
        scrollIntoView(element("upcoming.result"))
        tap(require(element("upcoming.result"), "enter scheduled result"))
        requireScreen("Результат")
        snap("scheduled-result-lineup")
        for number in [1, 2] {
            tap(element("editor.set.\(number)"))
            let score = require(element(number == 1 ? "score.6-4" : "score.6-3"), "set score")
            tap(score)
            waitForDisappearance(score, "score grid")
        }
        let submit = require(element("editor.submit"), "submit linked result")
        waitEnabled(submit, "linked result submit")
        tap(submit)
        let request = try XCTUnwrap(waitForRequest("POST", "v1/upcoming-matches/4a1fccad-7969-40d3-be76-443cfeb3e3c5/result"))
        let players = try XCTUnwrap(request.jsonObject?["players"] as? [[String: Any]])
        XCTAssertEqual(Set(players.compactMap { $0["player_id"] as? String }), Set([
            StubServer.currentUserID, StubServer.partnerID,
            "72b11bd9-f270-4ae2-b104-25a132d48204", "2becd560-4954-4ad9-ab50-e454ea8f2d73"
        ]))
        XCTAssertNotNil(request.header("Idempotency-Key"))
        XCTAssertTrue(server.recorded("POST", "v1/matches").isEmpty)
    }
    func testCoachProfileOpensRealScheduleAndEnrollment() throws {
        let eventID = "f8e49ac8-4f8c-4d88-8b6e-cb7ff3198a30"
        var coach = socialPlayer; coach["is_coach"] = true
        let profile: [String: Any] = ["deleted": false, "profile": coach,
            "coach": ["experience_years": 8, "certification": "Сертификат федерации",
                      "about": "Групповые занятия и техника у сетки", "club": ["id": 1, "name": "Клуб тренера"]]]
        let event: [String: Any] = ["id": eventID, "kind": "training", "format": "individual", "title": "Занятие у тренера",
            "description": "Работа у сетки", "organizer": coach, "starts_at": "2026-12-10T10:00:00Z", "duration_minutes": 60,
            "city": ["id": 1, "name": "Москва"], "location": "Корт 2", "capacity": 1, "min_level": 0, "max_level": 7,
            "round_count": 0, "points_per_game": 21, "current_round": 0, "status": "open", "registered_count": 0,
            "viewer": ["is_organizer": false], "registrations": [], "games": [], "standings": []]
        let profileData = try JSONSerialization.data(withJSONObject: profile)
        let page = try JSONSerialization.data(withJSONObject: ["items": [event]])
        let detail = try JSONSerialization.data(withJSONObject: event)
        var admitted = event
        admitted["registered_count"] = 1
        admitted["viewer"] = ["is_organizer": false, "registration": "accepted"]
        let admittedData = try JSONSerialization.data(withJSONObject: admitted)
        let paths = [eventID, UUID(uuidString: eventID)!.uuidString]
        try launch(.existingUser) { server in
            server.setOverride("GET", "v1/events", .json(page))
            for path in paths {
                server.setOverride("GET", "v1/events/" + path, .json(detail))
                server.setOverride("POST", "v1/events/" + path + "/register", .json(admittedData))
            }
            for id in [StubServer.partnerID, UUID(uuidString: StubServer.partnerID)!.uuidString] {
                server.setOverride("GET", "v1/players/" + id, .json(profileData))
            }
        }
        signIn(); waitForHome(); selectTab("Матчи")
        open(element("matches.events"), screen: "Тренировки и турниры")
        open(button(labelPrefix: "Занятие у тренера"), screen: "Тренировка")
        tap(button(labelPrefix: "Дмитрий Соколов"))
        require(element("player.coach"), timeout: 15, "approved professional profile")
        let schedule = button(label: "Расписание и запись")
        scrollIntoView(schedule)
        snap("coach-profile")
        open(schedule, screen: "Занятия тренера")
        XCTAssertTrue(waitUntil(timeout: 10) {
            server.recorded("GET", "v1/events").contains { $0.query["organizer_id"] == StubServer.partnerID && $0.query["kind"] == "training" }
        }, "Schedule must request the actual organizer filter")
        XCTAssertFalse(element("events.kind").exists)
        open(button(labelPrefix: "Занятие у тренера"), screen: "Тренировка")
        tap(button(label: "Записаться"))
        for path in paths { server.setOverride("GET", "v1/events/" + path, .json(admittedData)) }
        require(button(label: "Отменить запись"), timeout: 30, "server-confirmed training enrollment")
        XCTAssertTrue(waitUntil(timeout: 10) { paths.contains { !server.recorded("POST", "v1/events/" + $0 + "/register").isEmpty } })
        snap("coach-schedule-enrollment")
    }

    func testEventEditConflictReloadsConditionsAndPreservesIdentity() throws {
        let id = "883c2d69-b1b2-44c2-9838-38169a20ed66"
        var owner = socialPlayer; owner["id"] = StubServer.currentUserID
        let event: [String: Any] = ["id": id, "kind": "tournament", "format": "americano", "title": "Перенос турнира",
            "description": "Исходные условия", "organizer": owner,
            "starts_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400)), "duration_minutes": 60,
            "city": ["id": 1, "name": "Москва"], "location": "Корт 2", "capacity": 4, "min_level": 0, "max_level": 7,
            "round_count": 3, "points_per_game": 32, "metadata_version": 1, "current_round": 0,
            "status": "open", "registered_count": 1, "viewer": ["is_organizer": true],
            "registrations": [["player": socialPlayer, "team_id": StubServer.partnerID, "status": "accepted"]], "games": [], "standings": []]
        var fresh = event; fresh["metadata_version"] = 2; fresh["title"] = "Актуальный турнир"; fresh["location"] = "Корт 3"
        let originalData = try JSONSerialization.data(withJSONObject: event)
        let freshData = try JSONSerialization.data(withJSONObject: fresh)
        let page = try JSONSerialization.data(withJSONObject: ["items": [event]])
        let conflict = try JSONSerialization.data(withJSONObject: ["error": ["code": "event_version_conflict", "message": "Условия уже изменились"]])
        let paths = [id, UUID(uuidString: id)!.uuidString]
        try launch(.existingUser) { server in
            server.setOverride("GET", "v1/events", .json(page))
            for path in paths {
                server.setOverride("GET", "v1/events/" + path, .json(originalData))
                server.setOverride("PUT", "v1/events/" + path, .json(conflict, status: 409))
            }
        }
        signIn(); waitForHome(); selectTab("Матчи")
        open(element("matches.events"), screen: "Тренировки и турниры")
        tap(require(app.segmentedControls.buttons["Турниры"], "tournament kind"))
        open(button(labelPrefix: "Перенос турнира"), screen: "Турнир")
        scrollIntoView(button(label: "Изменить время и условия"))
        open(button(label: "Изменить время и условия"), screen: "Событие")
        func editEventTitle(_ text: String) -> String {
            // Removing the review section can leave the form below this lazy row.
            scrollIntoView(element("eventEdit.title"), searchBelow: false)
            let field = require(app.textFields["eventEdit.title"])
            tap(field)
            field.typeText(text)
            // Simulator input can finish after XCTest's idle notification.
            // Observe the actual edit once, without typing a duplicate suffix.
            XCTAssertTrue(waitUntil(timeout: 15) {
                (field.value as? String)?.contains(text) == true
            }, "The visible draft must contain the user's correction")
            let value = field.value as? String ?? ""
            XCTAssertTrue(value.contains(text), "The visible draft must contain the user's correction")
            dismissKeyboard()
            return value
        }
        let initialDraft = editEventTitle(" первый перенос")
        for path in paths { server.setOverride("GET", "v1/events/" + path, .json(freshData)) }
        tap(require(app.buttons["eventEdit.save"]))
        require(app.staticTexts["Условия изменились. Черновик сохранён; проверьте актуальные условия перед сохранением."], timeout: 20)
        scrollIntoView(element("eventEdit.title"), hittable: false)
        XCTAssertEqual(element("eventEdit.title").value as? String, initialDraft)
        // iOS 26 also exposes the toolbar container with this identifier.
        // Its enabled state does not represent the actual button's state.
        XCTAssertFalse(require(app.buttons["eventEdit.save"]).isEnabled, "Review is required before a rebased submission")
        XCTAssertEqual(paths.flatMap { server.recorded("PUT", "v1/events/" + $0) }.count, 1)
        let keepDraft = scrollIntoView(element("eventEdit.keepDraft"), searchBelow: false)
        snap("event-edit-conflict-review")
        tap(keepDraft)
        let correctedTitle = editEventTitle(" согласовано")
        var saved = fresh; saved["title"] = correctedTitle; saved["metadata_version"] = 3
        let savedData = try JSONSerialization.data(withJSONObject: saved)
        for path in paths {
            server.setOverride("PUT", "v1/events/" + path, .json(savedData))
            server.setOverride("GET", "v1/events/" + path, .json(savedData))
        }
        let save = require(app.buttons["eventEdit.save"]); waitEnabled(save); tap(save)
        XCTAssertTrue(waitUntil(timeout: 15) { !app.navigationBars["Событие"].exists })
        let sent = paths.flatMap { server.recorded("PUT", "v1/events/" + $0) }
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first?.jsonObject?["version"] as? Int, 1)
        XCTAssertEqual(sent.last?.jsonObject?["version"] as? Int, 2)
        XCTAssertEqual(sent.last?.jsonObject?["title"] as? String, correctedTitle)
        XCTAssertEqual(sent.last?.jsonObject?["location"] as? String, "Корт 3")
        XCTAssertTrue(server.recorded("POST", "v1/events").isEmpty)
        XCTAssertTrue(paths.allSatisfy { server.recorded("DELETE", "v1/events/" + $0).isEmpty })
    }

    func testTournamentScoreConflictReloadsVersionBeforeCorrection() throws {
        let eventID = "f8e49ac8-4f8c-4d88-8b6e-cb7ff3198a30"
        let gameID = "bb334a74-b41b-4ab0-9da2-544d395e8ea0"
        var me = socialPlayer; me["id"] = StubServer.currentUserID; me["display_name"] = "Михаил Орлов"
        var opponent = socialPlayer; opponent["id"] = "72b11bd9-f270-4ae2-b104-25a132d48204"
        var other = socialPlayer; other["id"] = "2becd560-4954-4ad9-ab50-e454ea8f2d73"
        let game: [String: Any] = ["id": gameID, "round": 1, "court": 1, "team1": [me, socialPlayer], "team2": [opponent, other],
                                 "points1": 20, "points2": 12, "version": 1, "confirmed": false, "confirmations": []]
        let event: [String: Any] = ["id": eventID, "kind": "tournament", "format": "americano", "title": "Турнир с конфликтом счёта",
            "description": "Подтверждённые результаты", "organizer": me, "starts_at": "2026-01-10T10:00:00Z", "duration_minutes": 60,
            "city": ["id": 1, "name": "Москва"], "location": "Корт 2", "capacity": 4, "min_level": 0, "max_level": 7,
            "round_count": 3, "points_per_game": 32, "current_round": 1, "status": "running", "registered_count": 4,
            "viewer": ["is_organizer": true], "registrations": [], "games": [game], "standings": []]
        var changed = game; changed["version"] = 2; changed["points1"] = 22; changed["points2"] = 10
        var fresh = event; fresh["games"] = [changed]
        let originalData = try JSONSerialization.data(withJSONObject: event)
        let freshData = try JSONSerialization.data(withJSONObject: fresh)
        let page = try JSONSerialization.data(withJSONObject: ["items": [event]])
        let conflict = try JSONSerialization.data(withJSONObject: ["error": ["code": "event_version_conflict", "message": "Счёт уже изменился"]])
        let paths = [eventID, UUID(uuidString: eventID)!.uuidString]
        let gamePaths = [gameID, UUID(uuidString: gameID)!.uuidString]
        try launch(.existingUser) { server in
            server.setOverride("GET", "v1/events", .json(page))
            for path in paths {
                server.setOverride("GET", "v1/events/" + path, .json(originalData))
                for gamePath in gamePaths {
                    server.setOverride("PUT", "v1/events/" + path + "/games/" + gamePath + "/score", .json(conflict, status: 409))
                }
            }
        }
        signIn(); waitForHome(); selectTab("Матчи")
        open(element("matches.events"), screen: "Тренировки и турниры")
        tap(require(app.segmentedControls.buttons["Турниры"], "tournament kind"))
        open(button(labelPrefix: "Турнир с конфликтом счёта"), screen: "Турнир")
        scrollIntoView(button(label: "Исправить счёт"))
        open(button(label: "Исправить счёт"), screen: "Счёт раунда")
        for path in paths { server.setOverride("GET", "v1/events/" + path, .json(freshData)) }
        tap(element("eventScore.save"))
        require(app.staticTexts["Счёт изменился. Загружена актуальная версия; проверьте значения перед сохранением."], timeout: 20, "fresh canonical score after conflict")
        for path in paths {
            for gamePath in gamePaths {
                server.setOverride("PUT", "v1/events/" + path + "/games/" + gamePath + "/score", .json(freshData))
            }
        }
        scrollIntoView(element("eventScore.save"))
        let save = require(element("eventScore.save"), "correct refreshed score")
        waitEnabled(save, "score correction unlocked after definitive conflict")
        tap(save)
        XCTAssertTrue(waitUntil(timeout: 15) { !app.navigationBars["Счёт раунда"].exists })
        let sent = paths.flatMap { path in gamePaths.flatMap { server.recorded("PUT", "v1/events/" + path + "/games/" + $0 + "/score") } }
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first?.jsonObject?["version"] as? Int, 1)
        XCTAssertEqual(sent.last?.jsonObject?["version"] as? Int, 2)
        XCTAssertEqual(sent.last?.jsonObject?["points1"] as? Int, 22)
        XCTAssertEqual(sent.last?.jsonObject?["points2"] as? Int, 10)
    }

}
