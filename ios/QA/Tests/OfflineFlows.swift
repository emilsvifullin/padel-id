import XCTest

@MainActor
final class OfflineFlows: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    let app = XCUIApplication(bundleIdentifier: "app.padelid.ios.preview")

    func testFirstLaunchSignInAndSchedule() {
        app.launch()
        shot("welcome")
        tap("Вход")
        enter("player@example.com", in: app.textFields["Электронная почта"])
        enter("Wrong123", in: app.secureTextFields["Пароль"])
        tap("Войти")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Неверная электронная почта или пароль")).firstMatch.waitForExistence(timeout: 4))
        let field = app.secureTextFields["Пароль"]
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Wrong123".count))
        field.typeText("Tennis123")
        tap("Войти")
        XCTAssertTrue(app.staticTexts["Вы уже тренировались в MatchPoint?"].waitForExistence(timeout: 4))
        let dismissPasswordSave = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Not Now"].firstMatch
        let dismissInApp = app.buttons["Not Now"].firstMatch
        if dismissInApp.exists {
            dismissInApp.tap()
        } else if dismissPasswordSave.waitForExistence(timeout: 2) {
            dismissPasswordSave.tap()
        } else if !app.buttons["Да, занимаюсь сейчас"].isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: 0.61)).tap()
        }
        shot("history-before")
        tapVisibleCenter("Да, занимаюсь сейчас")
        shot("history-after")
        let continueButton = app.buttons["Продолжить"].firstMatch
        XCTAssertTrue(continueButton.isEnabled)
        shot("history-selection")
        tapVisibleCenter("Продолжить")
        XCTAssertTrue(app.staticTexts["Вы в группе"].waitForExistence(timeout: 4))
        shot("active-group")
        tapVisibleCenter("К расписанию")
        XCTAssertTrue(app.tabBars.buttons["Расписание"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.tabBars.buttons["Расписание"].isSelected)
        shot("schedule-from-login")
    }

    func testQuestionnaire() {
        app.launchArguments = ["-previewOnboarding"]
        app.launch()
        tap("Нет, я впервые")
        tap("Продолжить")
        tap("Начать")
        for (index, option) in [
            "Начинающий", "Ещё ни разу не играл",
            "Только учусь подавать или часто допускаю двойные ошибки",
            "В спокойном темпе часто ошибаюсь после нескольких ударов",
            "Ещё не пробовал или часто ошибаюсь даже на спокойной подаче",
            "Редко выхожу к сетке или часто ошибаюсь с лёта"
        ].enumerated() {
            XCTAssertTrue(app.staticTexts["Шаг \(index + 1) из 6"].waitForExistence(timeout: 4))
            tap(option)
            tap(index == 5 ? "Показать результат" : "Продолжить")
        }
        XCTAssertTrue(app.staticTexts["Предварительный уровень"].waitForExistence(timeout: 4))
        shot("assessment-result")
        tap("Продолжить")
        XCTAssertTrue(app.staticTexts["Пробная тренировка"].waitForExistence(timeout: 4))
    }

    func testRegistrationAndPasswordRecovery() {
        app.launch()
        tap("Создайте его")
        enter("Алексей", in: app.textFields["Имя"])
        enter("Смирнов", in: app.textFields["Фамилия"])
        enter("player@example.com", in: app.textFields["Электронная почта"])
        tap("Показать пароль")
        enter("Offline123", in: app.textFields["Пароль"])
        XCTAssertEqual(app.textFields["Пароль"].value as? String, "Offline123")
        shot("registration-before-submit")
        tap("Создать аккаунт")
        shot("registration-after-submit")
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "подтвердите регистрацию")).firstMatch.waitForExistence(timeout: 4))
        app.alerts.buttons.firstMatch.tap()
        tap("Меню проверки")
        tap("Подтвердить почту")
        XCTAssertTrue(app.staticTexts["Вы уже тренировались в MatchPoint?"].waitForExistence(timeout: 4))

        app.terminate()
        app.launch()
        tap("Вход")
        tap("Забыли пароль?")
        enter("player@example.com", in: app.textFields["Электронная почта"])
        tap("Отправить ссылку")
        shot("recovery-after-request")
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "ссылка для сброса пароля")).firstMatch.waitForExistence(timeout: 4))
        app.alerts.buttons.firstMatch.tap()
        tap("Меню проверки")
        tap("Открыть ссылку сброса пароля")
        tap("Показать пароль")
        enter("Recovered123", in: app.textFields["Новый пароль"])
        XCTAssertEqual(app.textFields["Новый пароль"].value as? String, "Recovered123")
        tap("Сохранить пароль")
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Пароль обновлён")).firstMatch.waitForExistence(timeout: 4))
    }

    func testFirstPaymentRejectedThenConfirmed() {
        app.launchArguments = ["-previewTwoMonthPayment"]
        app.launch()
        let twoMonths = app.switches.containing(NSPredicate(format: "label BEGINSWITH %@", "Включить следующий месяц")).firstMatch
        XCTAssertTrue(twoMonths.waitForExistence(timeout: 5))
        twoMonths.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(twoMonths.value as? String, "1")
        shot("two-month-offer")
        tap("Оплатить по СБП")
        shot("payment-confirmation-dialog")
        tap("Отклонить")
        XCTAssertTrue(app.alerts["Оплата отклонена"].waitForExistence(timeout: 4))
        tap("Понятно")
        tap("Оплатить по СБП")
        tap("Подтвердить оплату")
        XCTAssertTrue(app.staticTexts["Оплата подтверждена"].waitForExistence(timeout: 4))
        shot("payment-success")
        tap("К расписанию")
        XCTAssertTrue(app.tabBars.buttons["Расписание"].waitForExistence(timeout: 4))
        app.tabBars.buttons["Абонемент"].tap()
        XCTAssertTrue(app.buttons["Вопрос по оплате"].waitForExistence(timeout: 4))
    }

    func testOverdueRenewalBlocksCheckout() {
        app.launchArguments = ["-previewOverdueRenewal"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Срок оплаты прошёл"].waitForExistence(timeout: 5))
        let checkout = app.buttons["Оплатить по СБП"]
        XCTAssertTrue(checkout.exists)
        XCTAssertFalse(checkout.isEnabled)
        XCTAssertFalse(app.staticTexts["Оплата подтверждена"].exists)
        shot("renewal-overdue")
    }

    func testOpenExistingScheduleWithoutPaying() {
        app.launchArguments = ["-previewRenewal"]
        app.launch()

        tap("Текущее расписание")
        XCTAssertTrue(app.tabBars.buttons["Расписание"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Оплата подтверждена"].exists)
        shot("renewal-existing-schedule")
        tap("К продлению")
        XCTAssertTrue(app.buttons["Оплатить по СБП"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Оплатить по СБП"].isEnabled)
    }

    func testRenewalAndReturn() {
        app.launchArguments = ["-previewRenewal"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Продление абонемента"].waitForExistence(timeout: 4))
        shot("renewal")
        tap("Оплатить по СБП")
        tap("Подтвердить оплату")
        tap("К расписанию")
        XCTAssertTrue(app.tabBars.buttons["Расписание"].waitForExistence(timeout: 4))
        tap("К продлению")
        XCTAssertTrue(app.staticTexts["Продление абонемента"].waitForExistence(timeout: 4))
    }

    func testCancellationAndMakeup() {
        app.launchArguments = ["-previewPlayerHome"]
        app.launch()
        let next = button(prefix: "Ближайшая тренировка")
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        // Choose the training on November 19, more than a day from the sample reference date.
        let lesson = button(prefix: "19 ноября")
        XCTAssertTrue(lesson.waitForExistence(timeout: 5), lesson.debugDescription)
        lesson.tap()
        tap("Отменить запись")
        tap("Подтвердить отмену")
        XCTAssertTrue(app.staticTexts["Доступна отработка"].waitForExistence(timeout: 5))
        tap("Закрыть")
        app.tabBars.buttons["Абонемент"].tap()
        let credit = button(prefix: "За 19 ноября")
        XCTAssertTrue(credit.waitForExistence(timeout: 5))
        credit.tap()
        let date = button(prefix: "20 ноября")
        XCTAssertTrue(date.waitForExistence(timeout: 4))
        date.tap()
        tap("Подтвердить запись")
        XCTAssertTrue(credit.waitForNonExistence(timeout: 5))
        app.tabBars.buttons["Расписание"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Отработка за 19 ноября")).firstMatch.waitForExistence(timeout: 4))
        shot("booked-makeup")
    }

    func testReplacementAfterClubCancellation() {
        app.launchArguments = ["-previewPlayerHome"]
        app.launch()
        let lesson = button(prefix: "23 ноября")
        XCTAssertTrue(lesson.waitForExistence(timeout: 5))
        lesson.tap()
        XCTAssertTrue(app.staticTexts["Даты замены"].waitForExistence(timeout: 4))
        let date = button(prefix: "27 ноября")
        XCTAssertTrue(date.waitForExistence(timeout: 4))
        date.tap()
        tap("Подтвердить запись")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Замена за 23 ноября")).firstMatch.waitForExistence(timeout: 4))
        shot("booked-replacement")
    }

    private func button(prefix: String) -> XCUIElement {
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH[c] %@", prefix)).firstMatch
    }

    private func enter(_ value: String, in field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText(value)
    }

    private func tap(_ title: String) {
        let button = app.buttons[title].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), title)
        if !button.isHittable { app.swipeUp() }
        button.tap()
    }

    private func tapVisibleCenter(_ title: String) {
        let control = app.buttons[title].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5), title)
        let frame = control.frame
        let screen = app.frame
        print("QA tap center", title, frame, screen, control.isHittable)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - screen.minX, dy: frame.midY - screen.minY)).tap()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
