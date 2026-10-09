import XCTest

/// Matches tab: confirming and disputing a result, entering a new match.
@MainActor
final class MatchesUITests: PadelIDUITestCase {
    func testConfirmPendingMatch() throws {
        try launch(.existingUser)
        signIn()
        waitForHome()
        openPendingMatch(screenshotList: true)

        let confirm = require(element("match.confirm"), timeout: 15, "match.confirm")
        snap("match-pending")
        tap(confirm)

        let request = try XCTUnwrap(waitForRequest("POST", "v1/matches/\(StubServer.pendingMatchID)/confirm"))
        XCTAssertEqual(request.jsonObject?["version"] as? Int, 1)
        waitForDisappearance(confirm, timeout: 15, "match.confirm after confirming")
        XCTAssertFalse(element("match.dispute").exists)
        require(element("match.feedback"), timeout: 15, "match.feedback of the confirmed match")
        snap("match-confirmed")
    }

    func testDisputeSheet() throws {
        try launch(.existingUser)
        signIn()
        waitForHome()
        openPendingMatch(screenshotList: false)

        open(require(element("match.dispute"), timeout: 15, "match.dispute"), screen: "Оспорить результат")
        let reason = require(button(labelPrefix: "Неверный сч"), "first dispute reason")
        tap(reason)
        let send = button(label: "Отправить")
        let reasonChosen = waitUntil(timeout: 3) {
            (reason.exists && reason.isSelected) || (send.exists && send.isEnabled)
        }
        XCTAssertTrue(reasonChosen, "The dispute reason was not selected")
        snap("dispute-sheet")

        let cancel = firstHittable(app.buttons.matching(NSPredicate(format: "label == %@", "Отмена")))
        let cancelButton = try XCTUnwrap(cancel, "Отмена is not reachable in the dispute sheet")
        cancelButton.tap()
        waitForScreenToClose("Оспорить результат")
        require(element("match.dispute"), "match.dispute after cancelling")
        require(element("match.confirm"), "match.confirm after cancelling")
        XCTAssertTrue(server.recorded("POST", "v1/matches/\(StubServer.pendingMatchID)/dispute").isEmpty)
    }

    func testCreateMatch() throws {
        try launch(.existingUser)
        signIn()
        waitForHome()
        selectTab("Матчи")
        open(require(element("matches.new"), timeout: 15, "matches.new"), screen: "Новый матч")
        scrollIntoView(find("editor.slot.1.left"))
        snap("editor-empty")

        pickPlayer("Соколов", for: "editor.slot.1.left", screenshot: true)
        pickPlayer("Морозов", for: "editor.slot.2.right")
        pickPlayer("Волков", for: "editor.slot.2.left")

        enterSet(1, score: "6-4", screenshot: true)
        enterSet(2, score: "6-3")

        // The forecast is requested for the line-up and again with the score.
        let forecastWithScore = waitUntil(timeout: 15) {
            server.recorded("POST", "v1/matches/preview").contains { request in
                ((request.jsonObject?["sets"] as? [Any])?.count ?? 0) == 2
            }
        }
        XCTAssertTrue(forecastWithScore, "The forecast was not requested with the entered score")
        let forecast = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Шансы вашей пары"))
            .firstMatch
        scrollIntoView(forecast, hittable: false, maxDrags: 20)
        snap("editor-filled")

        let submit = element("editor.submit")
        waitEnabled(submit, "editor.submit")
        submit.tap()
        let request = try XCTUnwrap(waitForRequest("POST", "v1/matches", timeout: 15))
        waitForDisappearance(submit, timeout: 15, "match editor")

        XCTAssertNotNil(request.header("Idempotency-Key"), "A new match must carry an idempotency key")
        let body = try XCTUnwrap(request.jsonObject, "The match body is not a JSON object")
        XCTAssertEqual(body["match_type"] as? String, "ranked")
        XCTAssertEqual(body["format"] as? String, "best_of_3")
        let players = try XCTUnwrap(body["players"] as? [[String: Any]], "players are missing")
        XCTAssertEqual(players.count, 4)
        let me = players.first { ($0["player_id"] as? String) == StubServer.currentUserID }
        XCTAssertEqual(me?["team"] as? Int, 1)
        XCTAssertEqual(me?["court_side"] as? String, "right")
        let partner = players.first { ($0["player_id"] as? String) == StubServer.partnerID }
        XCTAssertEqual(partner?["team"] as? Int, 1)
        XCTAssertEqual(partner?["court_side"] as? String, "left")
        XCTAssertEqual(players.filter { ($0["team"] as? Int) == 2 }.count, 2)
        let sets = try XCTUnwrap(body["sets"] as? [[String: Any]], "sets are missing")
        XCTAssertEqual(sets.map { $0["t1"] as? Int }, [6, 6])
        XCTAssertEqual(sets.map { $0["t2"] as? Int }, [4, 3])
    }

    // MARK: - Steps

    /// Opens the match that waits for the current user's answer: the first
    /// unconfirmed row («Ждёт подтверждения»), which is the «Нужен ваш ответ»
    /// section at the top of the Matches tab.
    private func openPendingMatch(screenshotList: Bool, file: StaticString = #filePath, line: UInt = #line) {
        selectTab("Матчи", file: file, line: line)
        let pendingRow = row("matchRow", containing: "подтверждения", timeout: 15, file: file, line: line)
        require(pendingRow, timeout: 15, "row of the match awaiting an answer", file: file, line: line)
        if screenshotList {
            snap("matches-list")
        }
        open(pendingRow, screen: "Матч", file: file, line: line)
        waitForRequest("GET", "v1/matches/\(StubServer.pendingMatchID)", file: file, line: line)
    }

    /// Opens the player picker for a line-up slot and picks the player.
    private func pickPlayer(_ name: String, for slot: String, screenshot: Bool = false,
                            file: StaticString = #filePath, line: UInt = #line) {
        tap(find(slot), file: file, line: line)
        let search = require(element("picker.search"), "picker.search", file: file, line: line)
        let player = row("picker.player", containing: name, timeout: 15, file: file, line: line)
        scrollIntoView(player, file: file, line: line)
        if screenshot {
            snap("player-picker")
        }
        player.tap()
        waitForDisappearance(search, "player picker", file: file, line: line)
        let tile = element(slot)
        let isShown = waitUntil(timeout: 5) { tile.exists && tile.label.contains(name) }
        XCTAssertTrue(isShown, "\(slot) does not show \(name)", file: file, line: line)
    }

    /// Opens the score grid of a set and picks the result.
    private func enterSet(_ number: Int, score: String, screenshot: Bool = false,
                          file: StaticString = #filePath, line: UInt = #line) {
        let setRow = element("editor.set.\(number)")
        tap(setRow, file: file, line: line)
        let option = require(element("score.\(score)"), "score.\(score)", file: file, line: line)
        if screenshot {
            snap("score-grid")
        }
        tap(option, file: file, line: line)
        waitForDisappearance(option, "score grid", file: file, line: line)
    }
}
