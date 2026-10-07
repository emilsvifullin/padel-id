import Foundation

// API models. Keys arrive in snake_case and are converted by `JSONCoding`
// (note: dictionary keys are converted too, e.g. "serve_return" → "serveReturn").

nonisolated struct NamedRef: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
}

nonisolated enum CourtSide: String, Codable, Hashable, Sendable, CaseIterable {
    case left, right, both
}

nonisolated enum Hand: String, Codable, Hashable, Sendable, CaseIterable {
    case right, left
}

nonisolated struct PlayerCard: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let username: String?
    let displayName: String
    let deleted: Bool
    let avatarPath: String?
    let city: NamedRef?
    let club: NamedRef?
    let preferredSide: CourtSide?
    let isCoach: Bool
    let level: Double?
    let reliability: Int?
    var compatibility: Int?
    var matchesTogether: Int?
}

nonisolated struct Profile: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let username: String?
    let displayName: String
    let deleted: Bool
    let avatarPath: String?
    let city: NamedRef?
    let club: NamedRef?
    let preferredSide: CourtSide?
    let isCoach: Bool
    let level: Double?
    let reliability: Int?
    let dominantHand: Hand?
    let playingSince: Int?
    let bio: String?
    let discoverable: Bool?
    let memberSince: Date?

    var card: PlayerCard {
        PlayerCard(id: id, username: username, displayName: displayName, deleted: deleted, avatarPath: avatarPath,
                   city: city, club: club, preferredSide: preferredSide, isCoach: isCoach, level: level,
                   reliability: reliability, compatibility: nil, matchesTogether: nil)
    }
}

nonisolated struct RatingSummary: Codable, Hashable, Sendable {
    let mu: Double
    let sigma: Double
    let reliability: Int
    let provisional: Bool
    let rankedMatches: Int
    let rankedWins: Int
    let peakMu: Double
    let initialMu: Double
    let lastRankedAt: Date?
    let idleDays: Int
    let trend30d: Double
}

nonisolated struct Me: Codable, Hashable, Sendable {
    let userId: UUID
    let email: String?
    let needsOnboarding: Bool
    let isAdmin: Bool
    let profile: Profile?
    let rating: RatingSummary?
    let dnaSelf: [String: Int]?
    let coachStatus: CoachStatus?
    let recoveryKeyCreatedAt: Date?
}

nonisolated enum CoachStatus: String, Codable, Hashable, Sendable {
    case pending, approved, rejected, revoked
}

// MARK: - Padel DNA

nonisolated struct DNADimensionState: Codable, Hashable, Sendable, Identifiable {
    let key: String
    let level: Double
    let offset: Double
    let confidence: Double
    let peerSignals: Int
    let coachSignals: Int
    let selfSignal: Bool
    let matchSignal: Bool
    let coachVerifiedAt: Date?
    let trend30d: Double?

    var id: String { key }
    var dimension: DNADimension? { DNADimension(apiKey: key) }
}

nonisolated struct DNAHistoryPoint: Codable, Hashable, Sendable {
    let dimension: String
    let day: Date
    let level: Double
}

nonisolated struct PadelDNA: Codable, Hashable, Sendable {
    let archetype: String
    let dimensions: [DNADimensionState]
    var history: [DNAHistoryPoint]?
    var rating: RatingSummary?
}

// MARK: - Statistics

nonisolated struct WinCount: Codable, Hashable, Sendable {
    let matches: Int
    let wins: Int
}

nonisolated struct WonLost: Codable, Hashable, Sendable {
    let won: Int
    let lost: Int
}

nonisolated struct SideStats: Codable, Hashable, Sendable {
    let left: WinCount
    let right: WinCount
}

nonisolated struct Streak: Codable, Hashable, Sendable {
    let type: String
    let count: Int
}

nonisolated struct PartnerStat: Codable, Hashable, Sendable, Identifiable {
    let player: PlayerCard
    let matches: Int
    let wins: Int
    var id: UUID { player.id }
}

nonisolated struct PlayerStats: Codable, Hashable, Sendable {
    let matches: Int
    let wins: Int
    let losses: Int
    let ranked: WinCount
    let friendly: WinCount
    let sets: WonLost
    let games: WonLost
    let tiebreaks: WonLost
    let decidingSets: WonLost
    let sides: SideStats
    let lastPlayedAt: Date?
    let form: [String]
    let streak: Streak?
    let partners: [PartnerStat]
    let rivals: [PartnerStat]
}

// MARK: - Matches

nonisolated enum MatchType: String, Codable, Hashable, Sendable, CaseIterable {
    case ranked, friendly
}

