import Foundation

/// Turns structured analytics from the API into Russian copy. The server sends
/// facts (numbers, codes); all wording lives here.
nonisolated struct InsightText: Sendable, Hashable {
    let title: String
    let body: String
    let symbol: String
    let sentiment: Sentiment
}

nonisolated enum Narratives {
    static func insight(_ insight: Insight) -> InsightText? {
        let v = insight.values
        switch insight.kind {
        case "reliability_path":
            let rel = v["reliability"]?.int ?? 0
            let n = v["matchesNeeded"]?.int ?? 0
            let target = v["target"]?.int ?? 70
            return InsightText(
                title: "Надёжность рейтинга \(rel)%",
                body: "Ещё \(Format.count(n, "рейтинговый матч", "рейтинговых матча", "рейтинговых матчей")) против игроков с устойчивым рейтингом — и надёжность превысит \(target)%. Пока рейтинг предварительный и сильнее меняется после каждого матча.",
                symbol: "gauge.with.dots.needle.33percent",
                sentiment: insight.sentiment)
        case "inactivity":
            let days = v["days"]?.int ?? 0
            let rel = v["reliability"]?.int ?? 0
            return InsightText(
                title: "Перерыв \(Format.days(days))",
                body: "Без рейтинговых матчей неопределённость растёт: надёжность сейчас \(rel)%. Первый матч после паузы повлияет на рейтинг сильнее обычного.",
                symbol: "hourglass",
                sentiment: insight.sentiment)
        case "trend":
            let delta = v["delta"]?.double ?? 0
            let matches = v["matches"]?.int ?? 0
            let title: String
            switch insight.sentiment {
            case .positive: title = "Рост \(Format.delta(delta)) за 30 дней"
            case .attention: title = "Спад \(Format.delta(delta)) за 30 дней"
            case .neutral: title = "Стабильный уровень"
            }
            let body = insight.sentiment == .neutral
                ? "За месяц \(Format.matches(matches)) в рейтинге, уровень почти не изменился — результаты соответствуют ожиданиям."
                : "За месяц \(Format.count(matches, "рейтинговый матч", "рейтинговых матча", "рейтинговых матчей")): уровень изменился на \(Format.delta(delta))."
            return InsightText(title: title, body: body,
                               symbol: insight.sentiment == .attention ? "chart.line.downtrend.xyaxis" : "chart.line.uptrend.xyaxis",
                               sentiment: insight.sentiment)
        case "vs_expectation":
            let residual = v["residual"]?.double ?? 0
            let matches = v["matches"]?.int ?? 0
            let pct = Int((abs(residual) * 100).rounded())
            if residual > 0 {
                return InsightText(
                    title: "Играете выше ожиданий",
                    body: "В последних \(matches) рейтинговых матчах вы побеждаете на \(pct) п.п. чаще, чем предсказывает модель. Если так продолжится, рейтинг будет расти.",
                    symbol: "arrow.up.right.circle", sentiment: .positive)
            }
            return InsightText(
                title: "Результаты ниже ожиданий",
                body: "В последних \(matches) рейтинговых матчах вы побеждаете на \(pct) п.п. реже, чем предсказывает модель. Обратите внимание на партнёров и выбор соперников.",
                symbol: "arrow.down.right.circle", sentiment: .attention)
        case "side_split":
            let better = v["betterSide"]?.string == "left" ? "левой" : "правой"
            let left = Int(((v["leftWinRate"]?.double ?? 0) * 100).rounded())
            let right = Int(((v["rightWinRate"]?.double ?? 0) * 100).rounded())
            let ln = v["leftMatches"]?.int ?? 0
            let rn = v["rightMatches"]?.int ?? 0
            return InsightText(
                title: "Сильнее на \(better) стороне",
                body: "Слева — \(left)% побед в \(Format.matches(ln)), справа — \(right)% в \(Format.matches(rn)). Учитывайте это при выборе партнёра.",
                symbol: "rectangle.split.2x1", sentiment: .neutral)
        case "close_sets":
            let won = v["won"]?.int ?? 0
            let total = v["total"]?.int ?? 0
            if insight.sentiment == .positive {
                return InsightText(
                    title: "Сильны в концовках",
                    body: "Выиграно \(won) из \(total) упорных сетов: 7:5, 7:6 и супертай-брейки. Это напрямую влияет на «Стабильность и решения» в Padel DNA.",
                    symbol: "flame", sentiment: .positive)
            }
            return InsightText(
                title: "Концовки — зона роста",
                body: "Выиграно \(won) из \(total) упорных сетов. Тренировка розыгрышей на счёт и тай-брейков даст быстрый эффект.",
                symbol: "flame", sentiment: .attention)
        case "best_partner":
            let card = v["player"]?.decode(PlayerCard.self)
            let matches = v["matches"]?.int ?? 0
            let pct = Int(((v["residual"]?.double ?? 0) * 100).rounded())
            return InsightText(
                title: "Лучшая связка — \(card?.displayName ?? "партнёр")",
                body: "Вместе \(Format.matches(matches)): вы побеждаете на \(pct) п.п. чаще ожидаемого.",
                symbol: "person.2.fill", sentiment: .positive)
        case "focus_area":
            guard let key = v["dimension"]?.string, let dimension = DNADimension(apiKey: key) else { return nil }
            return InsightText(
                title: "Фокус тренировок: \(dimension.title.lowercased())",
                body: "Самое слабое направление в вашем Padel DNA. \(dimension.trainingFocus)",
                symbol: dimension.symbol, sentiment: .neutral)
        default:
            return nil
        }
    }

    static func sideName(_ side: CourtSide?) -> String {
        switch side {
        case .left: "Левая сторона"
        case .right: "Правая сторона"
        case .both: "Любая сторона"
        case nil: "—"
        }
    }

    static func sideShort(_ side: CourtSide) -> String {
        switch side {
        case .left: "Слева"
        case .right: "Справа"
        case .both: "Любая"
        }
    }

    /// Compatibility reasons as short sentences from the viewer's perspective.
    static func compatibilityReasons(_ c: Compatibility, otherName: String) -> [String] {
        c.reasons.compactMap { reason in
            switch reason["code"]?.string {
            case "level_gap":
                let gap = reason["value"]?.double ?? 0
                if gap < 0.3 { return "Почти одинаковый уровень (разница \(Format.level(gap)))" }
                if gap < 0.75 { return "Близкий уровень: разница \(Format.level(gap))" }
                return "Разница в уровне \(Format.level(gap)) — пара будет несбалансированной"
            case "sides":
                let a = CourtSide(rawValue: reason["a"]?.string ?? "")
                let b = CourtSide(rawValue: reason["b"]?.string ?? "")
                switch (a, b) {
                case (.right, .left): return "Вы играете справа, \(otherName) — слева"
                case (.left, .right): return "Вы играете слева, \(otherName) — справа"
                case (.both, .both): return "Оба готовы играть на любой стороне"
                case (.both, _), (_, .both): return "Стороны легко распределить: один из вас играет на обеих"
                case (.left, .left): return "Оба предпочитаете левую сторону"
                case (.right, .right): return "Оба предпочитаете правую сторону"
                default: return nil
                }
            case "covers_weakness":
                let dims = (reason["dimensions"]?.array ?? []).compactMap { $0.string.flatMap(DNADimension.init(apiKey:)) }
                guard !dims.isEmpty else { return nil }
                return "Закрывает ваши слабые места: " + dims.map { $0.title.lowercased() }.joined(separator: ", ")
            case "chemistry":
                let n = reason["matches"]?.int ?? 0
                let residual = reason["residual"]?.double ?? 0
                let pct = Int((abs(residual) * 100).rounded())
                return residual >= 0
                    ? "Вместе \(Format.matches(n)): на \(pct) п.п. лучше ожидаемого"
                    : "Вместе \(Format.matches(n)): на \(pct) п.п. хуже ожидаемого"
            case "played_together":
                return "Уже играли вместе: \(Format.matches(reason["matches"]?.int ?? 0))"
            case "same_club":
                return "Играете в одном клубе"
            case "same_city":
                return "Из одного города"
            default:
                return nil
            }
        }
    }

    /// Step-by-step explanation of a rating change.
    static func ratingExplanation(_ change: RatingChange) -> [String] {
        let d = change.details
        var lines: [String] = []
        if let expected = d.expectedWin, let team = d.teamStrength, let opp = d.opponentStrength {
            lines.append("Модель давала вашей паре \(Format.percent(expected)) на победу: сила пары \(Format.level(team)) против \(Format.level(opp)).")
        }
        if let won = d.won {
            if let share = d.gameShare, let expectedShare = d.expectedGameShare {
                lines.append("\(won ? "Победа" : "Поражение"): вы взяли \(Format.percent(share)) геймов при ожидаемых \(Format.percent(expectedShare)).")
            } else {
                lines.append(won ? "Победа." : "Поражение.")
            }
        }
        if let margin = d.marginFactor, abs(margin - 1) >= 0.03 {
            let pct = Int((abs(margin - 1) * 100).rounded())
            lines.append(margin > 1
                ? "Счёт убедительнее ожидаемого — изменение увеличено на \(pct)%."
                : "Счёт скромнее ожидаемого — изменение уменьшено на \(pct)%.")
        }
        if let weight = d.weight, weight < 0.999 {
            lines.append("Повторный рейтинговый матч тем же составом за 30 дней учитывается с весом \(Format.percent(weight)).")
        }
        if let idle = d.idleDays, idle > 14 {
            lines.append("Перерыв \(Format.days(Int(idle))) повысил неопределённость, поэтому матч повлиял сильнее.")
        }
        if change.sigmaAfter < change.sigmaBefore - 0.0005 {
            lines.append("Неопределённость рейтинга снизилась: ±\(Format.level(change.sigmaBefore)) → ±\(Format.level(change.sigmaAfter)).")
        }
        return lines
    }

    static func disputeReason(_ reason: DisputeReason) -> String {
        switch reason {
        case .wrongScore: "Неверный счёт"
        case .wrongPlayers: "Неверный состав"
        case .wrongType: "Неверный тип матча"
        case .notPlayed: "Я не участвовал в этом матче"
        case .other: "Другая причина"
        }
    }

    static func matchType(_ type: MatchType) -> String {
        type == .ranked ? "Рейтинговый" : "Товарищеский"
    }

    static func format(_ format: MatchFormat) -> String {
        switch format {
        case .bestOf3: "3 сета"
        case .bestOf3SuperTiebreak: "2 сета + супертай-брейк"
        case .singleSet: "1 сет"
        }
    }

    static func status(_ status: MatchStatus) -> String {
        switch status {
        case .pending: "Ждёт подтверждения"
        case .disputed: "Оспорен"
        case .confirmed: "Подтверждён"
        case .cancelled: "Отменён"
        case .expired: "Истёк срок подтверждения"
        }
    }
}
