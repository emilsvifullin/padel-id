import SwiftUI

struct MainTabView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            Tab("Padel ID", systemImage: "person.text.rectangle", value: AppModel.Tab.padelID) {
                HomeView()
            }
            Tab("Матчи", systemImage: "sportscourt", value: AppModel.Tab.matches) {
                MatchesView()
            }
            .badge(app.actionCount)
            Tab("Игроки", systemImage: "magnifyingglass", value: AppModel.Tab.players, role: .search) {
                PlayersView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(item: $app.matchEditor) { request in
            MatchEditorView(request: request)
        }
        .sheet(isPresented: $app.isAccountPresented) {
            AccountView()
        }
    }
}