nonisolated enum MatchFormat: String, Codable, Hashable, Sendable, CaseIterable {
    case bestOf3 = "best_of_3"
    case bestOf3SuperTiebreak = "best_of_3_super_tiebreak"
    case singleSet = "single_set"
}

nonisolated enum MatchStatus: String, Codable, Hashable, Sendable {
    case pending, disputed, confirmed, cancelled, expired
}

nonisolated enum ResponseState: String, Codable, Hashable, Sendable {
    case pending, confirmed, disputed
}

nonisolated enum DisputeReason: String, Codable, Hashable, Sendable, CaseIterable {
    case wrongScore = "wrong_score"
    case wrongPlayers = "wrong_players"
    case wrongType = "wrong_type"
    case notPlayed = "not_played"
    case other
}

nonisolated struct SetScore: Codable, Hashable, Sendable {
    var t1: Int
    var t2: Int
    var superTiebreak: Bool = false
    var tb1: Int? = nil
    var tb2: Int? = nil

    var winner: Int { t1 > t2 ? 1 : 2 }
}

nonisolated struct LineupEntry: Codable, Hashable, Sendable {
    let player: PlayerCard
    let team: Int
    let courtSide: CourtSide
    let response: ResponseState
}

nonisolated struct MatchListItem: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let matchType: MatchType
    let format: MatchFormat
    let status: MatchStatus
    let playedAt: Date
    let clubName: String?
    let sets: [SetScore]
    let winnerTeam: Int
    let version: Int
    let updatedAt: Date
    let expiresAt: Date?
    let isCreator: Bool
    let myTeam: Int?
    let myResponse: ResponseState?
    let needsAction: Bool
    let pendingCount: Int
    let disputedCount: Int
    let ratingDelta: Double?
    let players: [LineupEntry]
    var subjectTeam: Int?
    var subjectRatingDelta: Double?
}

nonisolated struct MatchPage: Codable, Hashable, Sendable {
    let items: [MatchListItem]
    let nextBefore: String?
}

nonisolated struct RatingRef: Codable, Hashable, Sendable {
    let id: UUID
    let mu: Double
}

nonisolated struct RatingDetails: Codable, Hashable, Sendable {
    let algorithm: String?
    let team: Int?
    let won: Bool?
    let teamStrength: Double?
    let opponentStrength: Double?
    let expectedWin: Double?
    let expectedGameShare: Double?
    let gameShare: Double?
    let marginFactor: Double?
    let weight: Double?
    let repeatLineup: Int?
    let gain: Double?
    let coef: Double?
    let sigmaEffective: Double?
    let idleDays: Double?
    let partner: RatingRef?
    let opponents: [RatingRef]?
}

nonisolated struct RatingChange: Codable, Hashable, Sendable {
    let muBefore: Double
    let muAfter: Double
    let delta: Double
    let sigmaBefore: Double
    let sigmaAfter: Double
    let details: RatingDetails
}

nonisolated struct MatchPlayer: Codable, Hashable, Sendable, Identifiable {
    let player: PlayerCard
    let team: Int
    let courtSide: CourtSide
    let response: ResponseState
    let respondedAt: Date?
    let disputeReason: DisputeReason?
    let disputeComment: String?
    let ratingChange: RatingChange?
    var id: UUID { player.id }
}

nonisolated struct FeedbackEntry: Codable, Hashable, Sendable {
    let playerId: UUID
    let strengths: [String]
    let improvements: [String]
}

nonisolated struct MatchViewer: Codable, Hashable, Sendable {
    let isParticipant: Bool
    let team: Int?
    let response: ResponseState?
    let isCreator: Bool
    let canConfirm: Bool
    let canDispute: Bool
    let canEdit: Bool
    let canCancel: Bool
    let canGiveFeedback: Bool
    let feedback: [FeedbackEntry]?
}

nonisolated struct HeadToHead: Codable, Hashable, Sendable {
    let matches: Int
    let team1Wins: Int
}

nonisolated struct Partnerships: Codable, Hashable, Sendable {
    let team1: Int
    let team2: Int
}

nonisolated struct ProjectedChange: Codable, Hashable, Sendable {
    let delta: Double
    let muAfter: Double
}

nonisolated struct MatchAnalysis: Codable, Hashable, Sendable {
    let expectedWinTeam1: Double
    let upset: Bool
    let comeback: Bool
    let tiebreaks: Int
    let bagels: Int
    let gameShareTeam1: Double
    let headToHead: HeadToHead
    let partnerships: Partnerships
    let projectedChange: ProjectedChange?
}

nonisolated struct MatchClub: Codable, Hashable, Sendable {
    let id: Int
    let name: String
    let city: String?
}

