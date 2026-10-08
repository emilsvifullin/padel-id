import Foundation
import Observation

// MARK: - Navigation

/// Push destinations of the onboarding NavigationStack (step 1 is the root).
nonisolated enum OnboardingDestination: Hashable, Sendable {
    case game
    case level
    case style
    case city
    case club(cityId: Int)
}

// MARK: - Calibration answers (keys and values of `private.calibrate`)

nonisolated enum OnboardingExperience: String, CaseIterable, Hashable, Sendable, Encodable {
    case beginner = "none"
    case underSixMonths = "lt6m"
    case sixToTwelveMonths = "6to12m"
    case oneToThreeYears = "1to3y"
    case overThreeYears = "gt3y"

    var title: String {
        switch self {
        case .beginner: "Только начинаю"
        case .underSixMonths: "Меньше 6 месяцев"
        case .sixToTwelveMonths: "От 6 месяцев до года"
        case .oneToThreeYears: "От 1 года до 3 лет"
        case .overThreeYears: "Больше 3 лет"
        }
    }
}

nonisolated enum OnboardingFrequency: String, CaseIterable, Hashable, Sendable, Encodable {
    case rare
    case monthly
    case weekly
    case often

    var title: String {
        switch self {
        case .rare: "Реже раза в месяц"
        case .monthly: "1–3 раза в месяц"
        case .weekly: "1–2 раза в неделю"
        case .often: "3 раза в неделю и чаще"
        }
    }
}

nonisolated enum OnboardingRacket: String, CaseIterable, Hashable, Sendable, Encodable {
    case noExperience = "none"
    case amateur
    case trained
    case competitive

    var title: String {
        switch self {
        case .noExperience: "Нет опыта"
        case .amateur: "Любительский уровень"
        case .trained: "Занятия в секции или с тренером"
        case .competitive: "Соревнования, спортивный разряд"
        }
    }

    var subtitle: String? {
        switch self {
        case .noExperience: nil
        case .amateur: "Играю для себя, без регулярных тренировок"
        case .trained: "Поставленная техника основных ударов"
        case .competitive: "Участие в официальных турнирах"
        }
    }
}

/// Answers on a 0–3 scale (`glass`, `net`, `competition`).
nonisolated enum OnboardingScaleQuestion: CaseIterable, Hashable, Sendable {
    case glass, net, competition

    var title: String {
        switch self {
        case .glass: "Игра от стекла"
        case .net: "Игра у сетки"
        case .competition: "Соревнования"
        }
    }

    var options: [String] {
        switch self {
        case .glass:
            ["Не играю от стекла",
             "Отбиваю простые мячи после стекла",
             "Уверенно после одного стекла",
             "Уверенно после двух стёкол и в углах"]
        case .net:
            ["Редко выхожу к сетке",
             "Играю с лёта, смэш нестабилен",
             "Уверенный воллей и бандеха",
             "Вибора и смэш на вылет"]
        case .competition:
            ["Не участвую",
             "Клубные американо",
             "Любительские турниры",
             "Турниры высокого уровня"]
        }
    }
}

// MARK: - Validation (mirrors the server rules)

nonisolated enum OnboardingValidation {
    /// `private.validate_display_name`: whitespace collapsed and trimmed.
    static func normalizedName(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static let nameSymbols: Set<Character> = [" ", ".", "'", "’", "-"]

    /// A user-facing problem with a (non-empty) display name, or nil when valid.
    static func displayNameProblem(_ raw: String) -> String? {
        let name = normalizedName(raw)
        guard let first = name.first else { return "Введите имя." }
        if !first.isLetter { return "Имя должно начинаться с буквы." }
        if !name.allSatisfy({ $0.isLetter || nameSymbols.contains($0) }) {
            return "Только буквы, пробел, дефис, точка и апостроф."
        }
        let length = name.unicodeScalars.count
        if length < 2 { return "Минимум 2 буквы." }
        if length > 40 { return "Не больше 40 символов." }
        return nil
    }

    static func isValidDisplayName(_ raw: String) -> Bool {
        displayNameProblem(raw) == nil
    }

    /// `private.validate_username` format rule (`^[a-z0-9_]{3,20}$`).
    static func usernameProblem(_ username: String) -> String? {
        let allowed = username.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (0x61...0x7A).contains(value) || (0x30...0x39).contains(value) || value == 0x5F
        }
        if !allowed { return "Только латинские буквы, цифры и «_»." }
        if username.count < 3 { return "Минимум 3 символа." }
        if username.count > 20 { return "Не больше 20 символов." }
        return nil
    }
}

