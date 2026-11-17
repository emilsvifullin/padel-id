import Auth
import Foundation
import Observation

struct PlayerName {
    let first: String
    let last: String

    init?(first: String, last: String) {
        let first = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = last.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty, !last.isEmpty else { return nil }
        self.first = first
        self.last = last
    }
}

@Observable
final class TennisAuth {
    private enum EmailFlow: String {
        case confirm, recovery

        var redirect: URL { URL(string: "tennis-id://auth/\(rawValue)")! }
    }

    static let minimumPasswordLength = 6
    private static let pendingFlowKey = "pending-email-flow"
    private static let recoveryKey = "recovery-session"
    private static let invalidCredentialsMessage = "Неверная электронная почта или пароль."

    private let storage = KeychainLocalStorage(service: "app.padelid.ios.tennis-auth")
    @ObservationIgnored private lazy var client = AuthClient(configuration: .init(
        url: URL(string: "https://xnxhlfuncxyzdfdmqlkb.supabase.co/auth/v1")!,
        headers: ["apikey": "sb_publishable_Ij5UIKkrMHbdPOZeSo6gqw_2XkYypC_"],
        flowType: .pkce,
        storageKey: "tennis-id",
        localStorage: storage
    ))

    private(set) var isRestoring = true
    private(set) var userID: UUID?
    private(set) var hasPlayerName = false
    var isSignedIn: Bool { userID != nil }
    private(set) var needsNewPassword = false
    private(set) var isBusy = false
    var notice: String?
    private(set) var accountError: String?

    #if (DEBUG && targetEnvironment(simulator)) || TENNIS_PREVIEW
    private let isPreview: Bool
    private let previewSignInDelay: Duration?
    private var previewPassword = "Tennis123"
    private var pendingPreviewPassword: String?
    var isPreviewRegistrationPending: Bool { pendingPreviewPassword != nil }

    init(preview: Bool = false, previewSignInDelay: Duration? = nil) {
        isPreview = preview
        self.previewSignInDelay = previewSignInDelay
        isRestoring = !preview
    }

    func confirmPreviewRegistration() {
        guard isPreview, let pendingPreviewPassword else { return }
        previewPassword = pendingPreviewPassword
        self.pendingPreviewPassword = nil
        notice = nil
        hasPlayerName = true
        userID = UUID()
    }

    func openPreviewRecovery() {
        guard isPreview else { return }
        notice = nil
        needsNewPassword = true
        userID = UUID()
    }
    #endif

    func clearAccountError() {
        accountError = nil
    }

    func observeSession() async {
        needsNewPassword = (try? storage.retrieve(key: Self.recoveryKey)) != nil
        for await (event, session) in client.authStateChanges {
            if event == .initialSession || event == .signedOut || event == .signedIn || event == .tokenRefreshed || event == .userUpdated {
                userID = session?.user.id
                let metadata = session?.user.userMetadata
                hasPlayerName = PlayerName(
                    first: metadata?["first_name"]?.stringValue ?? "",
                    last: metadata?["last_name"]?.stringValue ?? ""
                ) != nil
                isRestoring = false
            }
            if event == .signedOut || (event == .initialSession && session == nil && !isBusy) {
                clearRecovery()
            }
        }
    }

    func submit(email: String, password: String, registrationName: PlayerName?) async {
        #if (DEBUG && targetEnvironment(simulator)) || TENNIS_PREVIEW
        if isPreview {
            await perform(onError: { self.accountError = $0 }) {
                if registrationName == nil, let previewSignInDelay {
                    try await Task.sleep(for: previewSignInDelay)
                }
                if registrationName != nil {
                    pendingPreviewPassword = password
                    notice = "Проверьте почту и подтвердите регистрацию по ссылке в письме."
                } else if password == previewPassword {
                    hasPlayerName = true
                    userID = UUID()
                } else {
                    accountError = Self.invalidCredentialsMessage
                }
            }
            return
        }
        #endif
        await perform(onError: { self.accountError = $0 }) {
            clearAccountError()
            if let registrationName {
                try storePendingFlow(.confirm)
                let response = try await client.signUp(
                    email: email,
                    password: password,
                    data: nameMetadata(registrationName),
                    redirectTo: EmailFlow.confirm.redirect
                )
                if response.session == nil {
                    notice = "Проверьте почту и подтвердите регистрацию по ссылке в письме."
                } else {
                    try storage.remove(key: Self.pendingFlowKey)
                }
            } else {
                _ = try await client.signIn(email: email, password: password)
            }
        }
    }

