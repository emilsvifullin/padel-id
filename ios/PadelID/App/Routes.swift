import SwiftUI
import Observation

/// Each tab (and the modal account) owns a separate, value-based path.
/// Async actions push into the same path as NavigationLink destinations.
@Observable
final class NavigationRouter {
    var path: [Route] = []
    /// Routes that have a card on screen to grow from. Plain rows keep the
    /// standard push.
    @ObservationIgnored var zoomSources: Set<Route> = []

    /// A late response must not reopen a screen the user already left.
    func push(_ route: Route, from source: [Route]) {
        guard path == source else { return }
        path.append(route)
    }
}

struct PadelNavigationStack<Content: View>: View {
    @State private var router = NavigationRouter()
    @Namespace private var zoom
    @ViewBuilder let content: () -> Content

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            content()
        }
        .environment(router)
        .environment(\.zoomNamespace, zoom)
        .padelTypesetting()
    }
}

/// The navigation stack of a sheet. A sheet does not take the typesetting
/// setting from the screen that presents it, so it is set again here.
struct SheetNavigationStack<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack { content() }.padelTypesetting()
    }
}

extension View {
    /// Russian text set by its own rules breaks words by syllable
    /// ("сохра-нён"); the system apps break between words. With no language
    /// to set the text in, a word breaks only when it is wider than its line.
    func padelTypesetting() -> some View {
        typesettingLanguage(Locale.Language(identifier: "und"))
    }
}

extension EnvironmentValues {
    /// The namespace cards and their destinations share inside one stack.
    @Entry var zoomNamespace: Namespace.ID?
}

private struct ZoomSource: ViewModifier {
    let route: Route
    @Environment(\.zoomNamespace) private var namespace
    @Environment(NavigationRouter.self) private var router: NavigationRouter?

    func body(content: Content) -> some View {
        if let namespace, let router {
            content
                .matchedTransitionSource(id: route, in: namespace)
                .onAppear { router.zoomSources.insert(route) }
                .onDisappear { if !router.path.contains(route) { router.zoomSources.remove(route) } }
        } else {
            content
        }
    }
}

private struct ZoomDestination: ViewModifier {
    let route: Route
    @Environment(\.zoomNamespace) private var namespace
    @Environment(NavigationRouter.self) private var router: NavigationRouter?

    func body(content: Content) -> some View {
        if let namespace, let router, router.zoomSources.contains(route) {
            content.navigationTransition(.zoom(sourceID: route, in: namespace))
        } else {
            content
        }
    }
}

extension View {
    /// A card its destination grows out of. The system swaps the zoom for a
    /// cross-fade under Reduce Motion.
    func zoomSource(_ route: Route) -> some View {
        modifier(ZoomSource(route: route))
    }
}

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
    case communityFeed
    case conversations
    case groups
    case friends
    case socialInbox
    case conversationMembers(UUID)
    case groupFeed(UUID)
    case socialPrivacy
    case socialPlayers(blocked: Bool)
    case sportsEvents
    case myEvents
    case coachTrainings(UUID)
    case club(Club, city: NamedRef)
    case clubEvents(Int, name: String)
    case clubNews(Int, name: String)
    case insights
    case analysis
    case conversation(UUID)
    case post(UUID)
    case event(UUID)
}

extension View {
    /// Registers all shared push destinations on a NavigationStack.
    func padelRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            Group {
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
            case .communityFeed: FeedView()
            case .conversations: ConversationsView()
            case .groups: GroupsView()
            case .friends: FriendsView(embedded: true)
            case .socialInbox: SocialInboxView()
            case .conversationMembers(let id): ConversationMembersView(conversationId: id)
            case .groupFeed(let id): FeedView(groupId: id)
            case .socialPrivacy: SocialPrivacyView()
            case .socialPlayers(let blocked): SocialPlayersListView(blocked: blocked)
            case .sportsEvents: EventsView()
            case .myEvents: EventsView(initialMine: true)
            case .coachTrainings(let id): EventsView(organizerId: id)
            case .club(let club, let city): ClubDetailView(club: club, city: city)
            case .clubEvents(let id, let name): ClubEventsView(clubID: id, name: name)
            case .clubNews(let id, let name): FeedView(clubId: id, clubName: name)
            case .insights: InsightsView()
            case .analysis: AnalysisView(embedded: true)
            case .conversation(let id): ChatView(id: id)
            case .post(let id): PostDetailView(id: id)
            case .event(let id): EventDetailView(eventId: id)
            }
            }
            .modifier(ZoomDestination(route: route))
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
