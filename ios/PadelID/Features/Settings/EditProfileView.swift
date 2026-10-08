import PhotosUI
import SwiftUI
import UIKit

/// Profile editor: photo, name, username, city and club, game preferences,
/// bio and search visibility. Only changed fields are sent.
struct EditProfileView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// The profile as it was when editing started (the baseline for changes).
    @State private var original: Profile
    @State private var displayName: String
    @State private var username: String
    @State private var usernameState: EditProfileUsernameState = .unchanged
    @State private var city: NamedRef?
    @State private var club: NamedRef?
    @State private var side: CourtSide
    @State private var hand: Hand
    @State private var playingSince: Int?
    @State private var bio: String
    @State private var discoverable: Bool

    @State private var isSaving = false
    @State private var formError: APIError?
    @State private var nameError: String?
    @State private var locationError: String?
    @State private var failureCount = 0
    @State private var saveCount = 0
    @State private var isConfirmingDiscard = false

    @State private var pickerItem: PhotosPickerItem?
    @State private var avatarPreview: UIImage?
    @State private var isAvatarBusy = false
    @State private var avatarError: String?
    @State private var isConfirmingAvatarRemoval = false
    @State private var avatarCount = 0

    init(profile: Profile) {
        _original = State(initialValue: profile)
        _displayName = State(initialValue: profile.displayName)
        _username = State(initialValue: profile.username ?? "")
        _city = State(initialValue: profile.city)
        _club = State(initialValue: profile.club)
        _side = State(initialValue: profile.preferredSide ?? .both)
        _hand = State(initialValue: profile.dominantHand ?? .right)
        _playingSince = State(initialValue: profile.playingSince)
        _bio = State(initialValue: profile.bio ?? "")
        _discoverable = State(initialValue: profile.discoverable ?? true)
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if !app.isOnline {
                    Section {
                        SettingsOfflineNotice()
                    }
                }
                if let formError {
                    Section {
                        SettingsErrorRow(message: formError.message)
                            .id(EditProfileAnchor.error)
                    }
                }
                avatarSection
                nameSection
                usernameSection
                locationSection
                gameSection
                bioSection
                visibilitySection
            }
            .disabled(isSaving)
            .onChange(of: failureCount) {
                withAnimation(.smooth) {
                    proxy.scrollTo(failureAnchor, anchor: .top)
                }
            }
        }
        .navigationTitle("Профиль")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasChanges)
        .toolbar {
            if hasChanges {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отменить") { isConfirmingDiscard = true }
                        .disabled(isSaving)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Сохранить", action: save)
                        .disabled(!canSave)
                }
            }
        }
        .interactiveDismissDisabled(hasChanges || isSaving || isAvatarBusy)
        .confirmationDialog("Отменить изменения?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Не сохранять", role: .destructive) { dismiss() }
            Button("Продолжить редактирование", role: .cancel) {}
        }
        .task(id: username) { await checkUsername() }
        .onChange(of: username) { _, value in
            let cleaned = value.lowercased().filter { !$0.isWhitespace }
            if cleaned != value { username = cleaned }
        }
        .onChange(of: displayName) { nameError = nil }
        .onChange(of: city) { oldValue, newValue in
            if oldValue?.id != newValue?.id {
                club = nil
            }
            locationError = nil
        }
        .onChange(of: club) { locationError = nil }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task { await uploadAvatar(item) }
        }
        .sensoryFeedback(.success, trigger: saveCount)
        .sensoryFeedback(.success, trigger: avatarCount)
        .sensoryFeedback(.error, trigger: failureCount)
    }

    // MARK: - Sections

    private var currentProfile: Profile { app.me?.profile ?? original }

    private var hasAvatar: Bool { avatarPreview != nil || currentProfile.avatarPath != nil }

    private var avatarSection: some View {
        Section {
            avatarImage
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(hasAvatar ? "Фото профиля" : "Фото профиля не выбрано")
                .accessibilityValue(isAvatarBusy ? "Загружается" : "")
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label(hasAvatar ? "Изменить фото" : "Выбрать фото", systemImage: "photo")
            }
            .disabled(!app.isOnline || isAvatarBusy || isSaving)
            if hasAvatar {
                Button(role: .destructive) {
                    isConfirmingAvatarRemoval = true
                } label: {
                    Label("Удалить фото", systemImage: "trash")
                }
                .disabled(!app.isOnline || isAvatarBusy || isSaving)
                .confirmationDialog("Удалить фото профиля?", isPresented: $isConfirmingAvatarRemoval, titleVisibility: .visible) {
                    Button("Удалить фото", role: .destructive, action: removeAvatar)
                    Button("Отмена", role: .cancel) {}
                }
            }
        } footer: {
            if let avatarError {
                Text(avatarError)
                    .foregroundStyle(Theme.negative)
            }
        }
    }

    private var avatarImage: some View {
        ZStack {
            if let avatarPreview {
                Image(uiImage: avatarPreview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 104, height: 104)
                    .clipShape(.circle)
            } else {
                AvatarView(profile: currentProfile, size: 104)
            }
            if isAvatarBusy {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 104, height: 104)
                ProgressView()
            }
        }
    }

    private var nameSection: some View {
        Section {
            TextField("Имя и фамилия", text: $displayName)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .id(EditProfileAnchor.name)
        } header: {
            Text("Имя")
        } footer: {
            if let message = nameMessage {
                Text(message)
                    .foregroundStyle(Theme.negative)
            } else {
                Text("Так вас увидят партнёры и соперники.")
            }
        }
    }

    private var usernameSection: some View {
        Section {
            HStack(spacing: 2) {
                Text("@")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("имя_пользователя", text: $username)
                    .textContentType(.nickname)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .accessibilityLabel("Имя пользователя")
            }
            .id(EditProfileAnchor.username)
        } header: {
            Text("Имя пользователя")
        } footer: {
            usernameFooter
        }
    }

    @ViewBuilder
    private var usernameFooter: some View {
        switch usernameState {
        case .unchanged:
            Text("3–20 символов: латинские буквы, цифры и «_». По нему вас найдут другие игроки.")
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Проверяем…")
            }
        case .available:
            Label("Имя свободно", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.positive)
        case .taken:
            Label("Это имя уже занято", systemImage: "xmark.circle.fill")
                .foregroundStyle(Theme.negative)
        case .invalid(let message):
            Text(message)
                .foregroundStyle(Theme.negative)
        case .unverified:
            Text("Не удалось проверить имя — проверим при сохранении.")
        }
    }

    private var locationSection: some View {
        Section {
            NavigationLink {
                CityPickerView(selection: $city)
            } label: {
                LabeledContent("Город", value: city?.name ?? "Не выбран")
            }
            .id(EditProfileAnchor.location)
            if let cityId = city?.id {
                NavigationLink {
                    ClubPickerView(cityId: cityId, selection: $club)
                } label: {
                    LabeledContent("Клуб", value: club?.name ?? "Не выбран")
                }
            }
        } header: {
            Text("Город и клуб")
        } footer: {
            if let locationError {
                Text(locationError)
                    .foregroundStyle(Theme.negative)
            } else {
                Text("Помогают находить партнёров рядом.")
            }
        }
    }

    private var gameSection: some View {
        Section {
            Picker("Сторона корта", selection: $side) {
                ForEach(EditProfileOptions.sides, id: \.self) { option in
                    Text(Narratives.sideName(option)).tag(option)
                }
            }
            .sensoryFeedback(.selection, trigger: side)
            Picker("Игровая рука", selection: $hand) {
                Text("Правая").tag(Hand.right)
                Text("Левая").tag(Hand.left)
            }
            .sensoryFeedback(.selection, trigger: hand)
            Picker("Год начала игры", selection: $playingSince) {
                Text("Не указан").tag(Int?.none)
                ForEach(EditProfileOptions.years, id: \.self) { year in
                    Text(String(year)).tag(Int?.some(year))
                }
            }
            .pickerStyle(.navigationLink)
        } header: {
            Text("Игра")
        }
    }

    private var bioSection: some View {
        Section {
            TextField("Например: играю по вечерам, ищу партнёра для турниров", text: $bio, axis: .vertical)
                .lineLimit(3...6)
        } header: {
            Text("О себе")
        } footer: {
            HStack(alignment: .firstTextBaseline) {
                Text("Видно в вашем профиле.")
                Spacer(minLength: 8)
                SettingsCharacterCount(count: SettingsText.length(bio), limit: EditProfileOptions.bioLimit)
            }
        }
    }

    private var visibilitySection: some View {
        Section {
            Toggle("Показывать меня в поиске", isOn: $discoverable)
        } footer: {
            Text(discoverable
                 ? "Вас могут найти все игроки Padel ID."
                 : "Вас найдут только игроки, с которыми вы уже играли.")
        }
    }

    // MARK: - Changes and validation

    private var normalizedName: String {
        EditProfileValidation.normalizedName(displayName)
    }

    private var nameMessage: String? {
        if let nameError { return nameError }
        guard normalizedName != original.displayName else { return nil }
        return EditProfileValidation.nameProblem(normalizedName)
    }

    private var patch: EditProfilePatch {
        var patch = EditProfilePatch()
        if normalizedName != original.displayName {
            patch.displayName = normalizedName
        }
        if !username.isEmpty, username != (original.username ?? "") {
            patch.username = username
        }
        if let city, city.id != original.city?.id {
            patch.cityId = city.id
        }
        if club?.id != original.club?.id {
            if let club {
                patch.clubId = EditProfileChange.set(club.id)
            } else {
                patch.clubId = EditProfileChange.clear
            }
        }
        if side != (original.preferredSide ?? .both) {
            patch.preferredSide = side
        }
        if hand != (original.dominantHand ?? .right) {
            patch.dominantHand = hand
        }
        if playingSince != original.playingSince {
            if let playingSince {
                patch.playingSince = EditProfileChange.set(playingSince)
            } else {
                patch.playingSince = EditProfileChange.clear
            }
        }
        let newBio = SettingsText.trimmed(bio)
        if newBio != SettingsText.trimmed(original.bio ?? "") {
            if newBio.isEmpty {
                patch.bio = EditProfileChange.clear
            } else {
                patch.bio = EditProfileChange.set(newBio)
            }
        }
        if discoverable != (original.discoverable ?? true) {
            patch.discoverable = discoverable
        }
        return patch
    }

    private var hasChanges: Bool { !patch.isEmpty }

    private var isValid: Bool {
        (normalizedName == original.displayName || EditProfileValidation.nameProblem(normalizedName) == nil)
            && usernameState.allowsSave
            && city != nil
            && SettingsText.length(bio) <= EditProfileOptions.bioLimit
    }

    private var canSave: Bool {
        hasChanges && isValid && app.isOnline && !isSaving && !isAvatarBusy
    }

    private var failureAnchor: EditProfileAnchor {
        if formError != nil { return .error }
        if nameError != nil { return .name }
        if locationError != nil { return .location }
        return .username
    }

    // MARK: - Username availability

    private func checkUsername() async {
        let candidate = username
        if candidate.isEmpty {
            usernameState = .invalid("Введите имя пользователя.")
            return
        }
        if candidate == (original.username ?? "") {
            usernameState = .unchanged
            return
        }
        if let problem = EditProfileValidation.usernameProblem(candidate) {
            usernameState = .invalid(problem)
            return
        }
        usernameState = .checking
        do {
            try await Task.sleep(for: .milliseconds(400))
        } catch {
            return
        }
        do {
            let check = try await app.api.send(
                .get("v1/me/username-check", query: [URLQueryItem(name: "username", value: candidate)]),
                as: UsernameCheck.self)
            guard !Task.isCancelled, candidate == username else { return }
            if !check.valid {
                usernameState = .invalid(check.reason == "username_reserved"
                    ? "Это имя пользователя недоступно."
                    : "3–20 символов: латинские буквы, цифры и «_».")
            } else {
                usernameState = check.available ? .available : .taken
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, candidate == username else { return }
            usernameState = .unverified
        }
    }

    // MARK: - Saving

    private func save() {
        guard canSave else { return }
        let body = patch
        isSaving = true
        formError = nil
        Task {
            defer { isSaving = false }
            do {
                let data = try await app.api.data(.json(.patch, "v1/me", body))
                let me = try JSONCoding.decoder.decode(Me.self, from: data)
                applyMe(me, data: data)
                saveCount += 1
                dismiss()
            } catch is CancellationError {
                return
            } catch let error as APIError {
                handle(error)
                failureCount += 1
            } catch {
                formError = APIError(kind: .decoding, code: "decoding", serverMessage: nil)
                failureCount += 1
            }
        }
    }

    private func handle(_ error: APIError) {
        switch error.code {
        case "username_taken":
            usernameState = .taken
        case "username_invalid", "username_reserved":
            usernameState = .invalid(error.message)
        case "display_name_invalid":
            nameError = error.message
        case "city_not_found", "city_required", "club_not_found":
            locationError = error.message
        default:
            formError = error
        }
    }

    private func applyMe(_ me: Me, data: Data) {
        app.cache.store(data, for: CacheKey.me)
        app.apply(me: me)
        app.dataDidChange()
    }

    // MARK: - Avatar

    private func uploadAvatar(_ item: PhotosPickerItem) async {
        guard app.isOnline else {
            avatarError = APIError.offline.message
            return
        }
        let previousPreview = avatarPreview
        isAvatarBusy = true
        avatarError = nil
        defer { isAvatarBusy = false }
        do {
            guard let source = try await item.loadTransferable(type: Data.self),
                  let image = EditProfileAvatarEncoder.prepare(source, maxSide: 512),
                  let jpeg = EditProfileAvatarEncoder.jpeg(image, maxBytes: 900_000) else {
                avatarError = "Не удалось открыть это фото. Выберите другое."
                return
            }
            avatarPreview = image
            let data: Data
            do {
                data = try await app.api.data(avatarEndpoint(jpeg))
            } catch let error as APIError where error.code == "payload_too_large" {
                // Retry once with a much smaller file.
                guard let compact = EditProfileAvatarEncoder.jpeg(image, maxBytes: 60_000) else { throw error }
                data = try await app.api.data(avatarEndpoint(compact))
            }
            let me = try JSONCoding.decoder.decode(Me.self, from: data)
            applyMe(me, data: data)
            avatarCount += 1
        } catch is CancellationError {
            avatarPreview = previousPreview
        } catch let error as APIError {
            avatarPreview = previousPreview
            avatarError = error.message
        } catch {
            avatarPreview = previousPreview
            avatarError = "Не удалось загрузить фото. Попробуйте ещё раз."
        }
    }

    private func avatarEndpoint(_ jpeg: Data) -> Endpoint {
        Endpoint(method: .put, path: "v1/me/avatar", body: jpeg, contentType: "image/jpeg")
    }

    private func removeAvatar() {
        guard app.isOnline else {
            avatarError = APIError.offline.message
            return
        }
        isAvatarBusy = true
        avatarError = nil
        Task {
            defer { isAvatarBusy = false }
            do {
                let data = try await app.api.data(.empty(.delete, "v1/me/avatar"))
                let me = try JSONCoding.decoder.decode(Me.self, from: data)
                avatarPreview = nil
                applyMe(me, data: data)
                avatarCount += 1
            } catch is CancellationError {
                return
            } catch let error as APIError {
                avatarError = error.message
            } catch {
                avatarError = "Не удалось удалить фото. Попробуйте ещё раз."
            }
        }
    }
}

