import Foundation

/// Russian-language formatting helpers shared across the app.
nonisolated enum Format {
    static let locale = Locale(identifier: "ru_RU")

    /// Level on the 0–7 scale, always two decimals: "3.74".
    static func level(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// Signed rating delta: "+0.07", "−0.03", "0.00".
    static func delta(_ value: Double?, digits: Int = 2) -> String {
        guard let value else { return "—" }
        let rounded = (value * pow(10, Double(digits))).rounded() / pow(10, Double(digits))
        let magnitude = String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), abs(rounded))
        if rounded > 0 { return "+" + magnitude }
        if rounded < 0 { return "−" + magnitude }
        return magnitude
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Russian plural selection: plural(5, "матч", "матча", "матчей") → "матчей".
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n100 = abs(n) % 100
        let n10 = n100 % 10
        if n100 >= 11 && n100 <= 14 { return many }
        if n10 == 1 { return one }
        if n10 >= 2 && n10 <= 4 { return few }
        return many
    }

    static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        "\(n) \(plural(n, one, few, many))"
    }

    static func matches(_ n: Int) -> String { count(n, "матч", "матча", "матчей") }
    static func days(_ n: Int) -> String { count(n, "день", "дня", "дней") }

    static func date(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(locale))
    }

    static func shortDate(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        var style = Date.FormatStyle().locale(locale).day().month(.abbreviated)
        if !sameYear { style = style.year() }
        return date.formatted(style)
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(locale))
    }

    /// "сегодня", "вчера", "3 дня назад", or a short date.
    static func relativeDay(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Сегодня" }
        if calendar.isDateInYesterday(date) { return "Вчера" }
        let diff = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if diff > 1 && diff < 7 { return "\(Format.days(diff)) назад" }
        return shortDate(date)
    }

    static func setScore(_ set: SetScore, perspective team: Int = 1) -> String {
        let mine = team == 1 ? set.t1 : set.t2
        let theirs = team == 1 ? set.t2 : set.t1
        var text = "\(mine):\(theirs)"
        if let a = set.tb1, let b = set.tb2 {
            // Tennis notation: the loser's tie-break points, e.g. 7:6(4).
            text += "(\(min(a, b)))"
        }
        return text
    }

    static func score(_ sets: [SetScore], perspective team: Int = 1) -> String {
        sets.map { setScore($0, perspective: team) }.joined(separator: " ")
    }
}

extension String {
    nonisolated var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
