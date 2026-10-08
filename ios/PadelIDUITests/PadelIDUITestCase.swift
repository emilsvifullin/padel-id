import XCTest

/// Stable screenshot numbering: the number of a screenshot is its position in
/// this list, so names are identical in every test run and configuration.
enum ScreenshotCatalog {
    static let names: [String] = [
        "welcome",
        "sign-up",
        "recovery-key",
        "onboarding-profile",
        "onboarding-city",
        "onboarding-game",
        "onboarding-level",
        "onboarding-style",
        "onboarding-result",
        "home-new",
        "sign-in",
        "home-top",
        "home-dna",
        "home-insights",
        "rating-detail",
        "dna-detail",
        "insights",
        "stats",
        "matches-list",
        "match-pending",
        "match-confirmed",
        "dispute-sheet",
        "editor-empty",
        "player-picker",
        "score-grid",
        "editor-filled",
        "players-default",
        "players-filters",
        "players-search",
        "profile-top",
        "profile-scrolled",
        "account",
        "edit-profile",
        "security",
        "about-rating",
        "delete-account",
        "error-state",
        "error-recovered",
    ]

    /// "PadelID-07-onboarding-level".
    static func attachmentName(_ name: String) -> String {
        let number = (names.firstIndex(of: name) ?? 98) + 1
        return "PadelID-" + (number < 10 ? "0" : "") + String(number) + "-" + name
    }
}

/// Base class of the UI tests: launches the app against the in-process stub
/// server and offers waiting, scrolling, tapping and screenshot helpers that
/// work at every text size (elements are always scrolled into view first).
@MainActor
class PadelIDUITestCase: XCTestCase {
    static let email = "m.orlov@padelid.app"
    static let password = "Padel2026"