// MARK: - Supporting types

private nonisolated enum EditProfileAnchor: Hashable, Sendable {
    case error, name, username, location
}

private nonisolated enum EditProfileUsernameState: Equatable, Sendable {
    case unchanged
    case checking
    case available
    case taken
    case invalid(String)
    /// The availability check failed (offline); the server validates on save.
    case unverified

    var allowsSave: Bool {
        switch self {
        case .unchanged, .available, .unverified: true
        case .checking, .taken, .invalid: false
        }
    }
}

private nonisolated enum EditProfileOptions {
    static let bioLimit = 160
    static let sides: [CourtSide] = [.right, .left, .both]

    /// Years accepted by the server: 1970 … current year, newest first.
    static var years: [Int] {
        let current = Calendar.current.component(.year, from: .now)
        return Array(stride(from: max(current, 1970), through: 1970, by: -1))
    }
}

/// A field that is either set to a value or explicitly cleared (`null`).
private nonisolated enum EditProfileChange<Value: Encodable & Sendable>: Sendable {
    case set(Value)
    case clear
}

private nonisolated enum EditProfilePatchKey: String, CodingKey, Sendable {
    case displayName = "display_name"
    case username
    case cityId = "city_id"
    case clubId = "club_id"
    case preferredSide = "preferred_side"
    case dominantHand = "dominant_hand"
    case playingSince = "playing_since"
    case bio
    case discoverable
}

