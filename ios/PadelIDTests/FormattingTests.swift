import Foundation
import Testing
@testable import PadelID

nonisolated private struct FormattingStamp: Codable, Equatable {
    let at: Date
}

@MainActor
@Suite("Formatting and JSON coding")
struct FormattingTests {
    private let minus = "\u{2212}"

    @Test("Level always has two decimals")
    func level() {
        #expect(Format.level(3.7449) == "3.74")
        #expect(Format.level(3.745001) == "3.75")
        #expect(Format.level(4) == "4.00")
        #expect(Format.level(0) == "0.00")
        #expect(Format.level(nil) == "—")
    }

    @Test("Delta signs use plus and the minus sign U+2212")
    func delta() {
        #expect(Format.delta(0.07) == "+0.07")
        #expect(Format.delta(-0.03) == "\(minus)0.03")
        #expect(Format.delta(0) == "0.00")
        #expect(Format.delta(-0.001) == "0.00")
        #expect(Format.delta(0.004) == "0.00")
        #expect(Format.delta(0.1234, digits: 3) == "+0.123")
        #expect(Format.delta(-1.5, digits: 1) == "\(minus)1.5")
        #expect(Format.delta(nil) == "—")
        #expect(!Format.delta(-0.25).contains("-"))
    }

    @Test("Percent")
    func percent() {
        #expect(Format.percent(0.42) == "42%")
        #expect(Format.percent(1) == "100%")
        #expect(Format.percent(0) == "0%")
    }

    @Test("Russian plural forms")
    func plurals() {
        let cases: [(Int, String)] = [
            (0, "матчей"), (1, "матч"), (2, "матча"), (4, "матча"), (5, "матчей"), (11, "матчей"),
            (12, "матчей"), (14, "матчей"), (21, "матч"), (22, "матча"), (25, "матчей"), (101, "матч"),
            (111, "матчей"), (112, "матчей"), (122, "матча"),
        ]
        for (n, form) in cases {
            #expect(Format.plural(n, "матч", "матча", "матчей") == form, "\(n)")
        }
        #expect(Format.count(21, "день", "дня", "дней") == "21 день")
        #expect(Format.matches(1) == "1 матч")
        #expect(Format.matches(2) == "2 матча")
        #expect(Format.matches(5) == "5 матчей")
        #expect(Format.matches(11) == "11 матчей")
        #expect(Format.days(22) == "22 дня")
        #expect(Format.days(25) == "25 дней")
        #expect(Format.days(111) == "111 дней")
    }

    @Test("Set scores with tie-break notation")
    func setScores() {
        let tiebreak = SetScore(t1: 7, t2: 6, superTiebreak: false, tb1: 7, tb2: 4)
        #expect(Format.setScore(tiebreak) == "7:6(4)")
        #expect(Format.setScore(tiebreak, perspective: 2) == "6:7(4)")
        #expect(Format.setScore(SetScore(t1: 6, t2: 3)) == "6:3")
        #expect(Format.setScore(SetScore(t1: 6, t2: 3), perspective: 2) == "3:6")
        #expect(Format.setScore(SetScore(t1: 8, t2: 10, superTiebreak: true)) == "8:10")
        let sets = [SetScore(t1: 6, t2: 4), SetScore(t1: 6, t2: 7, superTiebreak: false, tb1: 5, tb2: 7)]
        #expect(Format.score(sets) == "6:4 6:7(5)")
        #expect(Format.score(sets, perspective: 2) == "4:6 7:6(5)")
    }

