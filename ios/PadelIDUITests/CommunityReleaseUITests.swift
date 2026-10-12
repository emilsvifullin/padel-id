import XCTest

@MainActor
final class CommunityReleaseUITests: PadelIDUITestCase {
    private let chatID = "df0340e8-cf65-476c-83f0-6a7068cde8af"

    func testClubNewsRequestsScopedFeedAndPreservesClubNavigation() throws {
        let post = try JSONSerialization.data(withJSONObject: newsPost)
        let page = try JSONSerialization.data(withJSONObject: ["items": [newsPost]])
        let club = try JSONSerialization.data(withJSONObject: newsClub)
        try launch(.existingUser) { server in
            server.setOverride("GET", "v1/clubs/1", .json(club))
            server.setOverride("GET", "v1/social/feed", .json(page))
            for id in [newsPostID, UUID(uuidString: newsPostID)!.uuidString] {
                server.setOverride("GET", "v1/social/posts/" + id, .json(post))
                server.setOverride("GET", "v1/social/posts/" + id + "/comments", .json(Data("{\"items\":[]}".utf8)))
            }
        }
        signIn(); waitForHome(); selectTab("Клубы")
        open(row("clubs.row", containing: newsClubName, timeout: 15), screen: "Клуб")
        open(element("club.news"), screen: "Новости клуба")
        XCTAssertTrue(waitUntil(timeout: 10) {
            server.recorded("GET", "v1/social/feed").contains { $0.query["club_id"] == "1" }
        })
        XCTAssertFalse(element("feed.publish").exists, "Readers cannot publish club news")
        require(element("post.club"), "persisted club attribution")
        open(element("feed.post"), screen: "Публикация")
        require(element("post.club"), "attribution survives opening the news")
        goBack(previousTitle: "Новости клуба")
        goBack(previousTitle: "Клуб")
        requireScreen("Клуб")
        XCTAssertTrue(server.recorded("POST", "v1/social/posts").isEmpty)
    }

    func testClubNewsPublicationKeepsClubAndIdentityDuringUncertainRetry() throws {
        let bundle = Bundle(for: Self.self)
        let fixture = try XCTUnwrap(bundle.url(forResource: "me", withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "me", withExtension: "json"))
        var me = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        me["is_admin"] = true
        let meData = try JSONSerialization.data(withJSONObject: me)
        let club = try JSONSerialization.data(withJSONObject: newsClub)
        try launch(.existingUser) { server in
            server.setOverride("GET", "v1/me", .json(meData))
            server.setOverride("GET", "v1/clubs/1", .json(club))
            server.setOverride("GET", "v1/social/feed", .json(Data("{\"items\":[]}".utf8)))
            server.setOverride("POST", "v1/social/posts", .serviceUnavailable)
        }
        signIn(); waitForHome(); selectTab("Клубы")
        open(row("clubs.row", containing: newsClubName, timeout: 15), screen: "Клуб")
        open(element("club.news"), screen: "Новости клуба")
        open(element("feed.publish"), screen: "Новость клуба")
        let draft = require(element("post.draft"))
        enter("Субботний турнир", into: draft)
        tap(element("post.publish"))
        require(app.staticTexts["Сервис временно недоступен. Попробуйте через минуту."])
        XCTAssertFalse(draft.isEnabled)
        let uncertain = try XCTUnwrap(server.recorded("POST", "v1/social/posts").last)
        XCTAssertEqual(uncertain.jsonObject?["club_id"] as? Int, 1)
        XCTAssertEqual(uncertain.jsonObject?["visibility"] as? String, "public")
        let confirmed = try JSONSerialization.data(withJSONObject: newsPost)
        server.setOverride("POST", "v1/social/posts", .json(confirmed, status: 201))
        server.setOverride("GET", "v1/social/feed", .json(try JSONSerialization.data(withJSONObject: ["items": [newsPost]])))
        tap(element("post.publish"))
        requireScreen("Новости клуба")
        require(element("post.club"), timeout: 15, "server-confirmed news attribution")
        let repeated = try XCTUnwrap(server.recorded("POST", "v1/social/posts").last)
        XCTAssertNotNil(uncertain.header("Idempotency-Key"))
        XCTAssertEqual(repeated.header("Idempotency-Key"), uncertain.header("Idempotency-Key"))
        XCTAssertEqual(repeated.body, uncertain.body)
        XCTAssertEqual(repeated.jsonObject?["club_id"] as? Int, 1)
        snap("club-news-confirmed")
    }

