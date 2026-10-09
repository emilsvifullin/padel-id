import SwiftUI

/// Email, password, recovery key and sessions.
struct SecurityView: View {
    @Environment(AppModel.self) private var app
    @State private var isConfirmingGlobalSignOut = false
    @State private var isSigningOut = false
    @State private var signOutError: APIError?

    var body: some View {
        List {
            if !app.isOnline {
                Section {
                    SettingsOfflineNotice(message: "Нет подключения к интернету. Изменить почту, пароль или ключ восстановления можно только онлайн.")
                }
            }
            Section {
                NavigationLink {
                    ChangeEmailView()
                } label: {
                    LabeledContent {
                        Text(app.me?.email ?? "—")
                    } label: {
                        Label("Почта", systemImage: "envelope")
                    }
                }
                NavigationLink {
                    ChangePasswordView()
                } label: {
                    Label("Пароль", systemImage: "lock")
                }
            } footer: {
                Text("Почта — ваш логин для входа. Её видите только вы.")
            }

            Section {
                NavigationLink {
                    SecurityRecoveryKeyView()
                } label: {
                    LabeledContent {
                        Text(recoveryKeySummary)
                    } label: {
                        Label("Ключ восстановления", systemImage: "key.horizontal")
                    }
                }
            } footer: {
                Text("Ключ возвращает доступ к аккаунту, если вы забудете пароль.")
            }

            Section {
                SettingsActionButton(title: "Выйти на всех устройствах", role: .destructive, isWorking: isSigningOut) {
                    isConfirmingGlobalSignOut = true
                }
                .disabled(!app.isOnline || isSigningOut)
                .confirmationDialog("Выйти на всех устройствах?", isPresented: $isConfirmingGlobalSignOut, titleVisibility: .visible) {
                    Button("Выйти везде", role: .destructive, action: signOutEverywhere)
                    Button("Отмена", role: .cancel) {}
                } message: {
                    Text(globalSignOutMessage)
                }
                .alert("Не удалось завершить сеансы", isPresented: Binding(
                    get: { signOutError != nil },
                    set: { if !$0 { signOutError = nil } }
                )) {
                    Button("ОК", role: .cancel) {}
                } message: {
                    Text((signOutError?.message ?? "") + " Другие устройства пока остаются в аккаунте — попробуйте ещё раз.")
                }
            } footer: {
                Text(app.isOnline
                     ? "Завершает все сеансы, включая этот. На каждом устройстве нужно будет войти заново."
                     : "Нужно подключение к интернету.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Безопасность")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var recoveryKeySummary: String {
        guard let created = app.me?.recoveryKeyCreatedAt else { return "Не создан" }
        return Format.shortDate(created)
    }

    private var globalSignOutMessage: String {
        let count = app.outbox.operations.count
        guard count > 0 else {
            return "Сеансы на всех устройствах будут завершены, включая этот."
        }
        let changes = Format.count(count, "неотправленное изменение", "неотправленных изменения", "неотправленных изменений")
        return "Сеансы на всех устройствах будут завершены, включая этот. \(changes.capitalizedFirst) на этом устройстве \(Format.plural(count, "будет удалено", "будут удалены", "будут удалены"))."
    }

    private func signOutEverywhere() {
        guard app.isOnline else { return }
        isSigningOut = true
        Task {
            do {
                try await app.signOutEverywhere()
                app.isAccountPresented = false
            } catch let error as APIError {
                signOutError = error
            } catch {}
            isSigningOut = false
        }
    }
}

// MARK: - Email

struct ChangeEmailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var error: APIError?
    @State private var successCount = 0
    @State private var failureCount = 0
    @FocusState private var focus: Field?

    enum Field { case email, password }

    var body: some View {
        Form {
            if !app.isOnline {
                Section {
                    SettingsOfflineNotice()
                }
            }
            Section {
                LabeledContent("Текущая почта", value: app.me?.email ?? "—")
            }
            Section {
                TextField("Новая почта", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                SecureField("Текущий пароль", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.done)
                    .onSubmit(submit)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if isSameEmail {
                        Text("Это ваша текущая почта.")
                    } else {
                        Text("Новая почта сразу станет логином для входа. Пароль нужен, чтобы подтвердить изменение.")
                    }
                    if let error {
                        Text(message(for: error))
                            .foregroundStyle(Theme.negative)
                    }
                }
            }
            Section {
                SettingsActionButton(title: "Изменить почту", isWorking: isSubmitting, action: submit)
                    .disabled(!canSubmit)
            }
        }
        .disabled(isSubmitting)
        .navigationTitle("Почта")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focus = .email }
        .onChange(of: email) { error = nil }
        .onChange(of: password) { error = nil }
        .sensoryFeedback(.success, trigger: successCount)
        .sensoryFeedback(.error, trigger: failureCount)
    }

    private var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isSameEmail: Bool {
        guard let current = app.me?.email else { return false }
        return !normalizedEmail.isEmpty && normalizedEmail == current.lowercased()
    }

    private var canSubmit: Bool {
        PasswordPolicy.isPlausibleEmail(normalizedEmail) && !isSameEmail && !password.isEmpty
            && app.isOnline && !isSubmitting
    }

    private func message(for error: APIError) -> String {
        error.code == "email_taken" ? "Эта почта уже используется другим аккаунтом." : error.message
    }

    private func submit() {
        guard canSubmit else { return }
        let body = ["new_email": normalizedEmail, "password": password]
        isSubmitting = true
        error = nil
        Task {
            defer { isSubmitting = false }
            do {
                let data = try await app.api.data(.json(.post, "v1/account/email", body))
                let me = try JSONCoding.decoder.decode(Me.self, from: data)
                app.cache.store(data, for: CacheKey.me)
                app.apply(me: me)
                app.dataDidChange()
                successCount += 1
                dismiss()
            } catch is CancellationError {
                return
            } catch let apiError as APIError {
                error = apiError
                failureCount += 1
            } catch {
                self.error = APIError(kind: .decoding, code: "decoding", serverMessage: nil)
                failureCount += 1
            }
        }
    }
}

// MARK: - Password

struct ChangePasswordView: View {
    @Environment(AppModel.self) private var app
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var isSubmitting = false
    @State private var didChange = false
    @State private var error: APIError?
    @State private var successCount = 0
    @State private var failureCount = 0
    @FocusState private var focus: Field?