    @Test("Relative day")
    func relativeDay() throws {
        let now = Date()
        let calendar = Calendar.current
        #expect(Format.relativeDay(now) == "Сегодня")
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))
        #expect(Format.relativeDay(yesterday) == "Вчера")
        let threeDaysAgo = try #require(calendar.date(byAdding: .day, value: -3, to: now))
        #expect(Format.relativeDay(threeDaysAgo) == "3 дня назад")
        let monthAgo = try #require(calendar.date(byAdding: .day, value: -40, to: now))
        #expect(Format.relativeDay(monthAgo) == Format.shortDate(monthAgo))
    }

    @Test("String.capitalizedFirst")
    func capitalizedFirst() {
        #expect("сегодня".capitalizedFirst == "Сегодня")
        #expect("".capitalizedFirst == "")
    }

    // MARK: JSONCoding.parseDate

    private let reference = Date(timeIntervalSince1970: 1_791_413_583) // 2026-10-07T22:53:03Z

    private func parsed(_ raw: String) throws -> Date {
        try #require(JSONCoding.parseDate(raw), "\(raw) should parse")
    }

    @Test("Dates with 0, 1, 3 and 6 fractional digits")
    func fractionalSeconds() throws {
        let whole = try parsed("2026-10-07T22:53:03Z")
        #expect(whole == reference)
        let tenth = try parsed("2026-10-07T22:53:03.1Z")
        #expect(abs(tenth.timeIntervalSince(reference) - 0.1) < 0.0005)
        let millis = try parsed("2026-10-07T22:53:03.123Z")
        #expect(abs(millis.timeIntervalSince(reference) - 0.123) < 0.0005)
        let micros = try parsed("2026-10-07T22:53:03.123456Z")
        #expect(abs(micros.timeIntervalSince(reference) - 0.123) < 0.0011)
    }

    @Test("Dates with +00:00 offsets, as PostgreSQL writes them")
    func offsets() throws {
        let whole = try parsed("2026-10-07T22:53:03+00:00")
        #expect(whole == reference)
        let half = try parsed("2026-10-07T22:53:03.5+00:00")
        #expect(abs(half.timeIntervalSince(reference) - 0.5) < 0.0005)
        let micros = try parsed("2026-10-07T22:53:03.123456+00:00")
        #expect(abs(micros.timeIntervalSince(reference) - 0.123) < 0.0011)
    }

    @Test("Plain dates and garbage")
    func plainDates() throws {
        let day = try parsed("2026-10-07")
        #expect(day == Date(timeIntervalSince1970: 1_791_331_200))
        #expect(JSONCoding.parseDate("not a date") == nil)
        #expect(JSONCoding.parseDate("") == nil)
    }

    @Test("The decoder accepts the server's timestamps; the encoder round-trips")
    func coderDates() throws {
        let decoded = try JSONCoding.decoder.decode(FormattingStamp.self,
                                                    from: Data(#"{"at": "2026-10-07T22:53:03.123456+00:00"}"#.utf8))
        #expect(abs(decoded.at.timeIntervalSince(reference) - 0.123) < 0.0011)
        let encoded = try JSONCoding.encoder.encode(FormattingStamp(at: reference))
        let roundTrip = try JSONCoding.decoder.decode(FormattingStamp.self, from: encoded)
        #expect(roundTrip == FormattingStamp(at: reference))
        #expect(throws: DecodingError.self) {
            _ = try JSONCoding.decoder.decode(FormattingStamp.self, from: Data(#"{"at": "yesterday"}"#.utf8))
        }
    }

    // MARK: JSONValue

    @Test("JSONValue decodes, reads and round-trips")
    func jsonValueRoundTrip() throws {
        let raw = #"{"a": 1, "b": "x", "c": [true, null, 2.5], "d": {"e": -3}, "f": false}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
        #expect(value["a"]?.int == 1)
        #expect(value["a"]?.double == 1)
        #expect(value["b"]?.string == "x")
        #expect(value["b"]?.double == nil)
        #expect(value["c"]?.array?.count == 3)
        #expect(value["c"]?.array?.first?.bool == true)
        #expect(value["c"]?.array?[1].isNull == true)
        #expect(value["c"]?.array?.last?.double == 2.5)
        #expect(value["d"]?["e"]?.int == -3)
        #expect(value["f"]?.bool == false)
        #expect(value["missing"] == nil)
        #expect(JSONValue.string("0.75").double == 0.75)

        let encoded = try JSONEncoder().encode(value)
        let again = try JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(again == value)
    }

    @Test("JSONValue re-decodes nested objects as models")
    func jsonValueDecodesModels() throws {
        let raw = #"{"player": {"id": "03eed36a-a8a4-4767-9dd6-b1f89bf7267b", "username": "m_orlov", "display_name": "Михаил Орлов", "deleted": false, "avatar_path": null, "city": {"id": 1, "name": "Москва"}, "club": null, "preferred_side": "right", "is_coach": false, "level": 4.49, "reliability": 47}}"#
        let values = try JSONCoding.decoder.decode([String: JSONValue].self, from: Data(raw.utf8))
        let card = try #require(values["player"]?.decode(PlayerCard.self))
        #expect(card.displayName == "Михаил Орлов")
        #expect(card.city?.id == 1)
        #expect(card.preferredSide == .right)
        #expect(card.level == 4.49)
    }
}