    private let newsClubName = "Падел Арена Лужники"
    private let newsPostID = "64d3052d-1641-462c-bb5f-2cf1aa20e33d"
    private var newsClub: [String: Any] {
        ["id": 1, "name": newsClubName, "city_id": 1, "city_name": "Москва", "players_count": 5,
         "description": "Новости и игры клуба", "address": "Москва, Лужники", "latitude": NSNull(), "longitude": NSNull(),
         "photo_urls": [], "amenities": [], "metadata_version": 1, "courts_count": 0, "courts": [], "viewer": ["can_edit": false]]
    }
    private var newsPost: [String: Any] {
        ["id": newsPostID, "author": ["id": StubServer.currentUserID, "username": "m_orlov", "display_name": "Михаил Орлов",
            "deleted": false, "is_coach": false], "body": "Субботний турнир", "visibility": "public", "club_id": 1,
         "club": ["id": 1, "name": newsClubName], "created_at": "2026-10-12T08:00:00Z", "reaction_count": 0, "comment_count": 0]
    }

    func testRejectedPublicationCanBeCorrectedAndUncertainRetryKeepsIdentity() throws {
        try launch(.existingUser) { server in
            server.setOverride("GET", "v1/social/feed", .json(Data("{\"items\":[]}".utf8)))
            server.setOverride("POST", "v1/social/posts", .error(400, code: "invalid_request", message: "Исправьте публикацию."))
        }
        signIn(); waitForHome(); selectTab("Сообщество")
        open(element("community.feed"), screen: "Лента")
        tap(button(label: "Публикация"))
        let draft = require(element("post.draft"))
        enter("Первый текст", into: draft)
        tap(element("post.publish"))
        require(app.staticTexts["Исправьте публикацию."])
        XCTAssertTrue(draft.isEnabled)
        let rejected = try XCTUnwrap(server.recorded("POST", "v1/social/posts").last)
        // Editing the rejected draft starts a new semantic submission. A later
        // ambiguous server failure must retain that exact body/key for retry.
        enter("Исправленный текст", into: draft)
        server.setOverride("POST", "v1/social/posts", .serviceUnavailable)
        tap(element("post.publish"))
        require(app.staticTexts["Сервис временно недоступен. Попробуйте через минуту."])
        XCTAssertFalse(draft.isEnabled)
        let uncertain = try XCTUnwrap(server.recorded("POST", "v1/social/posts").last)
        XCTAssertNotEqual(rejected.header("Idempotency-Key"), uncertain.header("Idempotency-Key"))
        tap(element("post.publish"))
        XCTAssertTrue(waitUntil {
            server.recorded("POST", "v1/social/posts").count >= 3
        })
        let repeated = try XCTUnwrap(server.recorded("POST", "v1/social/posts").last)
        XCTAssertEqual(repeated.header("Idempotency-Key"), uncertain.header("Idempotency-Key"))
        XCTAssertEqual(repeated.body, uncertain.body)
        XCTAssertTrue(element("post.publish").exists)
    }

