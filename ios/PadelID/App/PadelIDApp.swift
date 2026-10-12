import SwiftUI

@main
struct PadelIDApp: App {
    @UIApplicationDelegateAdaptor(NotificationAppDelegate.self) private var notificationDelegate
    @State private var app = AppModel()
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.automatic.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(Theme.accent)
                .preferredColorScheme((AppAppearance(rawValue: appearance) ?? .automatic).colorScheme)
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
        if let page = try? await APIClient.shared.send(
            .get("v1/matches", query: [URLQueryItem(name: "scope", value: "open")]), as: MatchPage.self) {
            await NotificationService.shared.process(actionItems: page.items.filter(\.needsAction))
        }
        if let activity = try? await APIClient.shared.send(.get("v1/notifications"), as: CommunityPage<SocialNotification>.self) {
            await NotificationService.shared.process(activity: activity.items)
        }
    }
}
