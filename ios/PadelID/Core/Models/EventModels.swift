import Foundation

nonisolated enum SportEventKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case training, tournament
    var id: String { rawValue }
    var title: String { self == .training ? "Тренировки" : "Турниры" }
    var singular: String { self == .training ? "Тренировка" : "Турнир" }
    var symbol: String { self == .training ? "figure.tennis" : "trophy" }
}
nonisolated enum SportEventFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case individual, group, americano, mexicano
    case kingCourt = "king_court"
    case roundRobin = "round_robin"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .individual: "Индивидуальная"
        case .group: "Групповая"
        case .americano: "Американо"
        case .mexicano: "Мексикано"
        case .kingCourt: "Король корта"
        case .roundRobin: "Круговой турнир"
        }
    }
    var explanation: String {
        switch self {
        case .individual: "Один игрок и подтверждённый тренер."
        case .group: "Группа игроков и подтверждённый тренер."
        case .americano: "4 или 8 игроков. Каждый сыграет в паре с каждым один раз и против каждого дважды. Итог — сумма подтверждённых очков."
        case .mexicano: "Пары формируются по текущей таблице: 1-й с 4-м против 2-го с 3-м в каждой группе из четырёх. Итог — сумма подтверждённых очков."
        case .kingCourt: "Пары первого раунда остаются вместе. Победители поднимаются на корт выше, проигравшие опускаются. На границах пара остаётся на месте. Ничья не допускается. Итог определяется последним полностью подтверждённым раундом."
        case .roundRobin: "Постоянные пары. Каждый партнёр принимает приглашение самостоятельно. Каждая пара играет с каждой один раз. Итог — сумма подтверждённых очков."
        }
    }
    var capacities: [Int] {
        switch self {
        case .individual: [1]
        case .group: [2, 3, 4, 6, 8, 12, 16]
        case .americano: [4, 8]
        default: [4, 8, 12, 16]
        }
    }
    static func formats(for kind: SportEventKind) -> [SportEventFormat] {
        kind == .training ? [.individual, .group] : [.americano, .mexicano, .kingCourt, .roundRobin]
    }
}
nonisolated enum SportEventStatus: String, Codable, Sendable {
    case open, running, completed, cancelled
    var title: String {
        switch self {
        case .open: "Запись открыта"
        case .running: "Турнир идёт"
        case .completed: "Завершено"
        case .cancelled: "Отменено"
        }
    }
}
nonisolated struct SportEventViewer: Codable, Hashable, Sendable {
    let isOrganizer: Bool
    let registration: String?
}
nonisolated struct SportEventRegistration: Codable, Hashable, Identifiable, Sendable {
    let player: PlayerCard
    let teamId: UUID
    let status: String
    var id: UUID { player.id }
}
nonisolated struct SportEventGame: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let round: Int
    let court: Int
    let team1: [PlayerCard]
    let team2: [PlayerCard]
    let points1: Int?
    let points2: Int?
    let version: Int
    let confirmed: Bool
    let confirmations: [UUID]
    var playerIDs: Set<UUID> { Set((team1 + team2).map(\.id)) }
    var score: String { points1.map { "\($0):\(points2 ?? 0)" } ?? "Счёт не внесён" }
}
nonisolated struct SportEventStanding: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let rank: Int
    let points: Int
    let played: Int
    let wins: Int
    let pointDifference: Int
    let players: [PlayerCard]
}
nonisolated struct SportEvent: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let kind: SportEventKind
    let format: SportEventFormat
    let title: String
    let description: String
    let organizer: PlayerCard
    let startsAt: Date
    let durationMinutes: Int
    let city: NamedRef
    let club: NamedRef?
    let location: String
    let capacity: Int
    let minLevel: Double
    let maxLevel: Double
    let specialization: String?
    let priceRub: Int?
    let roundCount: Int
    let pointsPerGame: Int
    let currentRound: Int
    let status: SportEventStatus
    let registeredCount: Int
    let viewer: SportEventViewer
    let registrations: [SportEventRegistration]
    let games: [SportEventGame]
    let standings: [SportEventStanding]
    let metadataVersion: Int?
    var editingVersion: Int { metadataVersion ?? 1 }
    var rosterIsOpen: Bool { status == .open && startsAt > .now }
    var endsAt: Date { startsAt.addingTimeInterval(Double(durationMinutes) * 60) }
    var priceTitle: String? { priceRub.map { $0 == 0 ? "Бесплатно" : "\($0.formatted(.number.locale(Format.locale))) ₽" } }
}
nonisolated struct SportEventsPage: Codable, Sendable { let items: [SportEvent]; let nextOffset: Int? }
nonisolated struct SportEventCreateBody: Encodable, Sendable {
    let clientId: UUID
    let kind: SportEventKind
    let format: SportEventFormat
    let title: String
    let description: String
    let startsAt: String
    let durationMinutes: Int
    let cityId: Int
    let clubId: Int?
    let location: String
    let capacity: Int
    let minLevel: Double
    let maxLevel: Double
    let specialization: String?
    let priceRub: Int?
    let roundCount: Int
    let pointsPerGame: Int
}
nonisolated struct SportEventRegisterBody: Encodable, Sendable { let partnerId: UUID? }
nonisolated struct SportEventRoundBody: Encodable, Sendable { let expectedRound: Int }
nonisolated struct SportEventScoreBody: Encodable, Sendable { let version: Int; let points1: Int; let points2: Int }
nonisolated struct SportEventConfirmBody: Encodable, Sendable { let version: Int }
nonisolated struct SportEventEditBody: Encodable, Equatable, Sendable {
    let version: Int
    let title: String
    let description: String
    let startsAt: String
    let durationMinutes: Int
    let cityId: Int
    let clubId: Int?
    let location: String
    let specialization: String?
    let priceRub: Int?
}

/// Retains the local edits when another device updates the same event.
/// Unchanged fields take the canonical values; related city/club and price
/// fields are reconciled together so the resulting draft stays coherent.
nonisolated struct SportEventEditDraft: Equatable, Sendable {
    var title: String
    var description: String
    var startsAt: Date
    var duration: Int
    var city: NamedRef?
    var club: NamedRef?
    var location: String
    var specialization: String
    var hasPrice: Bool
    var priceText: String

    init(event: SportEvent) {
        title = event.title; description = event.description; startsAt = event.startsAt
        duration = event.durationMinutes; city = event.city; club = event.club
        location = event.location; specialization = event.specialization ?? ""
        hasPrice = event.priceRub != nil; priceText = event.priceRub.map(String.init) ?? ""
    }

    mutating func reconcile(from previous: SportEvent, to fresh: SportEvent) {
        if title == previous.title { title = fresh.title }
        if description == previous.description { description = fresh.description }
        if startsAt == previous.startsAt { startsAt = fresh.startsAt }
        if duration == previous.durationMinutes { duration = fresh.durationMinutes }
        if city?.id == previous.city.id && club?.id == previous.club?.id {
            city = fresh.city; club = fresh.club
        }
        if location == previous.location { location = fresh.location }
        if specialization == (previous.specialization ?? "") { specialization = fresh.specialization ?? "" }
        if hasPrice == (previous.priceRub != nil) && priceText == (previous.priceRub.map(String.init) ?? "") {
            hasPrice = fresh.priceRub != nil; priceText = fresh.priceRub.map(String.init) ?? ""
        }
    }
}
