import SwiftUI

@main
struct PadelIDApp: App {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.automatic.rawValue

    init() { Theme.applyNavigationTypography() }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .tint(Theme.accent)
                .headerProminence(.increased)
                .padelTypesetting()
                .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
        }
    }
}
