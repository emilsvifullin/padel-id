import XCTest

/// Account & settings sheet: profile editing, security, the rating
/// explanation and account deletion.
@MainActor
final class AccountUITests: PadelIDUITestCase {
    func testAccountScreens() throws {
        try launch(.existingUser)
        signIn()
        waitForHome()

        selectTab("Профиль")
        requireScreen("Профиль")
        let editProfile = require(element("account.editProfile"), "account.editProfile")
        snap("account")

        // Profile
        open(editProfile, screen: "Изменить профиль")
        snap("edit-profile")
        goBack(previousTitle: "Профиль")
        requireScreen("Профиль")

        // Security
        open(element("account.security"), screen: "Безопасность")
        snap("security")
        goBack(previousTitle: "Профиль")
        requireScreen("Профиль")

        // How the rating works
        open(aboutRatingRow(), screen: "Рейтинг и Padel DNA")
        snap("about-rating")
        goBack(previousTitle: "Профиль")
        requireScreen("Профиль")

        // Account deletion (only opened, never confirmed)
        open(element("account.deleteAccount"), screen: "Удаление аккаунта")
        snap("delete-account")
        goBack(previousTitle: "Профиль")
        requireScreen("Профиль")

        selectTab("Главная")
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
