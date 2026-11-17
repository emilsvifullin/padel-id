import XCTest

@MainActor
final class DeviceFeedbackCheck: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "app.padelid.ios.preview")

    override func setUpWithError() throws { continueAfterFailure = false }

    func testTrainingDetailsReturnAndTextLayout() {
        app.launchArguments = ["-previewPlayerHome"]
        app.launch()
        openTraining("23 ноября")
        let replacement = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "27 ноября")).firstMatch
        XCTAssertTrue(replacement.waitForExistence(timeout: 4))
        replacement.tap()
        XCTAssertTrue(app.buttons["Подтвердить запись"].isEnabled)
        shot("23-selected-replacement")
        openAndReturnFromChat()
        XCTAssertTrue(app.buttons["Подтвердить запись"].isEnabled)
        XCTAssertTrue(replacement.isSelected)
        app.buttons["Закрыть"].tap()

        openTraining("26 ноября")
        checkContent("Администратор предложит новую дату.", above: app.buttons["Написать в поддержку"].firstMatch)
        shot("26-cancelled")
        openAndReturnFromChat()
        checkContent("Администратор предложит новую дату.", above: app.buttons["Написать в поддержку"].firstMatch)
        app.buttons["Закрыть"].tap()

        openTraining("30 ноября")
        checkContent("Отмена с отработкой до", above: app.buttons["Отменить запись"])
        shot("30-scheduled")
        openAndReturnFromChat()
        checkContent("Отмена с отработкой до", above: app.buttons["Отменить запись"])
        app.buttons["Отменить запись"].tap()
        app.buttons["Подтвердить отмену"].tap()
        checkContent("Нет свободных дат.", above: app.buttons["Написать в поддержку"].firstMatch)
        shot("30-makeup-no-dates")
        app.buttons["Закрыть"].tap()

        app.tabBars.buttons["Абонемент"].tap()
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Нет свободных дат")).firstMatch.waitForExistence(timeout: 4))
        shot("membership-with-credit")
    }

    func testFirstPaymentHelpIsFullScreenAndReturns() {
        app.launchArguments = ["-previewTwoMonthPayment"]
        app.launch()
        let help = app.buttons["Вопрос по оплате"]
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        help.tap()
        let support = app.navigationBars["Поддержка"]
        XCTAssertTrue(support.waitForExistence(timeout: 4))
        XCTAssertLessThan(support.frame.minY, 85)
        XCTAssertTrue(app.buttons["support.removeTopic"].isHittable)
        shot("payment-full-screen-chat")
        support.buttons["Назад"].tap()
        XCTAssertTrue(help.waitForExistence(timeout: 4))
        XCTAssertTrue(help.isHittable)
        app.buttons["Оплатить по СБП"].tap()
        app.buttons["Подтвердить оплату"].tap()
        XCTAssertTrue(app.staticTexts["Оплата подтверждена"].waitForExistence(timeout: 4))
        shot("payment-success")
    }

    func testTextSendKeepsKeyboardAndLatestMessageVisible() {
        app.launchArguments = ["-previewPlayerHome"]
        app.launch()
        app.tabBars.buttons["Настройки"].tap()
        app.buttons["Поддержка"].tap()
        let composer = app.textFields["support.composer"]
        let send = app.buttons["support.send"]
        XCTAssertTrue(composer.waitForExistence(timeout: 4))
        composer.tap()
        let history = app.scrollViews["support.history"]
        for index in 1...2 {
            let phrase = "Сообщение для проверки \(index)"
            composer.typeText(phrase)
            XCTAssertTrue(send.waitForExistence(timeout: 4))
            shot("text-before-send-\(index)")
            send.tap()
            let bubble = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@ AND value CONTAINS %@", "Вы", phrase)).firstMatch
            XCTAssertTrue(bubble.waitForExistence(timeout: 4))
            XCTAssertTrue(send.waitForNonExistence(timeout: 3))
            XCTAssertLessThanOrEqual(bubble.frame.maxY, composer.frame.minY + 5)
        }
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let from = history.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.58))
        let to = history.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.58))
        from.press(forDuration: 0.08, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        shot("text-after-send")
    }

    func testSignInAndRegistrationSwitchKeepsEmail() {
        app.launch()
        app.buttons["Вход"].tap()
        let email = app.textFields["Электронная почта"]
        XCTAssertTrue(email.waitForExistence(timeout: 4))
        let firstPosition = email.frame
        email.tap()
        email.typeText("player@example.com")
        let registration = app.scrollViews.buttons["Создайте его"].firstMatch
        if !registration.isHittable { app.swipeUp() }
        registration.tap()
        let name = app.textFields["Имя"]
        XCTAssertTrue(name.waitForExistence(timeout: 4))
        XCTAssertEqual(email.value as? String, "player@example.com")
        XCTAssertEqual(email.frame.minX, firstPosition.minX, accuracy: 1)
        XCTAssertGreaterThan(email.frame.minY, name.frame.maxY)
        shot("registration-email")
        app.buttons["Войдите"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 4))
        XCTAssertEqual(email.value as? String, "player@example.com")
        XCTAssertEqual(email.frame.minX, firstPosition.minX, accuracy: 1)
        shot("signin-email")
    }

    private func openTraining(_ date: String) {
        let button = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", date)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 4))
        button.tap()
        XCTAssertTrue(app.navigationBars["Тренировка"].waitForExistence(timeout: 4))
    }

    private func openAndReturnFromChat() {
        app.buttons["Написать в поддержку"].firstMatch.tap()
        let support = app.navigationBars["Поддержка"]
        XCTAssertTrue(support.waitForExistence(timeout: 4))
        XCTAssertTrue(app.textFields["support.composer"].isHittable)
        XCTAssertTrue(app.buttons["support.removeTopic"].isHittable)
        support.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Тренировка"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Закрыть"].isHittable)
        XCTAssertFalse(app.buttons["profile.edit"].isHittable)
    }

    private func checkContent(_ prefix: String, above button: XCUIElement) {
        let text = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 4), prefix)
        XCTAssertTrue(text.isHittable)
        XCTAssertTrue(button.isHittable)
        XCTAssertLessThan(text.frame.maxY, button.frame.minY)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
