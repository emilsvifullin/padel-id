import XCTest

@MainActor
final class RowFeedbackCheck: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "app.padelid.ios.preview")

    func testSystemAndPlayerSettingsPress() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        let general = settings.cells.containing(NSPredicate(format: "label IN %@", ["General", "Основные"])).firstMatch
        let generalRow = general.exists ? general : settings.staticTexts.matching(
            NSPredicate(format: "label IN %@", ["General", "Основные"])
        ).firstMatch
        if !generalRow.isHittable { settings.swipeUp() }
        XCTAssertTrue(generalRow.isHittable)
        generalRow.press(forDuration: 0.65)
        XCTAssertTrue(settings.navigationBars.matching(
            NSPredicate(format: "identifier IN %@", ["General", "Основные"])
        ).firstMatch.waitForExistence(timeout: 4))

        app.launchArguments = ["-previewPlayerHome"]
        app.launch()
        app.tabBars.buttons["Настройки"].tap()
        for title in ["Уведомления и звуки", "Поддержка"] {
            let row = app.buttons[title]
            XCTAssertTrue(row.isHittable)
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.5)).press(forDuration: 0.65)
            let bar = app.navigationBars[title]
            XCTAssertTrue(bar.waitForExistence(timeout: 4))
            bar.buttons.firstMatch.tap()
            XCTAssertTrue(row.isHittable)
        }
    }

    private func pressRow(_ label: String, at x: CGFloat) {
        let button = app.buttons[label]
        XCTAssertTrue(button.isHittable)
        button.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).press(forDuration: 0.45)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