    var app: XCUIApplication!
    var server: StubServer!
    private var interruptionMonitor: (any NSObjectProtocol)?

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        if let interruptionMonitor {
            removeUIInterruptionMonitor(interruptionMonitor)
        }
        interruptionMonitor = nil
        if let server {
            XCTAssertTrue(server.missingFixtures.isEmpty,
                          "Fixtures missing from the UI test bundle: \(server.missingFixtures.joined(separator: ", "))")
            server.stop()
        }
        app?.terminate()
        app = nil
        server = nil
    }

    // MARK: - Launch

    /// Starts a fresh stub server for the scenario and launches the app with a
    /// clean state pointed at it.
    @discardableResult
    func launch(_ scenario: StubServer.Scenario, configure: (StubServer) -> Void = { _ in }) throws -> XCUIApplication {
        continueAfterFailure = false
        let server = StubServer(scenario: scenario)
        configure(server)
        try server.start()
        self.server = server

        let app = XCUIApplication()
        app.launchArguments = ["-padelid-uitest-reset-state"]
        app.launchEnvironment = ["PADELID_UITEST_API_BASE_URL": "http://localhost:\(server.port)"]
        self.app = app

        interruptionMonitor = addUIInterruptionMonitor(withDescription: "System permission alert") { alert in
            MainActor.assumeIsolated {
                PadelIDUITestCase.acceptSystemAlert(alert)
            }
        }
        app.launch()
        return app
    }

    /// Allows the notification permission, declines saving the password and
    /// confirms any other system alert.
    static func acceptSystemAlert(_ alert: XCUIElement) -> Bool {
        let titles = ["Not Now", "Не сейчас", "Allow", "Разрешить", "Allow While Using App", "При использовании", "OK", "ОК"]
        for title in titles {
            let button = alert.buttons[title]
            if button.exists {
                button.tap()
                return true
            }
        }
        return false
    }

    // MARK: - Common flows

    /// Signs in as the existing user from the welcome screen.
    func signIn(screenshot: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        tap(require(element("welcome.signIn"), timeout: 15, "welcome.signIn", file: file, line: line), file: file, line: line)
        let email = require(element("signIn.email"), "signIn.email", file: file, line: line)
        enter(Self.email, into: email, file: file, line: line)
        let password = require(element("signIn.password"), "signIn.password", file: file, line: line)
        enter(Self.password, into: password, file: file, line: line)
        if screenshot {
            snap("sign-in")
        }
        submit(element("signIn.submit"), orReturnIn: password)
        dismissSavePasswordPrompt()
    }

    /// iOS offers to save the password after a successful sign-in or sign-up;
    /// the sheet belongs to the system, so look for it in both processes.
    func dismissSavePasswordPrompt(timeout: TimeInterval = 6) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let candidates = ["Not Now", "Не сейчас"].flatMap { title in
            [app.buttons[title], springboard.buttons[title]]
        }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let button = candidates.first(where: { $0.exists && $0.isHittable }) {
                button.tap()
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
    }

    /// Waits for the Padel ID tab with the level hero.
    @discardableResult
    func waitForHome(timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        require(element("home.level"), timeout: timeout, "home.level", file: file, line: line)
    }

    /// Taps the form's submit button when it can be reached, otherwise the
    /// return key of the focused field (the forms submit on return).
    func submit(_ button: XCUIElement, orReturnIn field: XCUIElement) {
        if button.exists && button.isHittable && button.isEnabled {
            button.tap()
        } else {
            field.typeText("\n")
        }
    }

    // MARK: - Queries

    /// Any element with the accessibility identifier.
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The element with the identifier after a short wait for it to appear.
    /// Does not fail: rows of lazy lists (Form, List) below the visible area
    /// only exist once they are scrolled near, which `scrollIntoView` does.
    func find(_ identifier: String, timeout: TimeInterval = 5) -> XCUIElement {
        let target = element(identifier)
        _ = target.waitForExistence(timeout: timeout)
        return target
    }

    /// A button whose label is exactly `label`.
    func button(label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// A button whose label starts with `prefix` (labels of rows combine
    /// their texts, e.g. "Для себя, Без регулярных тренировок").
    func button(labelPrefix prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// A list row with the identifier whose label contains `text`.
    func row(_ identifier: String, containing text: String, timeout: TimeInterval = 10,
             file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let sample = require(element(identifier), timeout: timeout, identifier, file: file, line: line)
        if !sample.label.isEmpty {
            return app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", identifier, text))
                .firstMatch
        }
        return app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// The first element of the query that can be tapped right now.
    func firstHittable(_ query: XCUIElementQuery) -> XCUIElement? {
        for candidate in query.allElementsBoundByIndex where candidate.exists && candidate.isHittable {
            return candidate
        }
        return nil
    }

    // MARK: - Waiting

    /// Polls `condition` while the run loop keeps serving the stub server.
    @discardableResult
    func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        } while Date() < deadline
        return condition()
    }

    @discardableResult
    func require(_ element: XCUIElement, timeout: TimeInterval = 10, _ description: String = "element",
                 file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if !element.waitForExistence(timeout: timeout) {
            XCTFail("Not found within \(Int(timeout)) s: \(description)", file: file, line: line)
        }
        return element
    }

    func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 10, _ description: String = "element",
                              file: StaticString = #filePath, line: UInt = #line) {
        if !waitUntil(timeout: timeout, { !element.exists }) {
            XCTFail("Still visible after \(Int(timeout)) s: \(description)", file: file, line: line)
        }
    }

    func waitEnabled(_ element: XCUIElement, timeout: TimeInterval = 10, _ description: String = "element",
                     file: StaticString = #filePath, line: UInt = #line) {
        require(element, timeout: timeout, description, file: file, line: line)
        if !waitUntil(timeout: timeout, { element.exists && element.isEnabled }) {
            XCTFail("Not enabled within \(Int(timeout)) s: \(description)", file: file, line: line)
        }
    }

    /// Whether a screen with this navigation title is shown.
    func isScreenShown(_ title: String) -> Bool {
        app.navigationBars.matching(identifier: title).firstMatch.exists
            || app.navigationBars.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch.exists
    }

    func requireScreen(_ title: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        if !waitUntil(timeout: timeout, { isScreenShown(title) }) {
            XCTFail("Screen «\(title)» did not open", file: file, line: line)
        }
    }

    func waitForScreenToClose(_ title: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        if !waitUntil(timeout: timeout, { !isScreenShown(title) }) {
            XCTFail("Screen «\(title)» did not close", file: file, line: line)
        }
    }

    /// Waits for a request the app sent to the stub server.
    @discardableResult
    func waitForRequest(_ method: String, _ path: String, timeout: TimeInterval = 10,
                        file: StaticString = #filePath, line: UInt = #line) -> StubRequest? {
        var found: StubRequest?
        _ = waitUntil(timeout: timeout) {
            found = server.recorded(method, path).last
            return found != nil
        }
        if found == nil {
            XCTFail("The app did not send \(method) \(path)", file: file, line: line)
        }
        return found
    }

    // MARK: - Interaction

    /// Scrolls the element into view and taps it.
    func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        scrollIntoView(element, file: file, line: line)
        element.tap()
    }

    /// Taps the element with the identifier; rows of lazy lists that are not
    /// created yet are found by scrolling.
    func tap(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        tap(find(identifier), file: file, line: line)
    }

    /// Waits until the control is enabled, scrolls to it and taps it.
    func tapWhenEnabled(_ element: XCUIElement, _ description: String = "element",
                        file: StaticString = #filePath, line: UInt = #line) {
        waitEnabled(element, description, file: file, line: line)
        tap(element, file: file, line: line)
    }

    /// Focuses a text field and types into it.
    func enter(_ text: String, into field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        scrollIntoView(field, file: file, line: line)
        field.tap()
        dismissKeyboardIntroduction()
        field.typeText(text)
    }

    /// Hides the software keyboard if it is shown (return-like key or the
    /// keyboard toolbar's «Готово»).
    func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        let toolbarDone = app.toolbars.buttons.matching(NSPredicate(format: "label == %@", "Готово"))
        if let done = firstHittable(toolbarDone) {
            done.tap()
        } else {
            let keys = ["Return", "return", "Done", "done", "Go", "go", "Search", "search", "Next", "next",
                        "Ввод", "Готово", "Найти", "Далее"]
            for key in keys {
                let candidate = app.keyboards.buttons[key]
                if candidate.exists && candidate.isHittable {
                    candidate.tap()
                    break
                }
            }
        }
        _ = waitUntil(timeout: 3) { !app.keyboards.firstMatch.exists }
    }

    /// Fresh simulators can show the "slide to type" introduction over the keyboard.
    private func dismissKeyboardIntroduction() {
        let introduction = app.otherElements["UIContinuousPathIntroductionView"]
        guard introduction.exists else { return }
        let proceed = introduction.buttons.firstMatch
        if proceed.exists {
            proceed.tap()
        }
    }

    /// Turns a SwiftUI toggle on and waits for `isDone` (its visible effect).
    func turnOn(_ toggle: XCUIElement, until isDone: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        require(toggle, "toggle", file: file, line: line)
        scrollIntoView(toggle, file: file, line: line)
        if isDone() { return }
        let control = toggle.switches.firstMatch
        if control.exists && control.isHittable {
            control.tap()
        } else {
            toggle.tap()
        }
        if waitUntil(timeout: 3, isDone) { return }
        // The switch sits at the trailing edge of the row.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        if !waitUntil(timeout: 3, isDone) {
            XCTFail("The toggle did not switch on", file: file, line: line)
        }
    }

    /// Selects a tab of the tab bar by its title.
    func selectTab(_ title: String, alternatives: [String] = [], file: StaticString = #filePath, line: UInt = #line) {
        let inTabBar = app.tabBars.buttons[title]
        if inTabBar.waitForExistence(timeout: 5) && inTabBar.isHittable {
            inTabBar.tap()
            return
        }
        // A badge can extend the label ("Матчи, 1 …"); the search tab can sit
        // outside the tab bar group.
        for label in [title] + alternatives {
            let queries = [
                app.tabBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)),
                app.buttons.matching(NSPredicate(format: "label == %@", label)),
                app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)),
            ]
            for query in queries {
                if let candidate = firstHittable(query) {
                    candidate.tap()
                    return
                }
            }
        }
        XCTFail("Tab «\(title)» not found", file: file, line: line)
    }

    /// Returns to the previous screen of a navigation stack.
    func goBack(previousTitle: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        if let back = firstHittable(app.navigationBars.buttons.matching(identifier: "BackButton")) {
            back.tap()
            return
        }
        var labels = ["Назад", "Back"]
        if let previousTitle {
            labels.append(previousTitle)
        }
        for label in labels {
            if let back = firstHittable(app.navigationBars.buttons.matching(NSPredicate(format: "label == %@", label))) {
                back.tap()
                return
            }
        }
        // Interactive pop gesture from the leading edge.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    // MARK: - Scrolling

    /// The part of the screen where scrolled content is visible: below the
    /// navigation bar, above the tab bar and above the keyboard.
    private func visibleBand() -> CGRect {
        let screen = app.frame
        let top = screen.minY + screen.height * 0.14
        var bottom = screen.maxY - screen.height * 0.12
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            let keyboardTop = keyboard.frame.minY
            if keyboardTop > top + 120 {
                bottom = min(bottom, keyboardTop - 8)
            }
        }
        return CGRect(x: screen.minX, y: top, width: screen.width, height: max(bottom - top, 1))
    }

    /// Whether the element is on screen: hittable, or (for non-interactive
    /// blocks) inside the visible band.
    func isOnScreen(_ element: XCUIElement, hittable: Bool = true) -> Bool {
        guard element.exists else { return false }
        if hittable {
            return element.isHittable
        }
        let frame = element.frame
        guard !frame.isEmpty else { return false }
        let band = visibleBand()
        let overlap = frame.intersection(band)
        guard !overlap.isNull else { return false }
        return overlap.height >= min(frame.height, band.height * 0.5) - 1
    }

    /// Scrolls with short, momentum-free drags until the element is on screen.
    /// Elements that are not created yet (lazy lists) are looked for below.
    @discardableResult
    func scrollIntoView(_ element: XCUIElement, hittable: Bool = true, maxDrags: Int = 15,
                        file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if isOnScreen(element, hittable: hittable) {
            return element
        }
        for _ in 0..<maxDrags {
            if element.exists {
                let frame = element.frame
                let band = visibleBand()
                if !frame.isEmpty && band.contains(CGPoint(x: frame.midX, y: frame.midY))
                    && waitUntil(timeout: 1, { isOnScreen(element, hittable: hittable) }) {
                    return element
                }
                drag(upwards: frame.isEmpty || frame.midY > band.midY)
            } else {
                drag(upwards: true)
            }
            if isOnScreen(element, hittable: hittable) {
                return element
            }
        }
        if !isOnScreen(element, hittable: hittable) {
            XCTFail("Could not scroll the element into view", file: file, line: line)
        }
        return element
    }

    /// One short vertical drag in the middle of the visible band, held at the
    /// end so that the content does not keep scrolling.
    func drag(upwards: Bool) {
        let screen = app.frame
        let band = visibleBand()
        let distance = min(screen.height * 0.3, band.height * 0.45)
        let startY = upwards ? band.minY + band.height * 0.62 : band.minY + band.height * 0.30
        let endY = upwards ? startY - distance : startY + distance
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let x = screen.width / 2
        let start = origin.withOffset(CGVector(dx: x, dy: startY - screen.minY))
        let end = origin.withOffset(CGVector(dx: x, dy: endY - screen.minY))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.1)
    }

    // MARK: - Screenshots

    /// Attaches a screenshot named "PadelID-NN-name" (kept even for passing tests).
    func snap(_ name: String) {
        settle()
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = ScreenshotCatalog.attachmentName(name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Lets loading indicators and transitions finish before a screenshot.
    private func settle() {
        _ = waitUntil(timeout: 4) { !app.activityIndicators.firstMatch.exists }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
}