// MARK: - Username availability

nonisolated enum OnboardingUsernameStatus: Equatable, Sendable {
    /// Nothing entered yet.
    case empty
    /// Waiting for the debounced server check.
    case checking
    case available
    case taken
    case invalid(String)
    /// The check could not reach the server; the server validates on finish.
    case unverified

    var allowsContinue: Bool {
        switch self {
        case .available, .unverified: true
        case .empty, .checking, .taken, .invalid: false
        }
    }
}

// MARK: - Request body (POST v1/me/onboarding)

private nonisolated struct OnboardingCalibrationBody: Encodable, Sendable {
    let experience: OnboardingExperience
    let frequency: OnboardingFrequency
    let racket: OnboardingRacket
    let glass: Int
    let net: Int
    let competition: Int
}

private nonisolated struct OnboardingRequestBody: Encodable, Sendable {
    let username: String
    let displayName: String
    let cityId: Int
    let clubId: Int?
    let preferredSide: CourtSide
    let dominantHand: Hand
    let playingSince: Int?
    let calibration: OnboardingCalibrationBody
    /// Keys are the canonical snake_case dimension keys.
    let dnaSelf: [String: Int]
}

// MARK: - Model

/// State of the onboarding flow: profile fields, calibration answers, Padel
/// DNA self-assessment and the final submission.
@Observable
final class OnboardingModel {
    static let stepCount = 4

    var path: [OnboardingDestination] = []

    // Step 1 — profile
    var displayName = ""
    private(set) var username = ""
    private(set) var usernameEdited = false
    private(set) var usernameStatus: OnboardingUsernameStatus = .empty
    private(set) var city: NamedRef?
    private(set) var club: NamedRef?
    /// Server-side rejection of the display name (shown under the field).
    private(set) var nameError: String?
    /// Server-side rejection of the city or club.
    private(set) var locationError: String?

    // Step 2 — game
    var side: CourtSide?
    var hand: Hand = .right
    var playingSince: Int?

    // Step 3 — level
    var experience: OnboardingExperience?
    var frequency: OnboardingFrequency?
    var racket: OnboardingRacket?
    var glass: Int?
    var net: Int?
    var competition: Int?

    // Step 4 — style
    var dna: [DNADimension: Int] = Dictionary(uniqueKeysWithValues: DNADimension.allCases.map { ($0, 0) })

    // Submission
    private(set) var isSubmitting = false
    private(set) var submitError: APIError?
    /// Incremented on every failed submission (drives the error haptic).
    private(set) var failureCount = 0
    private(set) var result: Me?

    @ObservationIgnored private var checkTask: Task<Void, Never>?

    // MARK: Step completeness

    var nameMessage: String? {
        if let nameError { return nameError }
        let normalized = OnboardingValidation.normalizedName(displayName)
        // A single typed letter is not an error yet — the footer explains the rule.
        guard normalized.unicodeScalars.count >= 2 || normalized.first.map({ !$0.isLetter }) == true else { return nil }
        return OnboardingValidation.displayNameProblem(normalized)
    }

    var isProfileComplete: Bool {
        OnboardingValidation.isValidDisplayName(displayName) && nameError == nil
            && usernameStatus.allowsContinue && city != nil && locationError == nil
    }

    var isGameComplete: Bool { side != nil }

    var isLevelComplete: Bool {
        experience != nil && frequency != nil && racket != nil && glass != nil && net != nil && competition != nil
    }

    var canFinish: Bool {
        isProfileComplete && isGameComplete && isLevelComplete && !isSubmitting
    }

    static var yearOptions: [Int] {
        let current = Calendar.current.component(.year, from: .now)
        return Array(stride(from: max(current, 1990), through: 1990, by: -1))
    }

    // MARK: Profile editing

