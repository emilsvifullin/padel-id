import XCTest

@MainActor
final class SocialUITests: PadelIDUITestCase {
    func testPersistentTabsFriendRequestsAndSearch() throws {
        try launch(.existingUser)
        signIn()
        waitForHome()
        for title in ["Главная", "Матчи", "Анализ", "Друзья", "Профиль"] {
            XCTAssertTrue(app.tabBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch.exists)
        }
        selectTab("Друзья")
        waitForRequest("GET", "v1/friends")
        require(element("friends.row"), "friend row")
        snap("friends-requests")
        let accept = button(label: "Принять")
        scrollIntoView(accept)
        tap(accept)
        waitForRequest("POST", "v1/friends/72b11bd9-f270-4ae2-b104-25a132d48204/respond")
        let sent = try XCTUnwrap(server.recorded("POST", "v1/friends/72b11bd9-f270-4ae2-b104-25a132d48204/respond").last)
        XCTAssertEqual(sent.jsonObject?["decision"] as? String, "accepted")
        open(element("friends.search"), screen: "Найти игроков")
        require(element("playerRow"), "player search preserved")
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
        requireScreen("Новая открытая игра")
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
        XCTAssertTrue(waitUntil(timeout: 15) { !app.navigationBars["Новая открытая игра"].exists })
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
        requireScreen("Внести результат")
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
}
