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
        NavigationStack {
            List {
                profileSection
                styleSection
                coachSection
                if app.me?.isAdmin == true {
                    adminSection
                }
                AccountNotificationsSection()
                securitySection
                aboutSection
                signOutSection
                deleteSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Аккаунт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .confirmationDialog("Выйти из аккаунта?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
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
                NavigationLink {
                    EditProfileView(profile: profile)
                } label: {
                    AccountHeaderRow(profile: profile, email: app.me?.email)
                }
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

private struct AccountHeaderRow: View {
    let profile: Profile
    let email: String?

    var body: some View {
        HStack(spacing: 14) {
            AvatarView(profile: profile, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                if let email, !email.isEmpty {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Изменить профиль")
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

    var body: some View {
        Section {
            Toggle(isOn: toggleBinding) {
                Label("Напоминать о подтверждении матчей", systemImage: "bell.badge")
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
        } header: {
            Text("Уведомления")
        } footer: {
            Text("Напоминания приходят, когда iOS обновляет приложение в фоне, — время выбирает система.")
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