/// Body of `PATCH v1/me`: only present keys are sent; cleared fields are sent as `null`.
private nonisolated struct EditProfilePatch: Encodable, Sendable {
    var displayName: String?
    var username: String?
    var cityId: Int?
    var clubId: EditProfileChange<Int>?
    var preferredSide: CourtSide?
    var dominantHand: Hand?
    var playingSince: EditProfileChange<Int>?
    var bio: EditProfileChange<String>?
    var discoverable: Bool?

    var isEmpty: Bool {
        displayName == nil && username == nil && cityId == nil && clubId == nil && preferredSide == nil
            && dominantHand == nil && playingSince == nil && bio == nil && discoverable == nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: EditProfilePatchKey.self)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(cityId, forKey: .cityId)
        try Self.encode(clubId, forKey: .clubId, in: &container)
        try container.encodeIfPresent(preferredSide, forKey: .preferredSide)
        try container.encodeIfPresent(dominantHand, forKey: .dominantHand)
        try Self.encode(playingSince, forKey: .playingSince, in: &container)
        try Self.encode(bio, forKey: .bio, in: &container)
        try container.encodeIfPresent(discoverable, forKey: .discoverable)
    }

    private static func encode<Value: Encodable & Sendable>(
        _ change: EditProfileChange<Value>?,
        forKey key: EditProfilePatchKey,
        in container: inout KeyedEncodingContainer<EditProfilePatchKey>
    ) throws {
        switch change {
        case .some(.set(let value)):
            try container.encode(value, forKey: key)
        case .some(.clear):
            try container.encodeNil(forKey: key)
        case .none:
            break
        }
    }
}

