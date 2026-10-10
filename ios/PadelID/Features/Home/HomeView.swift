import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var upcoming = Resource<UpcomingPage>(cacheKey: CacheKey.upcomingHome) {
        .get("v1/upcoming-matches", query: [URLQueryItem(name: "scope", value: "mine"), URLQueryItem(name: "accepted_only", value: "true")])
    }

    var body: some View {
        NavigationStack {
            Group {
                if let page = upcoming.value {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                            if upcoming.isStale, let error = upcoming.error { StaleDataBanner(error: error) }
                            if let match = page.items.filter({ $0.viewer.participation == "accepted" && $0.startsAt > .now && !$0.isClosed })
                                .min(by: { $0.startsAt < $1.startsAt }) {
                                Text("Ваша ближайшая игра").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                                NavigationLink(value: Route.upcoming(match.id)) {
                                    SectionContainer { UpcomingMatchRow(match: match) }
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("home.upcoming")
                            } else {
                                ContentUnavailableView {
                                    Label("Следующая игра — впереди", systemImage: "tennis.racket")
                                } description: {
                                    Text("Найдите открытую игру или соберите свою. Здесь появится ближайший матч, в котором вы участвуете.")
                                } actions: {
                                    Button("Найти игру") { app.selectedTab = .matches }
                                        .buttonStyle(.borderedProminent)
                                }
                                .accessibilityIdentifier("home.empty")
                            }
                        }
                        .padding(Theme.horizontalPadding)
                    }
                    .refreshable { await upcoming.load(using: app) }
                } else if let error = upcoming.error {
                    ErrorStateView(error: error) { Task { await upcoming.load(using: app) } }
                } else { LoadingView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Главная")
            .padelRoutes()
        }
        .task(id: app.dataRevision) { await upcoming.load(using: app) }
        .task(id: app.dataRevision) {
            if let home = try? await app.api.send(.get("v1/home"), as: HomeResponse.self) {
                app.actionCount = home.actionItems.count
                await NotificationService.shared.process(actionItems: home.actionItems)
            }
        }
    }
}
