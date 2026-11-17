import XCTest

@MainActor
final class SettingsFlowCheck: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "app.padelid.ios.preview")

    func testSettingsEditAndNotifications() {
        app.launchArguments = ["-previewPlayerHome"]
        app.launch()
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.buttons["Настройки"].waitForExistence(timeout: 5))
        XCTAssertEqual(bar.buttons.count, 3)
        bar.buttons["Настройки"].tap()

        let edit = app.buttons["profile.edit"]
        let menu = app.buttons["Меню проверки"]
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        XCTAssertLessThan(edit.frame.minY, 95)
        XCTAssertGreaterThan(edit.frame.midX, app.frame.midX)
        XCTAssertLessThan(menu.frame.midX, app.frame.midX)
        XCTAssertEqual(edit.frame.midY, menu.frame.midY, accuracy: 6)
        XCTAssertFalse(app.buttons["Выйти"].exists)
        shot("01-settings")

        edit.tap()
        let phone = app.textFields["profile.phone"]
        XCTAssertTrue(phone.waitForExistence(timeout: 4))
        XCTAssertFalse(bar.isHittable)
        XCTAssertFalse(menu.exists)
        XCTAssertTrue(app.buttons["Изменить фотографию"].isHittable)
        XCTAssertTrue(app.buttons["Выйти"].isHittable)
        shot("02-edit")

        let original = phone.value as? String ?? ""
        phone.tap()
        if original != "Телефон" {
            phone.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count))
        }
        phone.typeText("5550118")
        app.buttons["Отмена"].tap()
        XCTAssertTrue(edit.isHittable)
        edit.tap()
        XCTAssertEqual(phone.value as? String, original)

        phone.tap()
        if original != "Телефон" {
            phone.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count))
        }
        phone.typeText("5550108")
        app.buttons["Сохранить"].tap()
        XCTAssertTrue(edit.isHittable)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "5550108")).firstMatch.exists)

        edit.tap()
        phone.tap()
        phone.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7))
        if original != "Телефон" { phone.typeText(original) }
        app.buttons["Сохранить"].tap()
        XCTAssertTrue(edit.isHittable)

        app.buttons["Уведомления и звуки"].tap()
        let toggle = app.switches["Тренировки"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 4))
        XCTAssertFalse(bar.isHittable)
        let before = toggle.value as? String
        let switchControl = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        switchControl.tap()
        XCTAssertNotEqual(toggle.value as? String, before)
        shot("03-notifications")
        switchControl.tap()
        XCTAssertEqual(toggle.value as? String, before)
        goBack(from: "Уведомления и звуки")
        XCTAssertTrue(edit.isHittable)

        edit.tap()
        app.buttons["Выйти"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["Отмена"].tap()
        app.buttons["Выйти"].tap()
        alert.buttons["Выйти"].tap()
        XCTAssertFalse(edit.isHittable)
    }

    func testSupportFromSettingsAndMembership() {
        app.launchArguments = ["-previewPlayerHome"]
        app.launch()
        let bar = app.tabBars.firstMatch
        bar.buttons["Настройки"].tap()
        app.buttons["Поддержка"].tap()
        let composer = app.textFields["support.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertFalse(bar.isHittable)
        shot("04-support")
        goBack(from: "Поддержка")
        XCTAssertTrue(bar.buttons["Настройки"].isSelected)

        bar.buttons["Абонемент"].tap()
        app.buttons["Вопрос по оплате"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["support.removeTopic"].exists)
        XCTAssertFalse(bar.isHittable)
        shot("05-support-context")
        app.buttons["support.removeTopic"].tap()
        goBack(from: "Поддержка")
        XCTAssertTrue(bar.buttons["Абонемент"].isSelected)
    }

    func testLargeSettings() {
        app.launchArguments = ["-previewPlayerHome", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        app.tabBars.buttons["Настройки"].tap()
        let edit = app.buttons["profile.edit"]
        XCTAssertTrue(edit.isHittable)
        shot("09-settings-large")
        edit.tap()
        XCTAssertTrue(app.textFields["profile.name"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        shot("10-edit-large")
        app.swipeUp()
        XCTAssertTrue(app.buttons["Выйти"].isHittable)
        app.buttons["Отмена"].tap()
        XCTAssertTrue(edit.isHittable)
    }

    private func goBack(from title: String) {
        let bar = app.navigationBars[title]
        XCTAssertTrue(bar.waitForExistence(timeout: 3), app.navigationBars.debugDescription)
        bar.buttons.firstMatch.tap()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
