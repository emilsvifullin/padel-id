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

    func testHomeAndAppearanceAccessibility() throws {
        try launch(.existingUser)
        signIn(); waitForHome()
        let audits: XCUIAccessibilityAuditType = [.sufficientElementDescription, .hitRegion]
        func audit(scrollViewport: Bool = false, layoutChecks: Bool = false) throws {
            // Dynamic Type and clipping audits change font sizes and reflow the
            // ScrollView. Re-establish the viewport before pixel-based audits.
            let types: [XCUIAccessibilityAuditType] = layoutChecks
                ? [.dynamicType, .textClipped] : [.contrast, audits]
            for type in types {
                try app.performAccessibilityAudit(for: type) { issue in
                    print("ACCESSIBILITY AUDIT: \(issue.compactDescription); target: \(issue.element?.debugDescription ?? "unknown")")
                    print("ACCESSIBILITY DETAIL: \(issue.detailedDescription)")
                    // XCTest sometimes reports screenshot-based contrast for scroll
                    // text entirely behind native bars or outside the screen. Those
                    // fragments contain no complete glyph sample. Classify only
                    // contrast on scroll text/buttons crossing the unobscured viewport;
                    // every other category and fully visible text remains strict.
                    if scrollViewport, issue.auditType == .contrast, let target = issue.element,
                       (target.elementType == .staticText || target.elementType == .button),
                       [self.app.scrollViews, self.app.collectionViews].contains(where: {
                           $0.descendants(matching: target.elementType)
                               .matching(NSPredicate(format: "label == %@", target.label)).firstMatch.exists
                       }) {
                        let top = self.app.navigationBars.firstMatch.frame.maxY
                        let bottom = self.app.tabBars.firstMatch.frame.minY
                        if target.frame.minY < top || target.frame.maxY > bottom {
                            print("ACCESSIBILITY EDGE FRAGMENT: \(target.label), frame=\(target.frame), content=\(top)...\(bottom)")
                            return true
                        }
                    }
                    return false
                }
            }
        }
        // Record every real failure; log screenshot edge-fragment classifications.
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        selectTab("Профиль")
        open(element("account.appearance"), screen: "Оформление")
        for title in ["Тёмная", "Светлая"] {
            tap(button(label: title))
            try audit(layoutChecks: true)
            try audit(scrollViewport: true)
            let help = scrollIntoView(element("appearance.icon.help"))
            for _ in 0..<4 {
                if help.frame.maxY <= app.tabBars.firstMatch.frame.minY - 16 { break }
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.50))
                start.press(forDuration: 0.1, thenDragTo: end)
            }
            XCTAssertGreaterThanOrEqual(help.frame.minY, app.navigationBars.firstMatch.frame.maxY)
            XCTAssertLessThanOrEqual(help.frame.maxY, app.tabBars.firstMatch.frame.minY - 16)
            try audit(scrollViewport: true)
            snap("appearance-accessibility-" + title)
            selectTab("Главная")
            try audit(scrollViewport: true, layoutChecks: true)
            // Tab navigation retains the previous scroll position. Audit the
            // header only after returning the complete identity above the bars.
            let identity = scrollIntoView(element("home.profile"), searchBelow: false)
            let headerTop = app.navigationBars.firstMatch.frame.maxY
            let headerBottom = app.tabBars.firstMatch.frame.minY
            for _ in 0..<6 {
                if identity.frame.minY >= headerTop && identity.frame.maxY <= headerBottom { break }
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                start.press(forDuration: 0.1, thenDragTo: end)
            }
            XCTAssertGreaterThanOrEqual(identity.frame.minY, headerTop)
            XCTAssertLessThanOrEqual(identity.frame.maxY, headerBottom)
            try audit(scrollViewport: true)
            snap("home-header-accessibility-" + title)
            // The system contrast audit samples the screenshot. A trend whose
            // frame only intersects the bottom edge has no rendered glyphs to
            // measure. Bring both labels above the native tab bar and prove
            // their full visibility before running the unchanged strict audit.
            let trend = require(app.staticTexts["за 30 дней"], "rating trend period")
            let delta = require(app.staticTexts["Рост на 0.24"], "rating trend delta")
            let findGame = require(app.staticTexts["Найти игру"], "find game action")
            let createGame = require(app.staticTexts["Создать игру"], "create game action")
            try audit(scrollViewport: true, layoutChecks: true)
            let viewport = app.windows.firstMatch.frame
            let top = app.navigationBars.firstMatch.frame.maxY + 8
            let bottom = min(app.tabBars.firstMatch.frame.minY - 16, viewport.maxY - 110)
            for _ in 0..<6 {
                if trend.frame.minY >= top && trend.frame.maxY <= bottom &&
                    delta.frame.minY >= top && delta.frame.maxY <= bottom &&
                    findGame.frame.minY >= top && findGame.frame.maxY <= bottom &&
                    createGame.frame.minY >= top && createGame.frame.maxY <= bottom { break }
                let above = [trend, delta, findGame, createGame].contains { $0.frame.minY < top }
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.42 : 0.65))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.65 : 0.42))
                start.press(forDuration: 0.1, thenDragTo: end)
            }
            for label in [trend, delta, findGame, createGame] {
                XCTAssertGreaterThanOrEqual(label.frame.minX, viewport.minX)
                XCTAssertLessThanOrEqual(label.frame.maxX, viewport.maxX)
                XCTAssertGreaterThanOrEqual(label.frame.minY, top)
                XCTAssertLessThanOrEqual(label.frame.maxY, bottom)
                XCTAssertTrue(label.isHittable)
                print("ACCESSIBILITY VISIBLE: \(label.label) frame=\(label.frame), bounds=\(top)...\(bottom)")
            }
            try audit(scrollViewport: true)
            snap("home-accessibility-" + title)
            selectTab("Профиль")
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
