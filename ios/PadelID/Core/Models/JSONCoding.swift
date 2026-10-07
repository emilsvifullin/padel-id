import Foundation

/// Shared JSON coders matching the API contract: snake_case keys and ISO-8601
/// timestamps with optional fractional seconds of any precision.
nonisolated enum JSONCoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = parseDate(raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(raw)")
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatDate(date))
        }
        return encoder
    }()

    static func formatDate(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// Parses `2026-10-07T22:53:03Z`, `…T22:53:03.1Z`, `…T22:53:03.123456+00:00`
    /// and plain dates `2026-10-07`.
    static func parseDate(_ raw: String) -> Date? {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.count == 10 {
            value += "T00:00:00Z"
        }
        // Normalise fractional seconds to exactly three digits.
        if let dot = value.firstIndex(of: "."), let tzStart = value[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let fraction = value[value.index(after: dot)..<tzStart]
            let normalized = String((fraction + "000").prefix(3))
            value = String(value[..<dot]) + "." + normalized + String(value[tzStart...])
        }
        if value.hasSuffix("+00:00") {
            value = String(value.dropLast(6)) + "Z"
        }
        if let date = try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        if let date = try? Date(value, strategy: Date.ISO8601FormatStyle()) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
