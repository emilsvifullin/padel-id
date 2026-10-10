import XCTest

/// Players tab: suggestions, filters, search and a player's profile.
@MainActor
final class PlayersUITests: PadelIDUITestCase {
    func testPlayersSearchAndProfile() throws {
        try launch(.existingUser)
        signIn()
        waitForHome()
        selectTab("Друзья")
        open(element("friends.search"), screen: "Найти игроков")

        require(element("playerRow"), timeout: 15, "playerRow")
        waitForRequest("GET", "v1/players/recent")
        snap("players-default")

        // Filters from the toolbar (hidden while a search is active).
        var filtersShown = false
        let filtersButton = find("players.filters")
        if filtersButton.exists && filtersButton.isHittable {
            filtersButton.tap()
            try showAndCloseFilters()
            filtersShown = true
        }

        // Search
        let searchField = require(app.searchFields.firstMatch, "search field")
        searchField.tap()
        searchField.typeText("sokolov")
        let resultsHeader = button(labelPrefix: "Фильтры:")
        require(resultsHeader, timeout: 15, "search results header")
        let sentQuery = waitUntil(timeout: 10) {
            server.recorded("GET", "v1/players/search").contains { $0.query["query"] == "sokolov" }
        }
        XCTAssertTrue(sentQuery, "The typed query was not sent")
        dismissKeyboard()

        if !filtersShown {
            // The results header opens the same filters.
            tap(resultsHeader)
            try showAndCloseFilters()
            dismissKeyboard()
        }

        let sokolov = row("playerRow", containing: "Соколов", timeout: 15)
        scrollIntoView(sokolov)
        snap("players-search")
        sokolov.tap()

        // Profile
        require(element("profile.newMatch"), timeout: 15, "profile.newMatch")
        waitForRequest("GET", "v1/players/\(StubServer.partnerID)")
        snap("profile-top")
        let compatibility = require(element("profile.compatibility"), "profile.compatibility")
        // Scroll until the block starts in the upper part of the screen (it
        // can be taller than the visible band, so "fully visible" is not a
        // target to aim for).
        for _ in 0..<10 where compatibility.frame.minY > app.frame.maxY * 0.45 {
            drag(upwards: true)
        }
        XCTAssertLessThan(compatibility.frame.minY, app.frame.maxY * 0.6, "profile.compatibility scrolled into view")
        snap("profile-scrolled")
    }

    /// The filters sheet is open: screenshot it and close it with «Отмена».
    private func showAndCloseFilters(file: StaticString = #filePath, line: UInt = #line) throws {
        requireScreen("Фильтры", file: file, line: line)
        snap("players-filters")
        let cancel = try XCTUnwrap(firstHittable(app.buttons.matching(NSPredicate(format: "label == %@", "Отмена"))),
                                   "Отмена is not reachable in the filters sheet", file: file, line: line)
        cancel.tap()
        waitForScreenToClose("Фильтры", file: file, line: line)
    }
}
