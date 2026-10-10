import Foundation

nonisolated enum FriendshipState: String, Codable, Hashable, Sendable {
    case none, incoming, outgoing, accepted
}

nonisolated struct FriendshipStatus: Codable, Hashable, Sendable {
    let playerId: UUID
    let status: FriendshipState
}

nonisolated struct Friendship: Codable, Hashable, Sendable, Identifiable {
    let player: PlayerCard
    let status: FriendshipState
    let requestedAt: Date
    var id: UUID { player.id }
}

nonisolated struct FriendsResponse: Codable, Hashable, Sendable {
    let accepted: [Friendship]
    let incoming: [Friendship]
    let outgoing: [Friendship]
}

nonisolated struct RecentRecord: Codable, Hashable, Sendable {
    let matches: Int
    let wins: Int
    let losses: Int
}

nonisolated enum UpcomingStatus: String, Codable, Hashable, Sendable {
    case open, full, awaitingResult = "awaiting_result", resultPending = "result_pending", completed, cancelled
    var title: String {
        switch self {
        case .open: "Набор игроков"
        case .full: "Состав собран"
        case .awaitingResult: "Ожидает результата"
        case .resultPending: "Подтверждение результата"
        case .completed: "Матч подтверждён"
        case .cancelled: "Игра отменена"
        }
    }
}

nonisolated struct UpcomingParticipant: Codable, Hashable, Sendable, Identifiable {
    let player: PlayerCard
    let joinedAt: Date
    var id: UUID { player.id }
}

nonisolated struct UpcomingApplication: Codable, Hashable, Sendable, Identifiable {
    let player: PlayerCard
    let status: String
    let requestedAt: Date
    var id: UUID { player.id }
}

nonisolated struct UpcomingViewer: Codable, Hashable, Sendable {
    let isOrganizer: Bool
    let participation: String
    let canJoin: Bool
    let admission: String
}

nonisolated struct AdmissionPolicy: Codable, Hashable, Sendable {
    let minReliability: Int
    let minimumRankedMatches: Int
}

nonisolated struct UpcomingMatch: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let clientId: UUID
    let organizer: PlayerCard
    let startsAt: Date
    let city: NamedRef
    let club: NamedRef?
    let location: String
    let matchType: MatchType
    let minLevel: Double
    let maxLevel: Double
    let note: String?
    let status: UpcomingStatus
    let participants: [UpcomingParticipant]
    let applications: [UpcomingApplication]
    let spotsLeft: Int
    let viewer: UpcomingViewer
    let admission: AdmissionPolicy
    let resultMatchId: UUID?
    let resultStatus: MatchStatus?

    var statusTitle: String {
        if status == .resultPending {
            switch resultStatus {
            case .expired: return "Срок подтверждения истёк"
            case .cancelled: return "Результат отменён"
            case .disputed: return "Результат оспорен"
            default: break
            }
        }
        return status.title
    }

    var isClosed: Bool { status == .cancelled || resultMatchId != nil }
    var canEnterResult: Bool {
        viewer.participation == "accepted" && !isClosed && participants.count == 4 && startsAt <= .now
    }
}

nonisolated struct UpcomingPage: Codable, Hashable, Sendable {
    let items: [UpcomingMatch]
    let nextOffset: Int?
}

nonisolated struct UpcomingCreateBody: Encodable, Sendable {
    let clientId: UUID
    let startsAt: String
    let cityId: Int
    let clubId: Int?
    let location: String
    let matchType: MatchType
    let minLevel: Double
    let maxLevel: Double
    let note: String?
}