nonisolated struct MatchDetail: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let matchType: MatchType
    let format: MatchFormat
    let status: MatchStatus
    let playedAt: Date
    let club: MatchClub?
    let sets: [SetScore]
    let winnerTeam: Int
    let team1Sets: Int
    let team2Sets: Int
    let team1Games: Int
    let team2Games: Int
    let version: Int
    let createdBy: UUID
    let createdAt: Date
    let updatedAt: Date
    let confirmedAt: Date?
    let expiresAt: Date?
    let ratingApplied: Bool
    let ratingWeight: Double?
    let players: [MatchPlayer]
    let viewer: MatchViewer
    let analysis: MatchAnalysis

    func team(_ number: Int) -> [MatchPlayer] {
        players.filter { $0.team == number }.sorted { $0.courtSide == .right && $1.courtSide != .right }
    }
}

// MARK: - Insights, compatibility, profiles

nonisolated enum Sentiment: String, Codable, Hashable, Sendable {
    case positive, neutral, attention
}

nonisolated struct Insight: Codable, Hashable, Sendable {
    let kind: String
    let sentiment: Sentiment
    let values: [String: JSONValue]
}

nonisolated struct CompatibilityComponent: Codable, Hashable, Sendable {
    let key: String
    let value: Double
    let weight: Double
}

nonisolated struct Compatibility: Codable, Hashable, Sendable {
    let score: Int
    let components: [CompatibilityComponent]
    let reasons: [[String: JSONValue]]
}

nonisolated struct CoachAssessment: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let coach: PlayerCard
    let scores: [String: Double]
    let createdAt: Date
    let note: String?
}

nonisolated struct ProfileViewer: Codable, Hashable, Sendable {
    let isMe: Bool
    let canAssess: Bool
}

nonisolated struct PlayerProfileResponse: Codable, Hashable, Sendable {
    let deleted: Bool
    let profile: Profile
    let rating: RatingSummary?
    let dna: PadelDNA?
    let stats: PlayerStats?
    let recentMatches: [MatchListItem]?
    let compatibility: Compatibility?
    let coachAssessments: [CoachAssessment]?
    let viewer: ProfileViewer?
}

nonisolated struct HomeResponse: Codable, Hashable, Sendable {
    let deleted: Bool
    let profile: Profile
    let rating: RatingSummary?
    let dna: PadelDNA?
    let stats: PlayerStats?
    let recentMatches: [MatchListItem]?
    let coachAssessments: [CoachAssessment]?
    let insights: [Insight]
    let actionItems: [MatchListItem]
    let openMatchesCount: Int
}

nonisolated struct RatingPoint: Codable, Hashable, Sendable, Identifiable {
    let at: Date
    let mu: Double
    let sigma: Double
    let delta: Double?
    let kind: String
    let matchId: UUID?
    let won: Bool?
    let expectedWin: Double?
    var id: Date { at }
}

nonisolated struct RatingHistory: Codable, Hashable, Sendable {
    let points: [RatingPoint]
    let peakMu: Double?
}

nonisolated struct SearchResult: Codable, Hashable, Sendable {
    let items: [PlayerCard]
    let total: Int
    let nextOffset: Int?
}

nonisolated struct City: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
    let countryCode: String
}

nonisolated struct Club: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
    let cityId: Int
    let playersCount: Int
}

nonisolated struct PreviewPlayer: Codable, Hashable, Sendable {
    let playerId: UUID
    let team: Int
    let ifTeam1Wins: Double
    let ifTeam2Wins: Double
    let withEnteredScore: Double?
}

nonisolated struct MatchPreview: Codable, Hashable, Sendable {
    let expectedWinTeam1: Double
    let team1Strength: Double
    let team2Strength: Double
    let weight: Double
    let players: [PreviewPlayer]
}

nonisolated struct CoachApplication: Codable, Hashable, Sendable {
    let player: PlayerCard
    let status: CoachStatus
    let experienceYears: Int
    let certification: String?
    let about: String
    let club: NamedRef?
    let submittedAt: Date
    let reviewedAt: Date?
    let reviewNote: String?
}

nonisolated struct UsernameCheck: Codable, Hashable, Sendable {
    let username: String
    let valid: Bool
    let available: Bool
    let reason: String?
}

// MARK: - Auth

nonisolated struct AuthUser: Codable, Hashable, Sendable {
    let id: UUID
    let email: String?
}

nonisolated struct Session: Codable, Hashable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let expiresAt: Int
    let user: AuthUser

    var expiryDate: Date { Date(timeIntervalSince1970: TimeInterval(expiresAt)) }
}

nonisolated struct SignupResponse: Codable, Hashable, Sendable {
    let session: Session?
    let recoveryKey: String
}

nonisolated struct RecoveryKeyResponse: Codable, Hashable, Sendable {
    let recoveryKey: String
}
