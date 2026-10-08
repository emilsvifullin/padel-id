import Foundation
import Testing
import UIKit
@testable import PadelID

/// Narratives turn the server's structured facts into Russian copy. Inputs are
/// decoded from JSON shaped exactly like the API output (snake_case keys), so
/// the tests cover the real decoding path.
@MainActor
@Suite("Narratives")
struct NarrativesTests {
    private func insight(_ json: String) throws -> Insight {
        try JSONCoding.decoder.decode(Insight.self, from: Data(json.utf8))
    }

    private func render(_ json: String) throws -> InsightText {
        let value = try insight(json)
        return try #require(Narratives.insight(value), "no text for \(value.kind)")
    }

    // MARK: Insights

    @Test("reliability_path")
    func reliabilityPath() throws {
        let text = try render(#"{"kind": "reliability_path", "sentiment": "neutral", "values": {"reliability": 42, "matches_needed": 3, "target": 70}}"#)
        #expect(text.title == "Надёжность рейтинга 42%")
        #expect(text.body.contains("Ещё 3 рейтинговых матча"))
        #expect(text.body.contains("70%"))
        #expect(text.sentiment == .neutral)
    }

    @Test("inactivity")
    func inactivity() throws {
        let text = try render(#"{"kind": "inactivity", "sentiment": "attention", "values": {"days": 25, "reliability": 55}}"#)
        #expect(text.title == "Перерыв 25 дней")
        #expect(text.body.contains("55%"))
        #expect(text.sentiment == .attention)
    }

    @Test("trend: positive, negative and neutral")
    func trend() throws {
        let up = try render(#"{"kind": "trend", "sentiment": "positive", "values": {"delta": 0.21, "matches": 6, "days": 30}}"#)
        #expect(up.title == "Рост +0.21 за 30 дней")
        #expect(up.body.contains("6 рейтинговых матчей"))
        #expect(up.symbol == "chart.line.uptrend.xyaxis")
        #expect(up.sentiment == .positive)

        let down = try render(#"{"kind": "trend", "sentiment": "attention", "values": {"delta": -0.15, "matches": 4, "days": 30}}"#)
        #expect(down.title == "Спад \u{2212}0.15 за 30 дней")
        #expect(down.body.contains("4 рейтинговых матча"))
        #expect(down.symbol == "chart.line.downtrend.xyaxis")
        #expect(down.sentiment == .attention)

        let flat = try render(#"{"kind": "trend", "sentiment": "neutral", "values": {"delta": 0.01, "matches": 5, "days": 30}}"#)
        #expect(flat.title == "Стабильный уровень")
        #expect(flat.body.contains("5 матчей"))
        #expect(flat.sentiment == .neutral)
    }

    @Test("vs_expectation: above and below")
    func versusExpectation() throws {
        let above = try render(#"{"kind": "vs_expectation", "sentiment": "positive", "values": {"residual": 0.18, "matches": 10}}"#)
        #expect(above.title == "Играете выше ожиданий")
        #expect(above.body.contains("18 п.п."))
        #expect(above.sentiment == .positive)

        let below = try render(#"{"kind": "vs_expectation", "sentiment": "attention", "values": {"residual": -0.12, "matches": 8}}"#)
        #expect(below.title == "Результаты ниже ожиданий")
        #expect(below.body.contains("12 п.п."))
        #expect(below.sentiment == .attention)
    }

    @Test("side_split")
    func sideSplit() throws {
        let text = try render(#"{"kind": "side_split", "sentiment": "neutral", "values": {"better_side": "left", "left_win_rate": 0.80, "left_matches": 5, "right_win_rate": 0.55, "right_matches": 11}}"#)
        #expect(text.title == "Сильнее на левой стороне")
        #expect(text.body.contains("80%"))
        #expect(text.body.contains("55%"))
        #expect(text.body.contains("5 матч"))
        #expect(text.body.contains("11 матч"))

        let right = try render(#"{"kind": "side_split", "sentiment": "neutral", "values": {"better_side": "right", "left_win_rate": 0.40, "left_matches": 5, "right_win_rate": 0.70, "right_matches": 10}}"#)
        #expect(right.title == "Сильнее на правой стороне")
    }

    @Test("close_sets: strong and weak")
    func closeSets() throws {
        let strong = try render(#"{"kind": "close_sets", "sentiment": "positive", "values": {"won": 9, "total": 13}}"#)
        #expect(strong.title == "Сильны в концовках")
        #expect(strong.body.contains("9 из 13"))
        #expect(strong.sentiment == .positive)

        let weak = try render(#"{"kind": "close_sets", "sentiment": "attention", "values": {"won": 3, "total": 10}}"#)
        #expect(weak.title == "Концовки — зона роста")
        #expect(weak.body.contains("3 из 10"))
        #expect(weak.sentiment == .attention)
    }

    @Test("best_partner")
    func bestPartner() throws {
        let text = try render(#"{"kind": "best_partner", "sentiment": "positive", "values": {"player": {"id": "d8b58bd9-8f8c-4732-a129-148692946aed", "username": "d_sokolov", "display_name": "Дмитрий Соколов", "deleted": false, "avatar_path": null, "city": {"id": 1, "name": "Москва"}, "club": {"id": 1, "name": "Падел Арена Лужники"}, "preferred_side": "left", "is_coach": false, "level": 4.89, "reliability": 25}, "matches": 6, "residual": 0.21}}"#)
        #expect(text.title == "Лучшая связка — Дмитрий Соколов")
        #expect(text.body.contains("6 матчей"))
        #expect(text.body.contains("21 п.п."))
        #expect(text.sentiment == .positive)
    }

    @Test("focus_area")
    func focusArea() throws {
        let text = try render(#"{"kind": "focus_area", "sentiment": "neutral", "values": {"dimension": "transition_lob", "offset": -0.56, "confidence": 0.54}}"#)
        #expect(text.title == "Фокус тренировок: переход и свечи")
        #expect(text.body.contains(DNADimension.transitionLob.trainingFocus))
        #expect(text.symbol == DNADimension.transitionLob.symbol)

        let camel = Insight(kind: "focus_area", sentiment: .neutral, values: ["dimension": .string("netGame")])
        #expect(Narratives.insight(camel)?.title == "Фокус тренировок: игра у сетки")

        let unknown = Insight(kind: "focus_area", sentiment: .neutral, values: ["dimension": .string("smash")])
        #expect(Narratives.insight(unknown) == nil)
    }

    @Test("Unknown insight kinds are skipped")
    func unknownKind() throws {
        let value = try insight(#"{"kind": "weather", "sentiment": "neutral", "values": {}}"#)
        #expect(Narratives.insight(value) == nil)
    }

    @Test("Every symbol exists in SF Symbols")
    func symbols() throws {
        let samples = [
            #"{"kind": "reliability_path", "sentiment": "neutral", "values": {"reliability": 42, "matches_needed": 3, "target": 70}}"#,
            #"{"kind": "inactivity", "sentiment": "attention", "values": {"days": 25, "reliability": 55}}"#,
            #"{"kind": "trend", "sentiment": "positive", "values": {"delta": 0.21, "matches": 6, "days": 30}}"#,
            #"{"kind": "trend", "sentiment": "attention", "values": {"delta": -0.15, "matches": 4, "days": 30}}"#,
            #"{"kind": "vs_expectation", "sentiment": "positive", "values": {"residual": 0.18, "matches": 10}}"#,
            #"{"kind": "vs_expectation", "sentiment": "attention", "values": {"residual": -0.12, "matches": 8}}"#,
            #"{"kind": "side_split", "sentiment": "neutral", "values": {"better_side": "left", "left_win_rate": 0.8, "left_matches": 5, "right_win_rate": 0.55, "right_matches": 11}}"#,
            #"{"kind": "close_sets", "sentiment": "positive", "values": {"won": 9, "total": 13}}"#,
            #"{"kind": "best_partner", "sentiment": "positive", "values": {"matches": 6, "residual": 0.21}}"#,
        ]
        for sample in samples {
            let symbol = try render(sample).symbol
            #expect(UIImage(systemName: symbol) != nil, "missing SF Symbol \(symbol)")
        }
        for dimension in DNADimension.allCases {
            #expect(UIImage(systemName: dimension.symbol) != nil, "missing SF Symbol \(dimension.symbol)")
        }
    }

    // MARK: Compatibility

    private func reasons(_ reasonsJSON: String, name: String = "Дмитрий") throws -> [String] {
        let json = "{\"score\": 80, \"components\": [], \"reasons\": [\(reasonsJSON)]}"
        let compatibility = try JSONCoding.decoder.decode(Compatibility.self, from: Data(json.utf8))
        return Narratives.compatibilityReasons(compatibility, otherName: name)
    }

    @Test("Compatibility: level gap")
    func levelGap() throws {
        let close = try reasons(#"{"code": "level_gap", "value": 0.2}"#)
        #expect(close == ["Почти одинаковый уровень (разница 0.20)"])
        let near = try reasons(#"{"code": "level_gap", "value": 0.5}"#)
        #expect(near == ["Близкий уровень: разница 0.50"])
        let far = try reasons(#"{"code": "level_gap", "value": 1.2}"#)
        #expect(far == ["Разница в уровне 1.20 — пара будет несбалансированной"])
    }

    @Test("Compatibility: court sides")
    func sides() throws {
        let cases: [(String, String, String)] = [
            ("right", "left", "Вы играете справа, Дмитрий — слева"),
            ("left", "right", "Вы играете слева, Дмитрий — справа"),
            ("both", "both", "Оба готовы играть на любой стороне"),
            ("both", "left", "Стороны легко распределить: один из вас играет на обеих"),
            ("right", "both", "Стороны легко распределить: один из вас играет на обеих"),
            ("left", "left", "Вы оба предпочитаете левую сторону"),
            ("right", "right", "Вы оба предпочитаете правую сторону"),
        ]
        for (a, b, expected) in cases {
            let lines = try reasons("{\"code\": \"sides\", \"a\": \"\(a)\", \"b\": \"\(b)\"}")
            #expect(lines == [expected], "\(a)/\(b)")
        }
    }

    @Test("Compatibility: style, chemistry, history and logistics")
    func otherReasons() throws {
        let covers = try reasons(#"{"code": "covers_weakness", "dimensions": ["transition_lob", "overheads"]}"#)
        #expect(covers == ["Закрывает ваши слабые места: переход и свечи, удары над головой"])
        let coversNothing = try reasons(#"{"code": "covers_weakness", "dimensions": []}"#)
        #expect(coversNothing.isEmpty)
        let chemistry = try reasons(#"{"code": "chemistry", "matches": 6, "residual": 0.21}"#)
        #expect(chemistry == ["Вместе 6 матчей: на 21 п.п. лучше ожидаемого"])
        let poorChemistry = try reasons(#"{"code": "chemistry", "matches": 3, "residual": -0.1}"#)
        #expect(poorChemistry == ["Вместе 3 матча: на 10 п.п. хуже ожидаемого"])
        let together = try reasons(#"{"code": "played_together", "matches": 1}"#)
        #expect(together == ["Уже играли вместе: 1 матч"])
        let club = try reasons(#"{"code": "same_club"}"#)
        #expect(club == ["Играете в одном клубе"])
        let city = try reasons(#"{"code": "same_city"}"#)
        #expect(city == ["Из одного города"])
        let unknown = try reasons(#"{"code": "horoscope"}"#)
        #expect(unknown.isEmpty)
    }

    @Test("Compatibility: order of reasons is kept")
    func reasonOrder() throws {
        let lines = try reasons(#"{"code": "level_gap", "value": 0.39}, {"code": "sides", "a": "right", "b": "left"}, {"code": "same_club"}"#)
        #expect(lines == ["Близкий уровень: разница 0.39", "Вы играете справа, Дмитрий — слева", "Играете в одном клубе"])
    }

    // MARK: Rating explanation

    private func change(_ json: String) throws -> RatingChange {
        try JSONCoding.decoder.decode(RatingChange.self, from: Data(json.utf8))
    }

    @Test("Rating explanation: every factor")
    func fullExplanation() throws {
        let value = try change(#"{"mu_before": 3.5, "mu_after": 3.58, "delta": 0.08, "sigma_before": 0.5, "sigma_after": 0.48, "details": {"algorithm": "PIR-1", "team": 1, "won": true, "team_strength": 3.71, "opponent_strength": 3.85, "expected_win": 0.42, "expected_game_share": 0.47, "game_share": 0.6, "margin_factor": 1.2, "weight": 0.6666666666666666, "repeat_lineup": 1, "gain": 0.25, "coef": 0.4, "sigma_effective": 0.5, "idle_days": 20, "partner": {"id": "d8b58bd9-8f8c-4732-a129-148692946aed", "mu": 4.1}, "opponents": [{"id": "72b11bd9-f270-4ae2-b104-25a132d48204", "mu": 4.6}, {"id": "2becd560-4954-4ad9-ab50-e454ea8f2d73", "mu": 3.2}]}}"#)
        #expect(value.details.partner?.mu == 4.1)
        #expect(value.details.opponents?.count == 2)
        #expect(Narratives.ratingExplanation(value) == [
            "Модель давала вашей паре 42% на победу: сила пары 3.71 против 3.85.",
            "Победа: вы взяли 60% геймов при ожидаемых 47%.",
            "Счёт убедительнее ожидаемого — изменение увеличено на 20%.",
            "Повторный рейтинговый матч тем же составом за 30 дней учитывается с весом 67%.",
            "Перерыв 20 дней повысил неопределённость, поэтому матч повлиял сильнее.",
            "Неопределённость рейтинга снизилась: ±0.50 → ±0.48.",
        ])
    }

    @Test("Rating explanation: a loss with a modest score")
    func lossExplanation() throws {
        let value = try change(#"{"mu_before": 4.0, "mu_after": 3.9, "delta": -0.1, "sigma_before": 0.6, "sigma_after": 0.59, "details": {"won": false, "team_strength": 4.2, "opponent_strength": 4.0, "expected_win": 0.61, "expected_game_share": 0.52, "game_share": 0.4, "margin_factor": 0.8, "weight": 1, "idle_days": 3}}"#)
        #expect(Narratives.ratingExplanation(value) == [
            "Модель давала вашей паре 61% на победу: сила пары 4.20 против 4.00.",
            "Поражение: вы взяли 40% геймов при ожидаемых 52%.",
            "Счёт скромнее ожидаемого — изменение уменьшено на 20%.",
            "Неопределённость рейтинга снизилась: ±0.60 → ±0.59.",
        ])
    }

    @Test("Rating explanation: missing details")
    func sparseExplanation() throws {
        let empty = try change(#"{"mu_before": 3.0, "mu_after": 3.0, "delta": 0, "sigma_before": 0.5, "sigma_after": 0.5, "details": {}}"#)
        #expect(Narratives.ratingExplanation(empty).isEmpty)
        let resultOnly = try change(#"{"mu_before": 3.0, "mu_after": 3.1, "delta": 0.1, "sigma_before": 0.5, "sigma_after": 0.5, "details": {"won": true}}"#)
        #expect(Narratives.ratingExplanation(resultOnly) == ["Победа."])
    }

    // MARK: Labels

    @Test("Labels for enums are Russian and complete")
    func labels() {
        for reason in DisputeReason.allCases {
            #expect(!Narratives.disputeReason(reason).isEmpty)
        }
        for format in MatchFormat.allCases {
            #expect(!Narratives.format(format).isEmpty)
        }
        let statuses: [MatchStatus] = [.pending, .disputed, .confirmed, .cancelled, .expired]
        #expect(Set(statuses.map(Narratives.status)).count == statuses.count)
        #expect(Narratives.matchType(.ranked) == "Рейтинговый")
        #expect(Narratives.matchType(.friendly) == "Товарищеский")
        #expect(Narratives.sideName(.left) == "Левая сторона")
        #expect(Narratives.sideName(nil) == "—")
        #expect(Narratives.sideShort(.right) == "Справа")
    }
}
