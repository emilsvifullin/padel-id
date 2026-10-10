import SwiftUI

struct MainTabView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            Tab("Главная", systemImage: "house", value: AppModel.Tab.padelID) { HomeView() }
            Tab("Матчи", systemImage: "tennis.racket", value: AppModel.Tab.matches) { MatchesView() }
                .badge(app.actionCount)
            Tab("Анализ", systemImage: "chart.xyaxis.line", value: AppModel.Tab.analysis) { AnalysisView() }
            Tab("Друзья", systemImage: "person.2", value: AppModel.Tab.friends) { FriendsView() }
            Tab("Профиль", systemImage: "person.crop.circle", value: AppModel.Tab.profile) { AccountView() }
        }
        .tabBarMinimizeBehavior(.never)
        .sheet(item: $app.matchEditor) { request in MatchEditorView(request: request) }
    }
}
