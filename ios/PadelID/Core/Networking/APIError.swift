import Foundation

/// Errors surfaced by the API client. `code` matches the server error contract.
nonisolated struct APIError: Error, Hashable, Sendable, LocalizedError {
    enum Kind: Hashable, Sendable {
        /// The device could not reach the server (offline, DNS, TLS, timeout).
        case network
        /// The server answered with a structured error.
        case server(status: Int)
        /// The response could not be understood.
        case decoding
    }

    let kind: Kind
    let code: String
    let serverMessage: String?

    static let offline = APIError(kind: .network, code: "network", serverMessage: nil)

    var isNetwork: Bool { kind == .network }

    var status: Int? {
        if case .server(let status) = kind { return status }
        return nil
    }

    /// Whether retrying the same request may succeed.
    var isTransient: Bool {
        switch kind {
        case .network: return true
        case .server(let status): return status >= 500 || status == 429
        case .decoding: return false
        }
    }

    var errorDescription: String? { message }

    var message: String {
        switch kind {
        case .network:
            return "Нет подключения к интернету. Проверьте сеть и попробуйте снова."
        case .decoding:
            return "Не удалось обработать ответ сервера. Обновите приложение или попробуйте позже."
        case .server:
            return APIError.messages[code] ?? serverMessage ?? "Что-то пошло не так. Попробуйте ещё раз."
        }
    }

    /// Client-side copy for the most common codes (server text is the fallback).
    private static let messages: [String: String] = [
        "invalid_credentials": "Неверная почта или пароль.",
        "email_taken": "Аккаунт с этой почтой уже существует. Войдите или восстановите доступ.",
        "weak_password": "Пароль: не меньше 8 символов, буквы и цифры.",
        "invalid_email": "Проверьте адрес электронной почты.",
        "rate_limited": "Слишком много попыток. Подождите немного и попробуйте снова.",
        "session_expired": "Сессия истекла. Войдите снова.",
        "invalid_password": "Неверный пароль.",
        "invalid_recovery": "Почта или ключ восстановления не подходят.",
        "same_password": "Новый пароль совпадает с текущим.",
        "service_unavailable": "Сервис временно недоступен. Попробуйте через минуту.",
        "client_outdated": "Эта версия приложения устарела. Установите обновление.",
        "version_conflict": "Матч только что изменили. Проверьте актуальный счёт.",
        "duplicate_match": "Этот матч уже внесён — проверьте раздел «Матчи».",
        "match_locked": "Матч уже подтверждён всеми участниками и не может быть изменён.",
        "match_closed": "Матч отменён или истёк срок его подтверждения.",
        "username_taken": "Это имя пользователя уже занято.",
    ]
}
