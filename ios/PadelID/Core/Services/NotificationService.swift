import BackgroundTasks
import Foundation
import UserNotifications

/// Local notifications about matches awaiting the user's confirmation. Remote
/// push is not used (it would require a paid developer account entitlement);
/// instead the app checks periodically with background app refresh.
final class NotificationService {
    static let shared = NotificationService()
    static let refreshTaskIdentifier = "app.padelid.refresh"

    private let notifiedKey = "notifiedMatchIds"
    private let enabledKey = "matchNotificationsEnabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Requests permission; returns whether notifications are allowed.
    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        isEnabled = granted
        if granted { scheduleBackgroundRefresh() }
        return granted
    }

    func scheduleBackgroundRefresh() {
        guard isEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Posts one notification per newly pending match and updates the badge.
    func process(actionItems: [MatchListItem]) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        if settings.badgeSetting == .enabled {
            try? await center.setBadgeCount(actionItems.count)
        }
        guard isEnabled else { return }
        var notified = Set(UserDefaults.standard.stringArray(forKey: notifiedKey) ?? [])
        // Keyed by version and status: an edited (or again disputed) match is news.
        for item in actionItems where !notified.contains(Self.notificationKey(item)) {
            let content = UNMutableNotificationContent()
            // Names and scores stay inside the app: notifications can be read
            // on the lock screen.
            if item.status == .disputed && item.isCreator {
                content.title = "Результат оспорен"
                content.body = "Проверьте возражение и исправьте счёт или отмените матч."
            } else {
                content.title = "Подтвердите результат"
                content.body = "\(Narratives.matchType(item.matchType)) матч ждёт вашего подтверждения."
            }
            content.sound = .default
            content.threadIdentifier = "matches"
            content.userInfo = ["matchId": item.id.uuidString]
            let request = UNNotificationRequest(identifier: "match-\(item.id.uuidString)", content: content, trigger: nil)
            try? await center.add(request)
            notified.insert(Self.notificationKey(item))
        }
        UserDefaults.standard.set(Array(notified.sorted().suffix(300)), forKey: notifiedKey)
    }

    private static func notificationKey(_ item: MatchListItem) -> String {
        "\(item.id.uuidString).\(item.version).\(item.status.rawValue)"
    }

    func clearBadge() async {
        try? await UNUserNotificationCenter.current().setBadgeCount(0)
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}
