import SwiftUI

/// Password rules shared with the server: ≥ 8 characters, letters and digits.
enum PasswordPolicy {
    static func isValid(_ password: String) -> Bool {
        password.count >= 8 && password.utf8.count <= 72 && hasLetter(password) && hasDigit(password)
            && Set(password).count > 1
    }

    static func hasLetter(_ value: String) -> Bool { value.contains { $0.isLetter } }
    /// ASCII digits only, the same rule as the server.
    static func hasDigit(_ value: String) -> Bool { value.contains { $0.isASCII && $0.isNumber } }

    static func isPlausibleEmail(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let at = trimmed.firstIndex(of: "@"), at != trimmed.startIndex else { return false }
        let domain = trimmed[trimmed.index(after: at)...]
        return domain.contains(".") && !domain.hasSuffix(".") && !trimmed.contains(" ")
    }
}

struct PasswordRequirements: View {
    let password: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            requirement("Не меньше 8 символов", met: password.count >= 8)
            requirement("Буквы и цифры", met: PasswordPolicy.hasLetter(password) && PasswordPolicy.hasDigit(password))
        }
        .font(.footnote)
    }

    private func requirement(_ text: String, met: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(met ? Theme.positive : .secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text + (met ? ", выполнено" : ", не выполнено"))
    }
}

extension View {
    /// Content type of a field for a new password: `.newPassword` lets iOS
    /// suggest a strong password. UI tests get `.password`, because the
    /// automatic strong-password sheet swallows synthesized typing.
    func newPasswordContentType() -> some View {
        let contentType: UITextContentType = AppEnvironment.isUITesting ? .password : .newPassword
        return textContentType(contentType)
    }
}

/// Full-width primary action of the authentication forms (a form row, so a
/// regular prominent button: Liquid Glass is for floating action bars).
struct AuthPrimaryButton: View {
    let title: String
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title)
                    .opacity(isBusy ? 0 : 1)
                if isBusy {
                    ProgressView()
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }
}

struct SignInView: View {
    @Environment(AppModel.self) private var app
    let onForgotPassword: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var error: APIError?
    @FocusState private var focus: Field?

    enum Field { case email, password }

    var body: some View {
        Form {
            Section {
                TextField("Электронная почта", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    .accessibilityIdentifier("signIn.email")
                SecureField("Пароль", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .accessibilityIdentifier("signIn.password")
            } footer: {
                if let error {
                    Text(error.message).foregroundStyle(Theme.negative)
                }
            }

            Section {
                AuthPrimaryButton(title: "Войти", isBusy: isSubmitting, action: submit)
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("signIn.submit")
            }

            Section {
                Button("Забыли пароль?", action: onForgotPassword)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("signIn.forgot")
            }
        }
        .navigationTitle("Вход")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .onAppear { focus = .email }
        .disabled(isSubmitting)
    }

    private var canSubmit: Bool {
        PasswordPolicy.isPlausibleEmail(email) && !password.isEmpty && !isSubmitting
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        error = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await app.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
            } catch let apiError as APIError {
                error = apiError
                Announce.post(apiError.message)
            } catch {}
        }
    }
}

struct SignUpView: View {
    @Environment(AppModel.self) private var app
    @State private var email = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var error: APIError?
    @FocusState private var focus: Field?

    enum Field { case email, password }

    var body: some View {
        Form {
            Section {
                TextField("Электронная почта", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    .accessibilityIdentifier("signUp.email")
                SecureField("Пароль", text: $password)
                    .newPasswordContentType()
                    .focused($focus, equals: .password)
                    .submitLabel(.done)
                    .onSubmit(submit)
                    .accessibilityIdentifier("signUp.password")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    PasswordRequirements(password: password)
                    Text("Почта используется для входа и видна только вам.")
                    if let error {
                        Text(error.message).foregroundStyle(Theme.negative)
                    }
                }
            }

            Section {
                AuthPrimaryButton(title: "Создать аккаунт", isBusy: isSubmitting, action: submit)
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("signUp.submit")
            }
        }
        .navigationTitle("Регистрация")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .onAppear { focus = .email }
        .disabled(isSubmitting)
    }

    private var canSubmit: Bool {
        PasswordPolicy.isPlausibleEmail(email) && PasswordPolicy.isValid(password) && !isSubmitting
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        error = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await app.signUp(email: email.trimmingCharacters(in: .whitespaces), password: password)
            } catch let apiError as APIError {
                error = apiError
                Announce.post(apiError.message)
            } catch {}
        }
    }
}

struct RecoverView: View {
    @Environment(AppModel.self) private var app
    @State private var email = ""
    @State private var recoveryKey = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var error: APIError?

    var body: some View {
        Form {
            Section {
                TextField("Электронная почта", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("recover.email")
            }
            Section {
                TextField("XXXXX-XXXXX-XXXXX-XXXXX", text: $recoveryKey)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Ключ восстановления")
                    .accessibilityIdentifier("recover.key")
            } header: {
                Text("Ключ восстановления")
            } footer: {
                Text("Ключ из 20 символов, который вы сохранили при регистрации или в настройках безопасности.")
            }
            Section {
                SecureField("Новый пароль", text: $password)
                    .newPasswordContentType()
                    .accessibilityIdentifier("recover.password")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    PasswordRequirements(password: password)
                    if let error {
                        Text(error.message).foregroundStyle(Theme.negative)
                    }
                }
            }
            Section {
                AuthPrimaryButton(title: "Восстановить доступ", isBusy: isSubmitting, action: submit)
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("recover.submit")
            } footer: {
                Text("После восстановления все другие устройства выйдут из аккаунта, а вы получите новый ключ.")
            }
        }
        .navigationTitle("Восстановление")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .disabled(isSubmitting)
    }

    private var normalizedKey: String {
        recoveryKey.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private var canSubmit: Bool {
        PasswordPolicy.isPlausibleEmail(email) && normalizedKey.count == 20 && PasswordPolicy.isValid(password) && !isSubmitting
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        error = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await app.recover(email: email.trimmingCharacters(in: .whitespaces), recoveryKey: normalizedKey, newPassword: password)
            } catch let apiError as APIError {
                error = apiError
                Announce.post(apiError.message)
            } catch {}
        }
    }
}
