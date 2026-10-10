import SwiftUI

/// Push destinations shared by every tab's NavigationStack.
enum Route: Hashable {
    case player(UUID)
    case match(UUID)
    case rating(UUID)
    case dna(UUID)
    case playerMatches(UUID)
    case stats(UUID)
    case upcoming(UUID)
    case upcomingGames
    case findPlayers
    case insights
}

extension View {
    /// Registers all shared push destinations on a NavigationStack.
    func padelRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .player(let id): PlayerProfileView(playerId: id)
            case .match(let id): MatchDetailView(matchId: id)
            case .rating(let id): RatingDetailView(playerId: id)
            case .dna(let id): DNADetailView(playerId: id)
            case .playerMatches(let id): PlayerMatchesView(playerId: id)
            case .stats(let id): StatsDetailView(playerId: id)
            case .upcoming(let id): UpcomingDetailView(matchId: id)
            case .upcomingGames: UpcomingListView()
            case .findPlayers: PlayersView()
            case .insights: InsightsView()
            }
        }
    }
}

/// Request to open the match editor (presented as a sheet by MainTabView).
struct MatchEditorRequest: Identifiable {
    enum Mode {
        /// New match; optional players to pre-fill (the current user is always team 1, right).
        case create(partner: PlayerCard?, opponents: [PlayerCard])
        /// Edit an existing pending/disputed match created by the current user.
        case edit(MatchDetail)
        case upcoming(UpcomingMatch, playerId: UUID)
    }

    let id = UUID()
    let mode: Mode

    static var blank: MatchEditorRequest { MatchEditorRequest(mode: .create(partner: nil, opponents: [])) }
}