    enum Field { case current, replacement }

    var body: some View {
        Form {
            if !app.isOnline {
                Section {
                    SettingsOfflineNotice()
                }
            }
            if didChange {
                Section {
                    Label("Пароль изменён. На других устройствах нужно будет войти заново.", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.positive)
                }
            }
            Section {
                SecureField("Текущий пароль", text: $currentPassword)
                    .textContentType(.password)
                    .focused($focus, equals: .current)
                    .submitLabel(.next)
                    .onSubmit { focus = .replacement }
            }
            Section {
                SecureField("Новый пароль", text: $newPassword)
                    .newPasswordContentType()
                    .focused($focus, equals: .replacement)
                    .submitLabel(.done)
                    .onSubmit(submit)
            }
            // The live requirements stay out of the password field's section:
            // updating that section while typing restarts editing, and a
            // secure field clears itself on the next keystroke.
            Section {
                SettingsActionButton(title: "Изменить пароль", isWorking: isSubmitting, action: submit)
                    .disabled(!canSubmit)
            } header: {
                VStack(alignment: .leading, spacing: 8) {
                    PasswordRequirements(password: newPassword)
                    if isSamePassword {
                        Text("Новый пароль совпадает с текущим.")
                            .foregroundStyle(Theme.negative)
                    }
                    if let error {
                        Text(error.message)
                            .foregroundStyle(Theme.negative)
                    }
                }
                .textCase(nil)
            } footer: {
                Text("После смены пароля другие устройства выйдут из аккаунта.")
            }
        }
        .disabled(isSubmitting)
        .navigationTitle("Пароль")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: currentPassword) { error = nil }
        .onChange(of: newPassword) { _, value in
            error = nil
            if !value.isEmpty { didChange = false }
        }
        .sensoryFeedback(.success, trigger: successCount)
        .sensoryFeedback(.error, trigger: failureCount)
    }

