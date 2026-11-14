import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Главная", systemImage: "house") {
                NavigationStack {
                    HomeView()
                }
            }

            Tab("Оформление", systemImage: "paintpalette") {
                NavigationStack {
                    AppearanceSettingsView()
                }
            }
        }
        .tabBarMinimizeBehavior(.never)
    }
}
