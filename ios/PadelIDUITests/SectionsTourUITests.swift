import XCTest

/// Walks every section of the app and keeps a screenshot of each: once with
/// the account most players have, once with the worst data a real account can
/// hold — long names and titles, counts of one and of thousands, missing
/// fields. The screenshots are what a release is reviewed against.
@MainActor
final class SectionsTourUITests: PadelIDUITestCase {
    func testEverySectionWithTypicalData() throws { try tour(worst: false) }
    func testEverySectionWithWorstCaseData() throws { try tour(worst: true) }

    private let chatID = "df0340e8-cf65-476c-83f0-6a7068cde8af"
    private let postID = "64d3052d-1641-462c-bb5f-2cf1aa20e33d"
    private let tournamentID = "f8e49ac8-4f8c-4d88-8b6e-cb7ff3198a30"

    private func tour(worst: Bool) throws {
        func pick<Value>(_ typical: Value, _ worstCase: Value) -> Value { worst ? worstCase : typical }
        let prefix = worst ? "worst" : "tour"

        func player(_ id: String, _ username: String, _ name: String, coach: Bool = false) -> [String: Any] {
            ["id": id, "username": username, "display_name": name, "deleted": false, "is_coach": coach]
        }
        let myName = pick("Михаил Орлов", "Александра Вишневская-Ковальчук")
        let me = player(StubServer.currentUserID, pick("m_orlov", "aleksandra_vishnevsk"), myName)
        let dimaName = pick("Дмитрий Соколов", "Константин Константинопольский-Задунайский")
        let dima = player(StubServer.partnerID, pick("d_sokolov", "konstantin_konstant"), dimaName, coach: true)
        let anna = player("72b11bd9-f270-4ae2-b104-25a132d48204", pick("anna_k", "yu"), pick("Анна Ковалёва", "Ю"))
        let igor = player("2becd560-4954-4ad9-ab50-e454ea8f2d73", "igor_p", pick("Игорь Павлов", "Максимилиан фон Штауффенберг"))
        let clubName = pick("Padel Friends", "Падел-клуб «Северная звезда» на Ленинградском проспекте")

        let posts: [[String: Any]] = [
            ["id": postID, "author": dima, "visibility": "public", "created_at": "2026-10-12T08:00:00Z",
             "body": pick("Собираю четвёрку на субботу в 10:00, Лужники, корт 2. Уровень 4.0–5.0, играем два часа. Нужен ещё один игрок слева.",
                          "Запись и подробности: https://severnaya-zvezda-padel-club.example.com/tournaments/autumn-open-2026/registration?source=padelid — "
                          + String(repeating: "собираем составы на все выходные до конца месяца, пишите в комментариях. ", count: 6)),
             "reaction_count": pick(12, 1284), "comment_count": pick(3, 1), "my_reaction": "like"],
            ["id": "7b0c6a52-0a5f-4a39-9f3e-0d6a5a3a1c11", "author": anna, "visibility": "public", "created_at": "2026-10-11T17:30:00Z",
             "body": pick("Первый турнир Americano позади: третье место и +0.18 к уровню. Спасибо всем, кто играл!", "Ок"),
             "reaction_count": pick(27, 0), "comment_count": pick(6, 0)],
            ["id": "0d8a1f2e-5b7c-4c1d-8e9f-3a2b1c0d9e8f", "author": igor, "visibility": "public", "club_id": 1,
             "club": ["id": 1, "name": clubName], "created_at": "2026-10-10T09:15:00Z",
             "body": "Открыли два новых корта с панорамным стеклом. Запись на вечерние слоты уже на сайте клуба.",
             "reaction_count": 8, "comment_count": 1],
        ]
        let comments: [[String: Any]] = [
            ["id": "a1a1a1a1-0000-4000-8000-000000000001", "post_id": postID, "author": anna,
             "body": pick("Я в деле, играю слева.", "👍"), "created_at": "2026-10-12T08:20:00Z"],
            ["id": "a1a1a1a1-0000-4000-8000-000000000002", "post_id": postID, "author": me,
             "body": "Отлично, тогда состав собран. Мячи беру я.", "created_at": "2026-10-12T08:31:00Z"],
        ]
        func message(_ id: Int, _ chat: String, _ sender: [String: Any], _ body: String, _ at: String) -> [String: Any] {
            ["id": id, "conversation_id": chat, "sender": sender, "body": body, "created_at": at,
             "client_id": "b2b2b2b2-0000-4000-8000-0000000000\(String(format: "%02d", id))", "deleted": false]
        }
        let groupChat = "c3c3c3c3-0000-4000-8000-000000000001", gameChat = "c3c3c3c3-0000-4000-8000-000000000002"
        let thread = [
            message(1, chatID, dima, "Привет! В субботу играем?", "2026-10-11T18:40:00Z"),
            message(2, chatID, me, pick("Да, в 10:00 в Лужниках. Корт уже забронирован.",
                                        "Да. Адрес: https://maps.example.com/moscow/leningradsky-prospekt/severnaya-zvezda-padel-club-entrance-b"),
                    "2026-10-11T18:42:00Z"),
            message(3, chatID, dima, "Супер. Я возьму новые мячи, ты — хорошее настроение.", "2026-10-12T09:03:00Z"),
            message(4, chatID, me, pick("Договорились 🎾", "Ок"), "2026-10-12T09:05:00Z"),
        ]
        let groupTitle = pick("Падел по выходным", "Любители падела Северо-Западного округа и Ленинградской области")
        let conversations: [[String: Any]] = [
            ["id": chatID, "kind": "direct", "title": dimaName, "visibility": "private", "created_at": "2026-10-10T10:00:00Z",
             "updated_at": "2026-10-12T09:05:00Z", "members": [["player": dima, "role": "member", "last_read_id": 2]], "unread_count": 0,
             "latest_message": thread[3]],
            ["id": groupChat, "kind": "group", "title": groupTitle, "visibility": "private", "created_at": "2026-10-01T10:00:00Z",
             "updated_at": "2026-10-12T08:40:00Z",
             "members": [["player": dima, "role": "owner"], ["player": anna, "role": "member"], ["player": igor, "role": "member"]],
             "unread_count": pick(3, 128), "latest_message": message(9, groupChat, anna, "Кто в воскресенье на утро?", "2026-10-12T08:40:00Z")],
            ["id": gameChat, "kind": "game", "title": "Игра 14 октября", "visibility": "private", "created_at": "2026-10-09T10:00:00Z",
             "updated_at": "2026-10-11T19:10:00Z", "members": [["player": anna, "role": "member"], ["player": igor, "role": "member"]],
             "unread_count": 0, "latest_message": message(10, gameChat, igor, "Буду за 15 минут до начала.", "2026-10-11T19:10:00Z")],
        ]
        var firstGroup: [String: Any] = ["id": "d4d4d4d4-0000-4000-8000-000000000001", "title": groupTitle, "visibility": "public",
                                         "city_id": 1, "owner_id": StubServer.partnerID, "member_count": pick(48, 1), "joined": true]
        if !worst { firstGroup["description"] = "Собираем составы на субботу и воскресенье" }
        let groups: [[String: Any]] = [
            firstGroup,
            ["id": "d4d4d4d4-0000-4000-8000-000000000002", "title": "Новички Москвы", "description": "Первые игры, уровень до 3.0",
             "visibility": "public", "city_id": 1, "owner_id": StubServer.partnerID, "member_count": pick(126, 12_840), "joined": false],
            ["id": "d4d4d4d4-0000-4000-8000-000000000003", "title": "Americano по средам", "description": "Еженедельный мини-турнир",
             "visibility": "public", "city_id": 1, "owner_id": StubServer.partnerID, "member_count": 31, "joined": false],
        ]
        let tournamentTitle = pick("Осенний Americano", "Открытый осенний турнир клуба «Северная звезда» памяти основателей")
        let notifications: [[String: Any]] = [
            ["id": "e5e5e5e5-0000-4000-8000-000000000001", "kind": "message", "title": pick("Анна Ковалёва", "Ю") + ": Кто в воскресенье на утро?",
             "resource_id": groupChat, "created_at": "2026-10-12T08:40:00Z"],
            ["id": "e5e5e5e5-0000-4000-8000-000000000002", "kind": "game_invite", "title": dimaName + " приглашает вас в игру 14 октября",
             "created_at": "2026-10-12T08:05:00Z"],
            ["id": "e5e5e5e5-0000-4000-8000-000000000003", "kind": "reaction", "title": "Игорь Павлов оценил вашу публикацию",
             "resource_id": postID, "created_at": "2026-10-11T18:00:00Z", "read_at": "2026-10-11T19:00:00Z"],
            ["id": "e5e5e5e5-0000-4000-8000-000000000004", "kind": "match", "title": "Результат матча подтверждён всеми игроками",
             "created_at": "2026-10-10T21:00:00Z", "read_at": "2026-10-11T09:00:00Z"],
            ["id": "e5e5e5e5-0000-4000-8000-000000000005", "kind": "event", "title": "Открыта запись на " + tournamentTitle,
             "created_at": "2026-10-09T12:00:00Z", "read_at": "2026-10-09T13:00:00Z"],
        ]
        func game(_ n: Int, _ round: Int, _ a: [[String: Any]], _ b: [[String: Any]], _ score: (Int, Int)?, _ done: Bool) -> [String: Any] {
            var value: [String: Any] = ["id": "f6f6f6f6-0000-4000-8000-0000000000\(String(format: "%02d", n))", "round": round, "court": 1,
                                        "team1": a, "team2": b, "version": 1, "confirmed": done, "confirmations": []]
            if let score { value["points1"] = score.0; value["points2"] = score.1 }
            return value
        }
        func standing(_ n: Int, _ player: [String: Any], _ points: Int, _ wins: Int, _ difference: Int) -> [String: Any] {
            ["id": "f7f7f7f7-0000-4000-8000-0000000000\(String(format: "%02d", n))", "rank": n, "points": points, "played": 2,
             "wins": wins, "point_difference": difference, "players": [player]]
        }
        let tournament: [String: Any] = ["id": tournamentID, "kind": "tournament", "format": "americano", "title": tournamentTitle,
            "description": "Три раунда по 32 очка, пары меняются каждый раунд", "organizer": dima, "starts_at": "2026-10-13T16:00:00Z",
            "duration_minutes": 120, "city": ["id": 1, "name": pick("Москва", "Петропавловск-Камчатский")],
            "club": ["id": 1, "name": clubName], "location": pick("Корты 1 и 2", "Крытые корты 1, 2 и 7, вход со двора через шлагбаум"),
            "capacity": 8, "min_level": 3.5, "max_level": 5.5, "round_count": 3, "points_per_game": 32, "current_round": 2,
            "status": "running", "registered_count": pick(4, 1), "viewer": ["is_organizer": false, "registration": "accepted"], "registrations": [],
            "games": [game(1, 1, [me, dima], [anna, igor], (20, 12), true), game(2, 2, [me, anna], [dima, igor], (17, 15), false),
                      game(3, 3, [me, igor], [dima, anna], nil, false)],
            "standings": [standing(1, me, pick(37, 1284), 2, 10), standing(2, dima, 35, 1, 6), standing(3, anna, 29, 1, -6),
                          standing(4, igor, pick(27, 0), 0, -10)]]
        var training: [String: Any] = ["id": "d6bedc42-afb7-4e16-908a-dc9e0f52b91c", "kind": "training", "format": "group",
            "title": pick("Игра у сетки: воллей и бандеха", "Т"), "description": "Групповая тренировка", "organizer": dima,
            "starts_at": "2099-10-18T08:00:00Z", "duration_minutes": 90, "city": ["id": 1, "name": "Москва"], "location": "Корт 2",
            "capacity": 4, "min_level": 3.0, "max_level": 5.0, "price_rub": pick(2500, 125_000), "round_count": 1, "points_per_game": 32,
            "current_round": 0, "status": "open", "registered_count": 3, "viewer": ["is_organizer": false], "registrations": [],
            "games": [], "standings": []]
        if !worst { training["club"] = ["id": 1, "name": clubName] }
        var mexicano = tournament
        mexicano["id"] = "f8e49ac8-4f8c-4d88-8b6e-cb7ff3198a31"; mexicano["format"] = "mexicano"; mexicano["title"] = "Mexicano выходного дня"
        mexicano["starts_at"] = "2099-10-25T09:00:00Z"; mexicano["status"] = "open"; mexicano["current_round"] = 0
        mexicano["registered_count"] = 6; mexicano["games"] = [[String: Any]](); mexicano["standings"] = [[String: Any]]()
        mexicano["viewer"] = ["is_organizer": false]

        func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
        // The worst account: the longest name the profile accepts, a city and
        // a club that do not fit one line, and clubs with every fact filled in.
        var me1 = try fixture("me"), home = try fixture("home")
        var clubs = try JSONSerialization.jsonObject(with: fixtureData("clubs")) as? [[String: Any]] ?? []
        if worst {
            for key in ["profile"] {
                var profile = me1[key] as? [String: Any] ?? [:]
                profile["display_name"] = myName; profile["username"] = "aleksandra_vishnevsk"
                profile["city"] = ["id": 1, "name": "Петропавловск-Камчатский"]; profile["club"] = ["id": 1, "name": clubName]
                me1[key] = profile
                var shown = home[key] as? [String: Any] ?? [:]
                shown["display_name"] = myName; shown["username"] = "aleksandra_vishnevsk"
                shown["city"] = ["id": 1, "name": "Петропавловск-Камчатский"]; shown["club"] = ["id": 1, "name": clubName]
                home[key] = shown
            }
            if !clubs.isEmpty {
                clubs[0]["name"] = clubName
                clubs[0]["address"] = "Ленинградский проспект, дом 36, строение 11, вход со стороны Петровского парка"
                clubs[0]["courts_count"] = 12; clubs[0]["players_count"] = 1284
                clubs[0]["amenities"] = ["Раздевалки и душевые", "Прокат ракеток", "Кафе"]
                clubs[0]["booking_url"] = "https://example.com/book"; clubs[0]["booking_verified_at"] = "2026-10-01T10:00:00Z"
            }
            if clubs.count > 1 { clubs[1]["name"] = "Я"; clubs[1]["players_count"] = 1; clubs[1]["courts_count"] = 1 }
        }
        try launch(.existingUser) { server in
            if worst {
                server.setOverride("GET", "v1/me", .json(json(me1)))
                server.setOverride("GET", "v1/home", .json(json(home)))
                server.setOverride("GET", "v1/clubs", .json(json(clubs)))
            }
            server.setOverride("GET", "v1/social/feed", .json(json(["items": posts])))
            for id in [self.postID, self.postID.uppercased()] {
                server.setOverride("GET", "v1/social/posts/" + id, .json(json(posts[0])))
                server.setOverride("GET", "v1/social/posts/" + id + "/comments", .json(json(["items": comments])))
            }
            server.setOverride("GET", "v1/conversations", .json(json(["items": conversations])))
            for id in [self.chatID, self.chatID.uppercased()] {
                server.setOverride("GET", "v1/conversations/" + id, .json(json(conversations[0])))
                server.setOverride("GET", "v1/conversations/" + id + "/messages", .json(json(["items": thread])))
                server.setOverride("POST", "v1/conversations/" + id + "/read", .noContent)
            }
            server.setOverride("GET", "v1/social/groups", .json(json(["items": groups])))
            server.setOverride("GET", "v1/notifications", .json(json(["items": notifications])))
            server.setOverride("GET", "v1/events", .json(json(["items": [tournament, training, mexicano]])))
            for id in [self.tournamentID, self.tournamentID.uppercased()] {
                server.setOverride("GET", "v1/events/" + id, .json(json(tournament)))
            }
        }
        signIn(); waitForHome()
        require(element("home.level"), timeout: 15, "home"); snap(prefix + "-01-home")
        drag(upwards: true); snap(prefix + "-02-home-more")
        selectTab("Матчи"); require(element("matches.events"), timeout: 15, "matches"); snap(prefix + "-03-matches")
        open(element("matches.upcoming"), screen: "Предстоящие игры"); snap(prefix + "-04-games")
        goBack(previousTitle: "Матчи")
        open(element("matches.events"), screen: "Тренировки и турниры"); snap(prefix + "-05-events")
        open(button(labelPrefix: tournamentTitle), screen: "Турнир"); snap(prefix + "-06-tournament")
        drag(upwards: true); snap(prefix + "-07-tournament-rounds")
        drag(upwards: true); snap(prefix + "-08-tournament-table")
        selectTab("Клубы"); require(element("clubs.row"), timeout: 15, "clubs"); snap(prefix + "-09-clubs")
        selectTab("Сообщество"); requireScreen("Сообщество")
        require(element("feed.post"), timeout: 15, "feed"); snap(prefix + "-10-community")
        open(element("community.chats"), screen: "Сообщения"); snap(prefix + "-11-chats")
        open(button(labelPrefix: dimaName), screen: dimaName); snap(prefix + "-12-chat")
        goBack(previousTitle: "Сообщения"); goBack(previousTitle: "Сообщество")
        open(element("community.groups"), screen: "Группы"); snap(prefix + "-13-groups")
        goBack(previousTitle: "Сообщество")
        open(element("community.inbox"), screen: "Уведомления"); snap(prefix + "-14-notifications")
        goBack(previousTitle: "Сообщество")
        drag(upwards: true); snap(prefix + "-15-feed")
        open(element("feed.post"), screen: "Публикация"); snap(prefix + "-16-post")
        goBack(previousTitle: "Сообщество")
        selectTab("Профиль"); require(element("account.appearance"), timeout: 15, "profile"); snap(prefix + "-17-profile")
        drag(upwards: true); snap(prefix + "-18-profile-more")
    }

    private func fixtureData(_ name: String) throws -> Data {
        let bundle = Bundle(for: StubServer.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "json"), "fixture " + name)
        return try Data(contentsOf: url)
    }

    private func fixture(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData(name)) as? [String: Any], "fixture " + name)
    }
}
