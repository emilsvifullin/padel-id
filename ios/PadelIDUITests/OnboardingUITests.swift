import XCTest

/// Sign-up of a new player: welcome, account, recovery key, the four
/// onboarding steps, the starting level and the first home screen.
@MainActor
final class OnboardingUITests: PadelIDUITestCase {
    func testSignUpAndOnboarding() throws {
        try launch(.newUser)

        // Welcome
        let signUp = require(element("welcome.signUp"), timeout: 15, "welcome.signUp")
        snap("welcome")
        tap(signUp, until: element("signUp.email"))

        // Account
        let email = require(element("signUp.email"), "signUp.email")
        enter("new.player@padelid.app", into: email)
        XCTAssertEqual(email.value as? String, "new.player@padelid.app", "e-mail typed into the sign-up form")
        // Return moves focus to the password field (the form's onSubmit).
        email.typeText("\n")
        let password = require(element("signUp.password"), "signUp.password")
        let submitButton = element("signUp.submit")
        enterPassword(Self.password, into: password, accepted: { submitButton.exists && submitButton.isEnabled })
        snap("sign-up")
        submit(element("signUp.submit"), orReturnIn: password)
        dismissSavePasswordPrompt()
        waitForRequest("POST", "v1/auth/signup")

        // Recovery key (shown once, has to be confirmed)
        require(element("recoveryKey.value"), timeout: 20, "recoveryKey.value")
        let keyDone = require(element("recoveryKey.done"), "recoveryKey.done")
        snap("recovery-key")
        turnOn(element("recoveryKey.confirm"), until: { keyDone.exists && keyDone.isEnabled })
        tap(keyDone)
        waitForDisappearance(keyDone, "recovery key screen")

        // Step 1 — profile
        requireScreen("Профиль", timeout: 15)
        let name = require(element("onboarding.displayName"), "onboarding.displayName")
        enter("Ilya Gromov", into: name)
        // The username is suggested from the name; only the keyboard has
        // to go before the city row.
        dismissKeyboard()

        // The keyboard may still be closing and move the row under the tap.
        let cityRow = find("onboarding.city")
        scrollIntoView(cityRow)
        moveAboveBottomBar(cityRow)
        tap(cityRow, until: button(label: "Москва"))
        let moscow = require(button(label: "Москва"), timeout: 15, "Москва in the city picker")
        snap("onboarding-city")
        tap(moscow)
        waitForDisappearance(moscow, "city picker")
        let profileNext = element("onboarding.next")
        waitEnabled(profileNext, timeout: 15, "onboarding.next on the profile step")
        snap("onboarding-profile")
        tap(profileNext)

        // Step 2 — game
        requireScreen("Игра")
        chooseAnswer("Справа")
        snap("onboarding-game")
        tapWhenEnabled(element("onboarding.next"), "onboarding.next on the game step")

        // Step 3 — calibration questions
        requireScreen("Уровень")
        let levelNext = element("onboarding.next")
        // A second pass picks up an answer whose tap was lost (answers that
        // are already selected are left alone).
        for pass in 0..<2 {
            if pass > 0 {
                scrollToQuestion("Как давно вы играете в падел?")
            }
            for answer in ["От полугода до года", "3 раза в неделю и чаще", "Для себя",
                           "Уверенно после одного стекла", "Уверенный воллей и бандеха", "Клубные американо"] {
                chooseAnswer(answer)
            }
            if waitUntil(timeout: 2, { levelNext.exists && levelNext.isEnabled }) {
                break
            }
        }
        snap("onboarding-level")
        if !(levelNext.exists && levelNext.isEnabled) {
            reportSelectedAnswers(from: "Как давно вы играете в падел?")
        }
        tapWhenEnabled(levelNext, "onboarding.next on the level step")

        // Step 4 — Padel DNA self-assessment (defaults are valid answers)
        requireScreen("Стиль игры")
        let finish = element("onboarding.finish")
        waitEnabled(finish, "onboarding.finish")
        snap("onboarding-style")
        tap(finish)

        // Starting level
        let openApp = require(element("onboarding.open"), timeout: 20, "onboarding.open")
        snap("onboarding-result")

        let request = try XCTUnwrap(server.recorded("POST", "v1/me/onboarding").last, "Onboarding was not sent")
        let body = try XCTUnwrap(request.jsonObject, "Onboarding body is not a JSON object")
        XCTAssertEqual(body["display_name"] as? String, "Ilya Gromov")
        XCTAssertEqual(body["username"] as? String, "ilya_gromov")
        XCTAssertEqual(body["city_id"] as? Int, 1)
        XCTAssertEqual(body["preferred_side"] as? String, "right")
        XCTAssertEqual(body["dominant_hand"] as? String, "right")
        let calibration = try XCTUnwrap(body["calibration"] as? [String: Any], "calibration is missing")
        XCTAssertEqual(calibration["experience"] as? String, "6to12m")
        XCTAssertEqual(calibration["frequency"] as? String, "often")
        XCTAssertEqual(calibration["racket"] as? String, "amateur")
        XCTAssertEqual(calibration["glass"] as? Int, 2)
        XCTAssertEqual(calibration["net"] as? Int, 2)
        XCTAssertEqual(calibration["competition"] as? Int, 1)
        let dnaSelf = try XCTUnwrap(body["dna_self"] as? [String: Any], "dna_self is missing")
        XCTAssertEqual(dnaSelf.count, 6)

        tap(openApp)
        waitForHome()
        snap("home-new")
    }

    /// Scrolls back up to a question header: rows are created lazily, and
    /// looking for an answer only scrolls down.
    private func scrollToQuestion(_ question: String) {
        let header = app.staticTexts[question]
        for _ in 0..<12 where !(header.exists && header.isHittable) {
            drag(upwards: false)
        }
    }

    /// Records which answers the screen reports as selected, from the first
    /// question down (diagnostics for a step that does not complete).
    private func reportSelectedAnswers(from question: String) {
        scrollToQuestion(question)
        var selected: [String] = []
        for _ in 0..<12 {
            let labels = app.buttons.matching(NSPredicate(format: "selected == true"))
                .allElementsBoundByIndex.map(\.label)
            selected.append(contentsOf: labels.filter { !selected.contains($0) })
            drag(upwards: true)
        }
        let footer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Осталось ответить"))
            .firstMatch
        XCTFail("Selected answers: \(selected); footer: \(footer.exists ? footer.label : "none")")
    }

    /// Taps a single-choice answer row (labels start with the option title).
    private func chooseAnswer(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let answer = button(labelPrefix: title)
        // Rows further down are created only when scrolled near.
        _ = answer.waitForExistence(timeout: 2)
        scrollIntoView(answer, file: file, line: line)
        if answer.isSelected {
            return
        }
        moveAboveBottomBar(answer)
        answer.tap()
        if !waitUntil(timeout: 2, { answer.exists && answer.isSelected }) {
            // Selecting the same answer again is harmless if the first tap was lost.
            scrollIntoView(answer, file: file, line: line)
            answer.tap()
        }
    }
}