    /// Clears a server rejection of the name and re-suggests the username
    /// from it until the user edits the username.
    func displayNameDidChange(api: APIClient) {
        nameError = nil
        guard !usernameEdited else { return }
        let normalized = OnboardingValidation.normalizedName(displayName)
        let suggestion = normalized.isEmpty ? "" : Transliteration.username(from: normalized)
        guard suggestion != username else { return }
        username = suggestion
        scheduleUsernameCheck(api: api)
    }

    /// Called for every edit of the username field.
    func editUsername(_ value: String, api: APIClient) {
        let lowered = value.lowercased()
        // Clearing the field hands the username back to the suggestion.
        usernameEdited = !lowered.isEmpty
        guard lowered != username else { return }
        username = lowered
        scheduleUsernameCheck(api: api)
    }

    /// Selecting another city resets the club (clubs belong to a city).
    func selectCity(_ newCity: NamedRef?) {
        if newCity?.id != city?.id {
            club = nil
        }
        city = newCity
        locationError = nil
    }

    func selectClub(_ newClub: NamedRef?) {
        club = newClub
        locationError = nil
    }

    private func scheduleUsernameCheck(api: APIClient) {
        checkTask?.cancel()
        checkTask = nil
        let candidate = username
        guard !candidate.isEmpty else {
            usernameStatus = .empty
            return
        }
        if let problem = OnboardingValidation.usernameProblem(candidate) {
            usernameStatus = .invalid(problem)
            return
        }
        usernameStatus = .checking
        checkTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            do {
                let check = try await api.send(
                    .get("v1/me/username-check", query: [URLQueryItem(name: "username", value: candidate)]),
                    as: UsernameCheck.self)
                guard !Task.isCancelled, candidate == self.username else { return }
                if !check.valid {
                    self.usernameStatus = .invalid(Self.reasonText(check.reason))
                } else {
                    self.usernameStatus = check.available ? .available : .taken
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, candidate == self.username else { return }
                self.usernameStatus = .unverified
            }
        }
    }

    private static func reasonText(_ reason: String?) -> String {
        switch reason {
        case "username_reserved": "Это имя пользователя недоступно."
        default: "3–20 символов: латинские буквы, цифры и «_»."
        }
    }

    // MARK: Submission

    func finish(app: AppModel) async {
        guard canFinish, let body = makeRequestBody() else { return }
        guard app.isOnline else {
            submitError = .offline
            failureCount += 1
            return
        }
        isSubmitting = true
        submitError = nil
        defer { isSubmitting = false }
        do {
            let data = try await app.api.data(.json(.post, "v1/me/onboarding", body, retryable: true))
            let me = try JSONCoding.decoder.decode(Me.self, from: data)
            app.cache.store(data, for: CacheKey.me)
            result = me
        } catch is CancellationError {
            return
        } catch let error as APIError {
            failureCount += 1
            handle(error)
        } catch {
            failureCount += 1
            submitError = APIError(kind: .decoding, code: "decoding", serverMessage: nil)
        }
    }

    private func handle(_ error: APIError) {
        switch error.code {
        case "username_taken":
            checkTask?.cancel()
            usernameStatus = .taken
            path = []
        case "username_invalid", "username_reserved":
            checkTask?.cancel()
            usernameStatus = .invalid(error.message)
            path = []
        case "display_name_invalid":
            nameError = error.message
            path = []
        case "city_required", "city_not_found":
            city = nil
            club = nil
            locationError = error.message
            path = []
        case "club_not_found":
            club = nil
            locationError = error.message
            path = []
        default:
            submitError = error
        }
    }

    private func makeRequestBody() -> OnboardingRequestBody? {
        guard let city, let side, let experience, let frequency, let racket,
              let glass, let net, let competition else { return nil }
        let dnaSelf = Dictionary(uniqueKeysWithValues: DNADimension.allCases.map { dimension in
            (dimension.rawValue, min(2, max(-2, dna[dimension] ?? 0)))
        })
        return OnboardingRequestBody(
            username: username,
            displayName: OnboardingValidation.normalizedName(displayName),
            cityId: city.id,
            clubId: club?.id,
            preferredSide: side,
            dominantHand: hand,
            playingSince: playingSince,
            calibration: OnboardingCalibrationBody(
                experience: experience, frequency: frequency, racket: racket,
                glass: glass, net: net, competition: competition),
            dnaSelf: dnaSelf)
    }
}
