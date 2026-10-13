import SwiftUI
import UIKit
import UserNotifications

/// Account and settings, presented as a sheet above the tabs
/// (`app.isAccountPresented`).
struct AccountView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingSignOut = false
    @State private var isSigningOut = false

    var body: some View {
        PadelNavigationStack {
            List {
                profileSection
                Section {
                    NavigationLink(value: Route.analysis) {
                        Label("Анализ игры", systemImage: "chart.xyaxis.line")
                    }.accessibilityIdentifier("account.analysis")
                    NavigationLink(value: Route.myEvents) {
                        Label("Мои тренировки и турниры", systemImage: "calendar")
                    }.accessibilityIdentifier("account.myEvents")
                }
                Section {
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        Label("Оформление", systemImage: "paintpalette")
                    }
                    .accessibilityIdentifier("account.appearance")
                }
                styleSection
                coachSection
                if app.me?.isAdmin == true {
                    adminSection
                }
                AccountNotificationsSection()
                securitySection
                Section {
                    NavigationLink(value: Route.socialPrivacy) {
                        Label("Приватность и общение", systemImage: "hand.raised")
                    }.accessibilityIdentifier("account.privacy")
                }
                aboutSection
                signOutSection
                deleteSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Профиль")
            .navigationBarTitleDisplayMode(.large)
            .padelRoutes()
            .alert("Выйти из аккаунта?", isPresented: $isConfirmingSignOut) {
                Button("Выйти", role: .destructive, action: signOut)
                Button("Отмена", role: .cancel) {}
            } message: {
                Text(signOutMessage)
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var profileSection: some View {
        Section {
            if let profile = app.me?.profile {
                // The card is the row: a hidden link keeps list navigation
                // without a system chevron on the graphite surface.
                ZStack {
                    NavigationLink {
                        EditProfileView(profile: profile)
                    } label: { EmptyView() }
                    .opacity(0)
                    AccountHeaderRow(profile: profile, email: app.me?.email, rating: app.me?.rating)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([profile.displayName, profile.username.map { "@" + $0 }, app.me?.email]
                    .compactMap { $0 }.joined(separator: ", "))
                .accessibilityHint("Изменить профиль")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("account.editProfile")
            } else if let email = app.me?.email {
                Text(email)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var styleSection: some View {
        Section {
            NavigationLink {
                SettingsDNASelfView(dnaSelf: app.me?.dnaSelf)
            } label: {
                Label("Самооценка стиля игры", systemImage: "hexagon")
            }
        } header: {
            Text("Padel DNA")
        } footer: {
            Text("Стартовая точка вашего Padel DNA. Отметки партнёров, соперников и тренеров постепенно уточняют профиль.")
        }
    }

    private var coachSection: some View {
        Section {
            NavigationLink {
                CoachApplicationView()
            } label: {
                LabeledContent {
                    if let status = app.me?.coachStatus {
                        Text(CoachApplicationCopy.status(status))
                    }
                } label: {
                    Label("Статус тренера", systemImage: "checkmark.seal")
                }
            }
        } header: {
            Text("Тренерам")
        } footer: {
            Text("Подтверждённые тренеры оценивают навыки игроков — их оценки подтверждают Padel DNA.")
        }
    }

    private var adminSection: some View {
        Section {
            NavigationLink {
                CoachReviewView()
            } label: {
                Label("Заявки тренеров", systemImage: "checkmark.shield")
            }
            NavigationLink { ModerationReportsView() } label: {
                Label("Жалобы сообщества", systemImage: "flag")
            }
        } header: {
            Text("Администрирование")
        }
    }

    private var securitySection: some View {
        Section {
            NavigationLink {
                SecurityView()
            } label: {
                Label("Безопасность", systemImage: "lock")
            }
            .accessibilityIdentifier("account.security")
        } footer: {
            Text("Почта, пароль и ключ восстановления.")
        }
    }

    private var aboutSection: some View {
        Section {
            NavigationLink {
                AboutRatingView()
            } label: {
                Label("Как устроены рейтинг и Padel DNA", systemImage: "book")
            }
            .accessibilityIdentifier("account.aboutRating")
            NavigationLink {
                NetworkDiagnosticsView()
            } label: {
                Label("Проверка сети", systemImage: "network")
            }
            LabeledContent("Версия", value: AppEnvironment.version)
            LabeledContent("Сборка", value: AppEnvironment.buildNumber)
        } header: {
            Text("О приложении")
        }
    }

    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                isConfirmingSignOut = true
            } label: {
                HStack {
                    Text("Выйти")
                    Spacer()
                    if isSigningOut {
                        ProgressView()
                    }
                }
            }
            .disabled(isSigningOut)
            .accessibilityIdentifier("account.signOut")
        }
    }

    private var deleteSection: some View {
        Section {
            NavigationLink {
                DeleteAccountView()
            } label: {
                Text("Удалить аккаунт")
                    .foregroundStyle(Theme.negative)
            }
            .accessibilityIdentifier("account.deleteAccount")
        }
    }

    // MARK: Sign out

    private var signOutMessage: String {
        let count = app.outbox.operations.count
        guard count > 0 else {
            return "Чтобы вернуться, войдите с той же почтой и паролем."
        }
        let changes = Format.count(count, "неотправленное изменение", "неотправленных изменения", "неотправленных изменений")
        let verb = Format.plural(count, "будет удалено", "будут удалены", "будут удалены")
        let pronoun = Format.plural(count, "его", "их", "их")
        return "На этом устройстве \(changes) — после выхода \(Format.plural(count, "оно", "они", "они")) \(verb). Подключитесь к интернету и дождитесь отправки, чтобы сохранить \(pronoun)."
    }

    private func signOut() {
        isSigningOut = true
        Task {
            await app.signOut()
            app.isAccountPresented = false
            isSigningOut = false
        }
    }
}

// MARK: - Header

/// The player on the graphite of the alternate icon: who they are and where
/// their rating stands. Opens profile editing.
private struct AccountHeaderRow: View {
    let profile: Profile
    let email: String?
    let rating: RatingSummary?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) { avatar; Spacer(minLength: 4); editMark }
                    identity
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    avatar
                    identity
                    Spacer(minLength: 4)
                    editMark
                }
            }
            if let rating {
                Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) { level(rating); reliability(rating); matches(rating) }
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        level(rating).frame(maxWidth: .infinity, alignment: .leading)
                        reliability(rating).frame(maxWidth: .infinity, alignment: .leading)
                        matches(rating).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inkCard()
    }

    private var avatar: some View {
        AvatarView(profile: profile, size: 64)
            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(profile.displayName)
                .font(.display(.title3, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            if let username = profile.username {
                Text("@" + username).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let email, !email.isEmpty {
                Text(email).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var editMark: some View {
        Image(systemName: "pencil")
            .font(.footnote.weight(.bold))
            .frame(width: 32, height: 32)
            .background(.white.opacity(0.12), in: .circle)
    }

    private func level(_ rating: RatingSummary) -> some View {
        fact(Format.level(rating.mu), "Уровень")
    }

    private func reliability(_ rating: RatingSummary) -> some View {
        fact("\(rating.reliability)%", "Надёжность")
    }

    private func matches(_ rating: RatingSummary) -> some View {
        fact("\(rating.rankedMatches)", "Рейтинговых")
    }

    private func fact(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.display(.title3, weight: .bold)).monospacedDigit().foregroundStyle(Theme.lime)
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.75))
        }
    }
}