/// Mirrors the server rules for display names and usernames.
private nonisolated enum EditProfileValidation {
    static func normalizedName(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func nameProblem(_ name: String) -> String? {
        guard let first = name.first else { return "Введите имя." }
        if !first.isLetter { return "Имя должно начинаться с буквы." }
        let symbols: Set<Character> = [" ", ".", "'", "’", "-"]
        if !name.allSatisfy({ $0.isLetter || symbols.contains($0) }) {
            return "Только буквы, пробел, дефис, точка и апостроф."
        }
        let length = name.unicodeScalars.count
        if length < 2 { return "Минимум 2 буквы." }
        if length > 40 { return "Не больше 40 символов." }
        return nil
    }

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

/// Prepares a picked photo for upload: decodes a reduced-size thumbnail,
/// scales it to at most `maxSide` pixels and encodes JPEG within a byte budget.
private enum EditProfileAvatarEncoder {
    static func prepare(_ data: Data, maxSide: CGFloat) -> UIImage? {
        guard let decoded = UIImage(data: data) else { return nil }
        let longest = max(decoded.size.width, decoded.size.height)
        guard longest > 0 else { return nil }
        // Decode at twice the target size at most instead of the full photo.
        let factor = min(1, maxSide * 2 / longest)
        let thumbnailSize = CGSize(width: decoded.size.width * factor, height: decoded.size.height * factor)
        let source = decoded.preparingThumbnail(of: thumbnailSize) ?? decoded
        return render(source, maxSide: maxSide)
    }

    static func render(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        let factor = longest > 0 ? min(1, maxSide / longest) : 1
        let target = CGSize(width: max(1, (size.width * factor).rounded()),
                            height: max(1, (size.height * factor).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Lowers the JPEG quality (and then the size) until the file fits.
    static func jpeg(_ image: UIImage, maxBytes: Int) -> Data? {
        let qualities: [CGFloat] = [0.85, 0.75, 0.65, 0.55, 0.45, 0.35]
        var candidate = image
        for _ in 0..<4 {
            for quality in qualities {
                if let data = candidate.jpegData(compressionQuality: quality), data.count <= maxBytes {
                    return data
                }
            }
            let longest = max(candidate.size.width, candidate.size.height)
            guard longest > 64 else { return nil }
            candidate = render(candidate, maxSide: (longest * 0.75).rounded())
        }
        return nil
    }
}
