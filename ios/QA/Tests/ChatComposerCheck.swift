import XCTest

@MainActor
final class ChatComposerCheck: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "app.padelid.ios.preview")

    func testPhotoAttachmentsAndBubbleLayout() {
        checkPhotoAttachments()
    }

    private func checkPhotoAttachments() {
        app.launchArguments = ["-previewPlayerHome"]
        app.launch()
        app.tabBars.buttons["Настройки"].tap()
        app.buttons["Поддержка"].tap()
        let composer = app.textFields["support.composer"]
        let add = app.buttons["support.attach"]
        let send = app.buttons["support.send"]
        let gallery = app.descendants(matching: .any).matching(identifier: "support.galleryHandle").firstMatch
        let confirm = app.buttons["support.galleryConfirm"]
        let remove = app.buttons["support.removePhoto"]
        let photo = app.buttons["support.messagePhoto"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(hasMessage("Уточню по тренировке.").exists)
        XCTAssertFalse(send.exists)
        shot("01-bubbles")

        let history = app.scrollViews["support.history"]
        history.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.82))
            .press(forDuration: 0.04, thenDragTo: history.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82)))

        add.tap()
        let photos = app.buttons.matching(NSPredicate(format: "identifier == %@", "photo.on.rectangle")).firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 3))
        shot("02-attachment-menu")
        photos.tap()
        XCTAssertTrue(gallery.waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["Готово"].exists)
        XCTAssertFalse(confirm.exists)
        let disclosure = app.buttons.matching(NSPredicate(format: "label IN %@", ["Продолжить", "Continue", "OK", "ОК"])).firstMatch
        if disclosure.waitForExistence(timeout: 2) {
            disclosure.tap()
            XCTAssertTrue(disclosure.waitForNonExistence(timeout: 4))
        }
        shot("03-inline-gallery")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.77)).tap()
        XCTAssertTrue(remove.firstMatch.waitForExistence(timeout: 6))
        XCTAssertTrue(send.isHittable)
        shot("05-photo-draft")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.664))
            .press(forDuration: 0.04, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.34)))
        XCTAssertTrue(app.segmentedControls["Photos"].waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.isHittable)
        shot("04-expanded-gallery")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.40)).tap()
        confirm.tap()
        XCTAssertTrue(app.segmentedControls["Photos"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(gallery.exists)
        XCTAssertFalse(app.buttons["Готово"].exists)
        XCTAssertFalse(confirm.exists)
        XCTAssertTrue(remove.firstMatch.waitForExistence(timeout: 4))
        XCTAssertEqual(app.buttons.matching(identifier: "support.removePhoto").count, 2)
        shot("10-confirmed-gallery")
        send.tap()
        XCTAssertTrue(gallery.waitForNonExistence(timeout: 4))
        XCTAssertTrue(photo.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(send.exists)
        shot("06-photo-message")
        photo.firstMatch.tap()
        let close = app.buttons["Закрыть"]
        XCTAssertTrue(close.waitForExistence(timeout: 4))
        close.tap()

        app.terminate()
        app.launch()
        app.tabBars.buttons["Настройки"].tap()
        app.buttons["Поддержка"].tap()
        XCTAssertTrue(photo.firstMatch.waitForExistence(timeout: 5))
        let latestReply = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value CONTAINS %@ AND label == %@", "Получили ваше сообщение", "Клуб"))
            .firstMatch
        XCTAssertTrue(latestReply.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(latestReply.frame.height, 30)
        XCTAssertLessThan(latestReply.frame.maxY, composer.frame.minY)
        shot("07-photo-after-relaunch")

        composer.tap()
        composer.typeText("Фото корта")
        XCTAssertTrue(send.isHittable)
        add.tap()
        photos.tap()
        XCTAssertTrue(gallery.waitForExistence(timeout: 4))
        shot("09-gallery-with-caption")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.78)).tap()
        if !remove.firstMatch.waitForExistence(timeout: 3) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.78)).tap()
        }
        XCTAssertTrue(remove.firstMatch.waitForExistence(timeout: 6))
        shot("08-caption-and-photo")
        remove.firstMatch.tap()
        XCTAssertFalse(remove.exists)
        XCTAssertEqual(composer.value as? String, "Фото корта")
        XCTAssertTrue(send.isHittable)
        send.tap()
        XCTAssertTrue(gallery.waitForNonExistence(timeout: 3))
        XCTAssertTrue(hasMessage("Фото корта").waitForExistence(timeout: 4))
        XCTAssertTrue(send.waitForNonExistence(timeout: 2))
    }

    private func hasMessage(_ text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text))
            .firstMatch
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
