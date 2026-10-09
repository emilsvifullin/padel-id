import XCTest

/// The Padel ID tab: level, rating, Padel DNA, insights and statistics, and
/// the error state when the server is unavailable.
@MainActor
final class HomeUITests: PadelIDUITestCase {
    func testHomeRatingDnaInsights() throws {
        try launch(.existingUser)
        signIn(screenshot: true)
        waitForHome()
        require(element("home.rating"), "home.rating")
        snap("home-top")

        let dna = require(element("home.dna"), "home.dna")
        scrollIntoView(dna)
        snap("home-dna")

        scrollIntoView(insightsLink())
        snap("home-insights")

        // Rating
        open(require(element("home.rating"), "home.rating"), screen: "Рейтинг")
        snap("rating-detail")
        XCTAssertFalse(server.recorded("GET", "v1/players/\(StubServer.currentUserID)/rating-history").isEmpty)
        goBack(previousTitle: "Padel ID")
        requireScreen("Padel ID")

        // Padel DNA
        open(require(element("home.dna"), "home.dna"), screen: "Padel DNA")
        snap("dna-detail")
        waitForRequest("GET", "v1/players/\(StubServer.currentUserID)/dna")
        goBack(previousTitle: "Padel ID")
        requireScreen("Padel ID")

        // Insights
        open(insightsLink(), screen: "Анализ")
        snap("insights")
        goBack(previousTitle: "Padel ID")
        requireScreen("Padel ID")

        // Statistics
        open(statsLink(), screen: "Статистика")
        snap("stats")
        goBack(previousTitle: "Padel ID")
        requireScreen("Padel ID")
    }

    func testServerErrorState() throws {
        try launch(.existingUser) { server in
            server.setOverride("GET", "v1/home", .serviceUnavailable)
        }
        signIn()

        let retry = require(button(label: "Повторить"), timeout: 25, "Повторить in the error state")
        XCTAssertFalse(element("home.level").exists)
        snap("error-state")
        XCTAssertFalse(server.recorded("GET", "v1/home").isEmpty)

        server.removeOverride("GET", "v1/home")
        tap(retry)
        waitForHome(timeout: 15)
        snap("error-recovered")
    }

    // MARK: - Elements

    /// «Весь анализ» link of the insights block.
    private func insightsLink(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let byIdentifier = element("home.insights")
        if byIdentifier.exists {
            return byIdentifier
        }
        return require(button(label: "Весь анализ"), "Весь анализ", file: file, line: line)
    }

    /// The statistics block (its label starts with the block title).
    private func statsLink() -> XCUIElement {
        let byIdentifier = element("home.stats")
        if byIdentifier.exists {
            return byIdentifier
        }
        return button(labelPrefix: "Статистика")
    }
}