    func testChatRequiresServerConfirmationAndRetriesSameSubmission() throws {
        let chatPath = "v1/conversations/\(chatID)"
        let player: [String: Any] = ["id": StubServer.partnerID, "username": "d_sokolov", "display_name": "Дмитрий Соколов",
                                     "deleted": false, "is_coach": false]
        let conversation: [String: Any] = ["id": chatID, "kind": "direct", "title": "Дмитрий Соколов", "visibility": "private",
            "created_at": "2026-10-10T10:00:00Z", "updated_at": "2026-10-10T10:00:00Z", "members": [["player":player,"role":"member"]], "unread_count":0]
        try launch(.existingUser) { server in
            server.setOverride("GET", "v1/conversations", .json(try! JSONSerialization.data(withJSONObject: ["items":[conversation]])))
            server.setOverride("GET", chatPath, .json(try! JSONSerialization.data(withJSONObject: conversation)))
            server.setOverride("GET", chatPath + "/messages", .json(Data("{\"items\":[]}".utf8)))
            server.setOverride("POST", chatPath + "/read", .noContent)
            server.setOverride("POST", chatPath + "/messages", .serviceUnavailable)
        }
        signIn(); waitForHome(); selectTab("Сообщество")
        open(element("community.chats"), screen: "Сообщения")
        open(button(labelPrefix: "Дмитрий Соколов"), screen: "Дмитрий Соколов")
        let draft = require(element("chat.draft"))
        enter("Играем завтра?", into: draft)
        tap(element("chat.send"))
        waitForRequest("POST", chatPath + "/messages")
        require(app.staticTexts["Сервис временно недоступен. Попробуйте через минуту."])
        XCTAssertEqual(draft.value as? String, "Играем завтра?")
        XCTAssertFalse(app.staticTexts["Играем завтра?"].exists)
        let message: [String: Any] = ["id":1,"conversation_id":chatID,"sender":player,"body":"Играем завтра?",
            "created_at":"2026-10-10T10:01:00Z","client_id":"d9023856-5ab7-4922-b508-6f6773c3a134","deleted":false]
        server.setOverride("POST", chatPath + "/messages", .json(try JSONSerialization.data(withJSONObject: message), status:201))
        server.setOverride("GET", chatPath + "/messages", .json(try JSONSerialization.data(withJSONObject: ["items":[message], "latest_id":1])))
        tap(element("chat.send"))
        require(app.staticTexts["Играем завтра?"])
        let requests = server.recorded("POST", chatPath + "/messages")
        XCTAssertGreaterThanOrEqual(requests.count, 2)
        XCTAssertNotNil(requests.first?.header("Idempotency-Key"))
        XCTAssertEqual(Set(requests.compactMap { $0.header("Idempotency-Key") }).count, 1)
        XCTAssertTrue(requests.allSatisfy { $0.header("Authorization") != nil })
        snap("chat-confirmed")
    }

    func testAppearanceOffersThemesAndAllPreparedIcons() throws {
        try launch(.existingUser)
        dismissIconConfirmation()
        signIn(); waitForHome(); selectTab("Профиль")
        open(element("account.appearance"), screen: "Оформление")
        require(element("appearance.theme"))
        for title in ["Тёмная", "Светлая", "Автоматически"] {
            let option = require(button(label: title))
            tap(option)
            XCTAssertTrue(waitUntil { option.isSelected })
        }
        for icon in ["lime", "charcoal", "ball"] { scrollIntoView(element("appearance.icon." + icon)) }
        snap("appearance-icons")
        for icon in ["lime", "charcoal", "ball", "lime"] {
            let option = element("appearance.icon." + icon)
            scrollIntoView(option)
            tap(option)
            // UIKit may show its own confirmation after a successful change.
            dismissIconConfirmation()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            // Wait for UIKit completion before leaving the app. The system
            // alert and selected state can arrive before the operation ends.
            XCTAssertTrue(waitUntil(timeout: 30) {
                if springboard.alerts.firstMatch.exists {
                    springboard.alerts.firstMatch.buttons.firstMatch.tap()
                }
                return option.isEnabled && (option.value as? String) == "Выбрана"
            }, option.debugDescription)
            XCTAssertFalse(element("appearance.icon.error").exists)
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(springboard.icons["Padel ID"].waitForExistence(timeout: 10))
            let screenshot = XCTAttachment(screenshot: springboard.screenshot())
            screenshot.name = "home-screen-icon-" + icon
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.activate()
        }
        // Selected state comes from UIApplication.alternateIconName, including
        // after a cold relaunch; the production device check remains separate.
        app.terminate()
        app.launchArguments.removeAll { $0 == "-padelid-uitest-reset-state" }
        app.launch()
        // Keychain persistence depends on how the test app is signed. A cold
        // launch may restore the session or require authentication; both must
        // still preserve the icon selected through UIKit.
        XCTAssertTrue(waitUntil(timeout: 20) {
            app.navigationBars["Главная"].exists || element("welcome.signIn").exists
        })
        if element("welcome.signIn").exists { signIn() }
        waitForHome(); selectTab("Профиль")
        open(element("account.appearance"), screen: "Оформление")
        scrollIntoView(element("appearance.icon.lime"))
        XCTAssertEqual(element("appearance.icon.lime").value as? String, "Выбрана")
    }

    private func dismissIconConfirmation() {
        // The OS presents this alert in SpringBoard, outside the application.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 3) {
            springboard.alerts.firstMatch.buttons.firstMatch.tap()
        }
    }
}
