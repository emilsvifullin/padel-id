import XCTest

/// The Padel ID tab: level, rating, Padel DNA, insights and statistics, and
/// the error state when the server is unavailable.
@MainActor
final class HomeUITests: PadelIDUITestCase {
    func testRegisteredTrainingAppearsOnHomeAndOpensCanonicalEvent() throws {
        let id = "d6bedc42-afb7-4e16-908a-dc9e0f52b91c"
        let coach: [String: Any] = ["id": StubServer.partnerID, "display_name": "Дмитрий Соколов", "deleted": false, "is_coach": true]
        let event: [String: Any] = ["id": id, "kind": "training", "format": "group", "title": "Ваша ближайшая тренировка",
            "description": "Работа у сетки", "organizer": coach, "starts_at": "2099-10-12T10:00:00Z", "duration_minutes": 60,
            "city": ["id": 1, "name": "Москва"], "location": "Корт 2", "capacity": 4, "min_level": 0, "max_level": 7,
            "round_count": 1, "points_per_game": 32, "current_round": 0, "status": "open", "registered_count": 1,
            "viewer": ["is_organizer": false, "registration": "accepted"], "registrations": [], "games": [], "standings": []]
        let detail = try JSONSerialization.data(withJSONObject: event)
        let page = try JSONSerialization.data(withJSONObject: ["items": [event]])
        try launch(.existingUser) { server in
            server.setOverride("GET", "v1/events", .json(page))
            for path in [id, UUID(uuidString: id)!.uuidString] {
                server.setOverride("GET", "v1/events/" + path, .json(detail))
            }
        }
        signIn(); waitForHome()
        scrollIntoView(element("home.sportEvent"))
        require(app.staticTexts["Вы записаны"])
        XCTAssertTrue(server.recorded("GET", "v1/events").contains {
            $0.query["scope"] == "mine" && $0.query["upcoming_only"] == "true"
        })
        open(element("home.sportEvent"), screen: "Тренировка")
        require(app.staticTexts["Ваша ближайшая тренировка"])
        scrollIntoView(button(label: "Отменить запись"))
        require(button(label: "Отменить запись"))
        goBack(previousTitle: "Главная")
        requireScreen("Главная")
    }

    /// The system accessibility audit on the two screens that carry the
    /// brand surfaces, in both themes: contrast, labels, hit regions, Dynamic
    /// Type and clipped text.
    func testHomeAndAppearanceAccessibility() throws {
        try launch(.existingUser)
        signIn(); waitForHome()
        // Record every failure of a pass instead of stopping at the first.
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        selectTab("Профиль")
        open(element("account.appearance"), screen: "Оформление")
        for title in ["Тёмная", "Светлая"] {
            tap(button(label: title))
            try auditVisibleScreen()
            snap("appearance-accessibility-" + title)
            selectTab("Главная")
            require(element("home.level"), timeout: 15, "home.level")
            try auditVisibleScreen()
            snap("home-accessibility-" + title)
            selectTab("Профиль")
        }
    }

    private func auditVisibleScreen() throws {
        let types: [XCUIAccessibilityAuditType] = [.dynamicType, .textClipped, .contrast, .sufficientElementDescription, .hitRegion]
        for type in types {
            try app.performAccessibilityAudit(for: type) { issue in
                print("ACCESSIBILITY AUDIT: \(issue.compactDescription); target: \(issue.element?.debugDescription ?? "unknown")")
                print("ACCESSIBILITY DETAIL: \(issue.detailedDescription)")
                // The contrast audit samples the screenshot. Scroll content cut
                // by the navigation or tab bar has no complete glyphs to
                // measure; every other category and all fully visible text
                // stay strict.
                guard issue.auditType == .contrast, let target = issue.element else { return false }
                // The floating tab bar blurs what scrolls under it well above
                // its own frame.
                let top = self.app.navigationBars.firstMatch.frame.maxY
                let bottom = min(self.app.tabBars.firstMatch.frame.minY - 16, self.app.windows.firstMatch.frame.maxY - 110)
                if target.frame.minY < top || target.frame.maxY > bottom {
                    print("ACCESSIBILITY EDGE FRAGMENT: \(target.label), frame=\(target.frame), content=\(top)...\(bottom)")
                    return true
                }
                return false
            }
        }
    }

    func testHomeRatingDnaInsights() throws {
        try launch(.existingUser)
        signIn(screenshot: true)
        waitForHome()
        openAnalysis()
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
        goBack(previousTitle: "Анализ")
        requireScreen("Анализ")

        // Padel DNA
        open(require(element("home.dna"), "home.dna"), screen: "Padel DNA")
        snap("dna-detail")
        waitForRequest("GET", "v1/players/\(StubServer.currentUserID)/dna")
        goBack(previousTitle: "Анализ")
        requireScreen("Анализ")

        // Insights
        open(insightsLink(), screen: "Выводы об игре")
        snap("insights")
        goBack(previousTitle: "Анализ")
        requireScreen("Анализ")

        // Statistics
        open(statsLink(), screen: "Статистика")
        snap("stats")
        goBack(previousTitle: "Анализ")
        requireScreen("Анализ")
    }

    func testServerErrorState() throws {
        try launch(.existingUser) { server in
            server.setOverride("GET", "v1/home", .serviceUnavailable)
        }
        signIn()
        waitForHome()
        openAnalysis()

        let retry = require(button(label: "Повторить"), timeout: 25, "Повторить in the error state")
        XCTAssertFalse(element("home.level").exists)
        snap("error-state")
        XCTAssertFalse(server.recorded("GET", "v1/home").isEmpty)

        server.removeOverride("GET", "v1/home")
        tap(retry)
        require(element("home.level"), timeout: 15, "home.level")
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