    func savePlayerName(_ name: PlayerName) async {
        guard isSignedIn, !needsNewPassword else { return }
        await perform(onError: { self.accountError = $0 }) {
            clearAccountError()
            _ = try await client.update(user: UserAttributes(data: nameMetadata(name)))
        }
    }

    private func nameMetadata(_ name: PlayerName) -> [String: AnyJSON] {
        ["first_name": .string(name.first), "last_name": .string(name.last)]
    }

    func requestRecovery(email: String) async {
        #if (DEBUG && targetEnvironment(simulator)) || TENNIS_PREVIEW
        if isPreview {
            notice = "Если этот адрес зарегистрирован, на него придёт ссылка для сброса пароля."
            return
        }
        #endif
        await perform {
            try storePendingFlow(.recovery)
            try await client.resetPasswordForEmail(email, redirectTo: EmailFlow.recovery.redirect)
            notice = "Если этот адрес зарегистрирован, на него придёт ссылка для сброса пароля."
        }
    }

    func open(_ url: URL) async {
        guard url.scheme == "tennis-id", url.host == "auth",
              let flow = EmailFlow(rawValue: String(url.path.dropFirst())) else { return }

        await perform {
            let expected = try storage.retrieve(key: Self.pendingFlowKey)
            guard expected == Data(flow.rawValue.utf8) else {
                notice = "Запросите новую ссылку в приложении на этом устройстве."
                return
            }

            if flow == .recovery {
                try storage.store(key: Self.recoveryKey, value: Data([1]))
                needsNewPassword = true
            }

            do {
                _ = try await client.session(from: url)
                try storage.remove(key: Self.pendingFlowKey)
            } catch {
                if flow == .recovery { clearRecovery() }
                if !Task.isCancelled {
                    notice = error is URLError
                        ? Self.message(for: error)
                        : "Ссылка недействительна или истекла. Запросите новую в приложении."
                }
            }
        }
    }

    func updatePassword(_ password: String) async {
        guard needsNewPassword, isSignedIn else { return }
        #if (DEBUG && targetEnvironment(simulator)) || TENNIS_PREVIEW
        if isPreview {
            previewPassword = password
            await signOut()
            notice = "Пароль обновлён. Войдите с новым паролем."
            return
        }
        #endif
        await perform {
            _ = try await client.update(user: UserAttributes(password: password))
            // The SDK drops the local session even when the revocation request fails.
            try? await client.signOut(scope: .local)
            notice = "Пароль обновлён. Войдите с новым паролем."
        }
    }

    func signOut() async {
        #if (DEBUG && targetEnvironment(simulator)) || TENNIS_PREVIEW
        if isPreview {
            userID = nil
            needsNewPassword = false
            hasPlayerName = false
            return
        }
        #endif
        await perform {
            try await client.signOut(scope: .local)
        }
    }

    private func clearRecovery() {
        try? storage.remove(key: Self.recoveryKey)
        needsNewPassword = false
    }

    private func storePendingFlow(_ flow: EmailFlow) throws {
        try storage.store(key: Self.pendingFlowKey, value: Data(flow.rawValue.utf8))
    }

    private func perform(onError: ((String) -> Void)? = nil, _ work: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await work()
        } catch {
            guard !Task.isCancelled else { return }
            let message = Self.message(for: error)
            if let onError { onError(message) } else { notice = message }
        }
    }

    private static func message(for error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .cannotFindHost || urlError.code == .dnsLookupFailed {
            return "Сервер недоступен. Попробуйте другую сеть."
        }
        if let urlError = error as? URLError {
            if urlError.code == .notConnectedToInternet { return "Нет интернета. Проверьте подключение." }
            return "Не удалось подключиться. Попробуйте ещё раз."
        }
        switch (error as? AuthError)?.errorCode {
        case .invalidCredentials: return invalidCredentialsMessage
        case .emailNotConfirmed: return "Подтвердите почту по ссылке из письма."
        case .emailExists, .userAlreadyExists: return "Аккаунт с этой почтой уже существует."
        case .weakPassword: return "Выберите более надёжный пароль."
        case .samePassword: return "Новый пароль должен отличаться от прежнего."
        case .overRequestRateLimit, .overEmailSendRateLimit: return "Слишком много запросов. Попробуйте позже."
        case .emailAddressNotAuthorized: return "Не удалось отправить письмо на этот адрес."
        case .signupDisabled: return "Регистрация сейчас недоступна."
        default: return "Не удалось выполнить действие. Попробуйте ещё раз."
        }
    }
}
