import SwiftUI

/// Permanent account deletion, confirmed with the password.
struct DeleteAccountView: View {
    @Environment(AppModel.self) private var app
    @State private var password = ""
    @State private var isConfirming = false
    @State private var isDeleting = false
    @State private var error: APIError?
    @State private var failureCount = 0

    var body: some View {
        Form {
            if !app.isOnline {
                Section {
                    SettingsOfflineNotice(message: "Нет подключения к интернету. Удалить аккаунт можно только онлайн.")
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Label {
                        Text("Удаление нельзя отменить")
                            .font(.headline)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.negative)
                    }
                    DeleteAccountPoint(text: "Профиль, фото, Padel DNA, самооценка, оценки тренеров и заявка тренера будут удалены вместе с личными данными.")
                    DeleteAccountPoint(text: "Подтверждённые матчи останутся в истории других игроков — вместо вашего имени они увидят «Удалённый игрок».")
                    DeleteAccountPoint(text: "Матчи, которые ещё ждут подтверждения, будут отменены.")
                    DeleteAccountPoint(text: "Восстановить аккаунт будет невозможно, даже с ключом восстановления.")
                }
                .padding(.vertical, 6)
            }
            Section {
                SecureField("Пароль", text: $password)
                    .keyboardType(.asciiCapable)
                    .textContentType(.password)
                    .submitLabel(.done)
            } footer: {
                if let error {
                    Text(error.message)
                        .foregroundStyle(Theme.negative)
                } else {
                    Text("Введите пароль, чтобы подтвердить удаление.")
                }
            }
            Section {
                SettingsActionButton(title: "Удалить аккаунт", role: .destructive, isWorking: isDeleting) {
                    isConfirming = true
                }
                .disabled(!canDelete)
                .confirmationDialog("Удалить аккаунт навсегда?", isPresented: $isConfirming, titleVisibility: .visible) {
                    Button("Удалить аккаунт", role: .destructive, action: deleteAccount)
                    Button("Отмена", role: .cancel) {}
                } message: {
                    Text("Профиль и личные данные будут удалены без возможности восстановления.")
                }
            }
        }
        .disabled(isDeleting)
        .navigationTitle("Удаление аккаунта")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isDeleting)
        .onChange(of: password) { error = nil }
        .sensoryFeedback(.error, trigger: failureCount)
    }

    private var canDelete: Bool {
        !password.isEmpty && app.isOnline && !isDeleting
    }

    private func deleteAccount() {
        guard canDelete else { return }
        let body = ["password": password]
        isDeleting = true
        error = nil
        Task {
            do {
                try await app.api.sendVoid(.json(.delete, "v1/account", body))
                app.isAccountPresented = false
                app.resetLocalState(notice: "Аккаунт удалён.")
            } catch is CancellationError {
                isDeleting = false
            } catch let apiError as APIError {
                error = apiError
                failureCount += 1
                isDeleting = false
            } catch {
                self.error = APIError(kind: .decoding, code: "decoding", serverMessage: nil)
                failureCount += 1
                isDeleting = false
            }
        }
    }
}

private struct DeleteAccountPoint: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("•")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
