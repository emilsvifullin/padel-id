import SwiftUI

@main
struct PadelIDApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
        }
        .backgroundTask(.appRefresh(NotificationService.refreshTaskIdentifier)) {
            await BackgroundRefresh.run()
        }
    }
}

/// Periodic check for matches awaiting confirmation while the app is in the
/// background (local notifications + badge).
enum BackgroundRefresh {
    static func run() async {
        defer { NotificationService.shared.scheduleBackgroundRefresh() }
        guard SessionStore.shared.session != nil else { return }
        guard let page = try? await APIClient.shared.send(
            .get("v1/matches", query: [URLQueryItem(name: "scope", value: "open")]), as: MatchPage.self) else { return }
        await NotificationService.shared.process(actionItems: page.items.filter(\.needsAction))
    }
}