    private var isSamePassword: Bool {
        !newPassword.isEmpty && newPassword == currentPassword
    }

    private var canSubmit: Bool {
        !currentPassword.isEmpty && PasswordPolicy.isValid(newPassword) && !isSamePassword
            && app.isOnline && !isSubmitting
    }

    private func submit() {
        guard canSubmit else { return }
        let body = ["current_password": currentPassword, "new_password": newPassword]
        isSubmitting = true
        error = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await app.api.sendVoid(.json(.post, "v1/account/password", body))
                currentPassword = ""
                newPassword = ""
                focus = nil
                didChange = true
                successCount += 1
            } catch is CancellationError {
                return
            } catch let apiError as APIError {
                error = apiError
                failureCount += 1
            } catch {
                self.error = APIError(kind: .decoding, code: "decoding", serverMessage: nil)
                failureCount += 1
            }
        }
    }
}

// MARK: - Recovery key

private struct SecurityRecoveryKeyView: View {
    @Environment(AppModel.self) private var app
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var error: APIError?
    @State private var issuedKey: String?
    @State private var failureCount = 0

    var body: some View {
        Form {
            if !app.isOnline {
                Section {
                    SettingsOfflineNotice()
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ключ восстановления — 20 символов, которые возвращают доступ к аккаунту, если вы забудете пароль.")
                    Text("Мы не храним ключ в открытом виде, поэтому показать действующий ключ ещё раз нельзя. Если он потерян, создайте новый — старый сразу перестанет действовать.")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .padding(.vertical, 4)
                LabeledContent("Текущий ключ создан", value: createdText)
            }
            Section {
                SecureField("Пароль", text: $password)
                    .textContentType(.password)
                    .submitLabel(.done)
                    .onSubmit(submit)
            } header: {
                Text("Новый ключ")
            } footer: {
                if let error {
                    Text(error.message)
                        .foregroundStyle(Theme.negative)
                } else {
                    Text("Введите пароль от аккаунта, чтобы создать новый ключ.")
                }
            }
            Section {
                SettingsActionButton(title: "Создать новый ключ", isWorking: isSubmitting, action: submit)
                    .disabled(!canSubmit)
            }
        }
        .disabled(isSubmitting)
        .navigationTitle("Ключ восстановления")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: password) { error = nil }
        .sensoryFeedback(.error, trigger: failureCount)
        .fullScreenCover(isPresented: Binding(
            get: { issuedKey != nil },
            set: { if !$0 { issuedKey = nil } }
        )) {
            if let key = issuedKey {
                RecoveryKeyView(recoveryKey: key) {
                    issuedKey = nil
                }
            }
        }
    }

    private var createdText: String {
        guard let created = app.me?.recoveryKeyCreatedAt else { return "Нет данных" }
        return Format.date(created)
    }

    private var canSubmit: Bool {
        !password.isEmpty && app.isOnline && !isSubmitting
    }

    private func submit() {
        guard canSubmit else { return }
        let body = ["password": password]
        isSubmitting = true
        error = nil
        Task {
            defer { isSubmitting = false }
            do {
                let response = try await app.api.send(.json(.post, "v1/account/recovery-key", body), as: RecoveryKeyResponse.self)
                password = ""
                // Shown right here, above the account sheet: the key exists only in this response.
                issuedKey = response.recoveryKey
                await app.refreshMe()
            } catch is CancellationError {
                return
            } catch let apiError as APIError {
                error = apiError
                failureCount += 1
            } catch {
                self.error = APIError(kind: .decoding, code: "decoding", serverMessage: nil)
                failureCount += 1
            }
        }
    }
}
