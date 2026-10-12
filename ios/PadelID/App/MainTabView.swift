import SwiftUI

struct MainTabView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            Tab("Главная", systemImage: "house", value: AppModel.Tab.padelID) { HomeView() }
            Tab("Матчи", systemImage: "tennis.racket", value: AppModel.Tab.matches) { MatchesView() }
                .badge(app.actionCount)
            Tab("Клубы", systemImage: "sportscourt", value: AppModel.Tab.clubs) { ClubsView() }
            Tab("Сообщество", systemImage: "person.3", value: AppModel.Tab.community) { CommunityView() }
            Tab("Профиль", systemImage: "person.crop.circle", value: AppModel.Tab.profile) { AccountView() }
        }
        .tabBarMinimizeBehavior(.never)
        .sheet(item: $app.matchEditor) { request in MatchEditorView(request: request) }
        .sheet(isPresented: $app.isAccountPresented) {
            AccountView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") { app.isAccountPresented = false }
                    }
                }
        }
    }
}
