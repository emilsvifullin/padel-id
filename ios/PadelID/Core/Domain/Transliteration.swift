import Foundation

/// Builds Latin usernames from display names.
///
/// Cyrillic is transliterated with a passport-like scheme (ж → zh, х → kh,
/// ц → ts, ч → ch, ш → sh, щ → shch, ю → yu, я → ya, й → y, ё → e, ъ/ь are
/// dropped). Latin letters lose their diacritics, spaces and hyphens become
/// underscores and everything else is removed, so the result always matches
/// the server rule `^[a-z0-9_]{3,20}$`.
nonisolated enum Transliteration {
    static let minimumLength = 3
    static let maximumLength = 20

    private static let table: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
        "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
        "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
        "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
        // Ukrainian and Belarusian.
        "і": "i", "ї": "yi", "є": "ye", "ґ": "g", "ў": "u",
        // Kazakh.
        "ә": "a", "ғ": "g", "қ": "k", "ң": "n", "ө": "o", "ұ": "u", "ү": "u", "һ": "h",
    ]

    private static let separators: Set<Character> = ["-", "‐", "‑", "–", "—", "_"]

    /// A username suggestion for a display name, e.g. "Иван Петров" → "ivan_petrov".
    /// Returns an empty string for an empty name.
    static func username(from displayName: String) -> String {
        let source = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !source.isEmpty else { return "" }

        var raw = ""
        for character in source {
            if let mapped = table[character] {
                raw += mapped
            } else if character.isWhitespace || separators.contains(character) {
                raw += "_"
            } else {
                raw += latin(character)
            }
        }

        // Collapse runs of underscores and trim them at both ends.
        var collapsed = ""
        for character in raw {
            if character == "_" && (collapsed.isEmpty || collapsed.last == "_") { continue }
            collapsed.append(character)
        }
        while collapsed.last == "_" { collapsed.removeLast() }

        if collapsed.count > maximumLength {
            collapsed = String(collapsed.prefix(maximumLength))
            while collapsed.last == "_" { collapsed.removeLast() }
        }

        if collapsed.isEmpty {
            // Nothing transliterable (e.g. a name in another script).
            return "player"
        }

        var digit = 1
        while collapsed.count < minimumLength {
            collapsed += String(digit)
            digit += 1
        }
        return collapsed
    }

    /// Keeps a-z and 0-9 of a single character after removing diacritics
    /// ("é" → "e", "ñ" → "n").
    private static func latin(_ character: Character) -> String {
        let folded = String(character).folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive],
                                               locale: Locale(identifier: "en_US_POSIX"))
        var result = ""
        for scalar in folded.unicodeScalars {
            let value = scalar.value
            if (0x61...0x7A).contains(value) || (0x30...0x39).contains(value) {
                result.append(Character(scalar))
            }
        }
        return result
    }
}
