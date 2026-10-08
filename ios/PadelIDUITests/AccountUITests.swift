import XCTest

/// Account & settings sheet: profile editing, security, the rating
/// explanation and account deletion.
@MainActor
final class AccountUITests: PadelIDUITestCase {
    func testAccountScreens() throws {
        try launch(.existingUser)
        signIn()
        waitForHome()

        tap("home.account")
        requireScreen("Аккаунт")
        let editProfile = require(element("account.editProfile"), "account.editProfile")
        snap("account")

        // Profile
        tap(editProfile)
        requireScreen("Профиль")
        snap("edit-profile")
        goBack(previousTitle: "Аккаунт")
        requireScreen("Аккаунт")

        // Security
        tap(element("account.security"))
        requireScreen("Безопасность")
        snap("security")
        goBack(previousTitle: "Аккаунт")
        requireScreen("Аккаунт")

        // How the rating works
        tap(aboutRatingRow())
        requireScreen("Рейтинг и Padel DNA")
        snap("about-rating")
        goBack(previousTitle: "Аккаунт")
        requireScreen("Аккаунт")

        // Account deletion (only opened, never confirmed)
        tap(element("account.deleteAccount"))
        requireScreen("Удаление аккаунта")
        snap("delete-account")
        goBack(previousTitle: "Аккаунт")
        requireScreen("Аккаунт")

        let done = try XCTUnwrap(firstHittable(app.buttons.matching(NSPredicate(format: "label == %@", "Готово"))),
                                 "Готово is not reachable in the account sheet")
        done.tap()
        waitForDisappearance(done, "account sheet")
        waitForHome()

        XCTAssertTrue(server.recorded("PATCH", "v1/me").isEmpty, "Opening the profile must not save it")
        XCTAssertTrue(server.recorded("DELETE", "v1/account").isEmpty, "The account must not be deleted")
    }

    /// «Как устроены рейтинг и Padel DNA».
    private func aboutRatingRow() -> XCUIElement {
        let byIdentifier = element("account.aboutRating")
        if byIdentifier.exists {
            return byIdentifier
        }
        return button(labelPrefix: "Как устроены рейтинг")
    }
}