// MARK: - Notifications

private struct AccountNotificationsSection: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var isEnabled = NotificationService.shared.isEnabled
    @State private var isRequesting = false
    @State private var showsDeniedHint = false
    @State private var toggleCount = 0
    @State private var remotePush = RemotePushService.shared

    var body: some View {
        Section {
            Toggle(isOn: toggleBinding) {
                Label("Уведомления и напоминания", systemImage: "bell.badge")
            }
            .disabled(isRequesting)
            .sensoryFeedback(.selection, trigger: toggleCount)
            .task { await refreshAuthorization() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await refreshAuthorization() }
            }
            if showsDeniedHint {
                Text("Уведомления для Padel ID выключены в настройках iPhone. Разрешите их, чтобы получать напоминания.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Открыть настройки", action: openSettings)
            }
            if AppEnvironment.remotePushEnabled, remotePush.state == .pending {
                Text("Не удалось синхронизировать уведомления. Повторите при подключении к интернету.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Повторить") { Task { await remotePush.synchronize() } }
            }
        } header: {
            Text("Уведомления")
        } footer: {
            Text(AppEnvironment.remotePushEnabled
                 ? "Получайте сообщения о новых событиях. Настройки сообщений и активности находятся в разделе конфиденциальности сообщества."
                 : "Напоминания приходят, когда iOS обновляет приложение в фоне, — время выбирает система.")
        }
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { newValue in
                toggleCount += 1
                if newValue {
                    enable()
                } else {
                    disable()
                }
            })
    }

    private func enable() {
        isEnabled = true
        isRequesting = true
        Task {
            let granted = await NotificationService.shared.requestAuthorization()
            isEnabled = granted
            showsDeniedHint = !granted
            isRequesting = false
        }
    }

    private func disable() {
        NotificationService.shared.isEnabled = false
        isEnabled = false
        showsDeniedHint = false
    }

    /// Mirrors the system permission: a reminder switched on in the app but
    /// denied in iOS Settings is shown as off with an explanation.
    private func refreshAuthorization() async {
        let status = await NotificationService.shared.authorizationStatus()
        if status == .denied {
            if NotificationService.shared.isEnabled {
                showsDeniedHint = true
            }
            isEnabled = false
        } else {
            isEnabled = NotificationService.shared.isEnabled
            showsDeniedHint = false
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

// MARK: - Shared settings components

/// Explains why an action that needs the network is unavailable right now.
struct SettingsOfflineNotice: View {
    var message = "Нет подключения к интернету. Изменения можно будет сохранить, когда связь восстановится."

    var body: some View {
        Label(message, systemImage: "wifi.slash")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

/// "34/160" character counter for limited text fields.
struct SettingsCharacterCount: View {
    let count: Int
    let limit: Int

    var body: some View {
        Text(String(count) + "/" + String(limit))
            .monospacedDigit()
            .foregroundStyle(count > limit ? Theme.negative : Color.secondary)
            .accessibilityLabel(String(count) + " из " + String(limit) + " символов")
    }
}

/// Inline error row for forms.
struct SettingsErrorRow: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.subheadline)
        .foregroundStyle(Theme.negative)
    }
}

/// A form button row with an inline progress indicator.
struct SettingsActionButton: View {
    let title: String
    var role: ButtonRole?
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                if isWorking {
                    ProgressView()
                }
            }
        }
    }
}

nonisolated enum SettingsText {
    /// Character count as the server measures it (`char_length` counts code points).
    static func length(_ text: String) -> Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
