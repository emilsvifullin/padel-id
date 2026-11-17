import SwiftUI
import PhotosUI
import ImageIO

struct PlayerProfile: Codable, Equatable {
    var name = "Алексей Смирнов"
    var givenName: String?
    var familyName: String?
    var email = "player@example.com"
    var phone = ""
    var avatar: Data?
    var trainingNotifications = true
    var subscriptionNotifications = true
    var supportNotifications = true
}

@MainActor
@Observable
final class LocalPlayerAccount {
    private struct SavedAccount: Codable {
        var profile = PlayerProfile()
        var messages: [SupportMessage] = []
    }

    private static let storageKey = "tennis-preview-player-account"
    private let defaults: UserDefaults
    private var saved: SavedAccount {
        didSet {
            if let data = try? JSONEncoder().encode(saved) {
                defaults.set(data, forKey: Self.storageKey)
            }
        }
    }

    var draft = ""
    var draftTopic: SupportTopic?
    var draftPhotos: [SupportDraftPhoto] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        saved = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(SavedAccount.self, from: $0) }
            ?? SavedAccount()
    }

    var profile: PlayerProfile {
        get { saved.profile }
        set { saved.profile = newValue }
    }

    var messages: [SupportMessage] { saved.messages }

    var canSend: Bool {
        !draftPhotos.isEmpty || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send(messageID: UUID = UUID(), delaysReply: Bool = false) throws {
        guard canSend else { return }
        let photos = try SupportPhoto.save(draftPhotos)
        let response: String
        switch draftTopic?.kind {
        case .training: response = "Получили ваш вопрос. Дата и время тренировки есть в сообщении."
        case .payment: response = "Получили ваш вопрос. Данные абонемента есть в сообщении."
        case nil: response = "Получили ваше сообщение. Спасибо, что написали."
        }
        let message = SupportMessage(id: messageID, text: draft.trimmingCharacters(in: .whitespacesAndNewlines),
                                     topic: draftTopic, fromPlayer: true, photos: photos.isEmpty ? nil : photos)
        if delaysReply {
            saved.messages.append(message)
            Task {
                guard (try? await Task.sleep(for: .milliseconds(650))) != nil else { return }
                saved.messages.append(SupportMessage(text: response, fromPlayer: false))
            }
        } else {
            saved.messages += [message, SupportMessage(text: response, fromPlayer: false)]
        }
        clearDraft()
    }

    func clearDraft() {
        draft = ""
        draftTopic = nil
        draftPhotos = []
    }
}

enum PlayerPhoto {
    nonisolated static func thumbnail(from data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

enum PlayerSettingsPage: Equatable {
    case overview, editProfile, notifications, support
}

enum PlayerChrome: PreferenceKey {
    enum Mode: Equatable {
        case standard, player, settings, focused
    }

    static let defaultValue: Mode = .standard

    static func reduce(value: inout Mode, nextValue: () -> Mode) {
        let next = nextValue()
        if next != .standard { value = next }
    }
}

struct PlayerSettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var account: LocalPlayerAccount
    @Binding var page: PlayerSettingsPage
    let onSignOut: () -> Void
    var overviewLeadingControl: AnyView? = nil

    @State private var draft = PlayerProfile()
    @State private var draftGivenName = ""
    @State private var draftFamilyName = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isLoadingPhoto = false
    @State private var photoFailed = false
    @State private var confirmsSignOut = false
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case givenName, familyName, email, phone
    }

    private var isEditing: Bool { page == .editProfile }
    private var cleanGivenName: String { draftGivenName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanFamilyName: String { draftFamilyName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanEmail: String { draft.email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var emailIsValid: Bool {
        let parts = cleanEmail.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !cleanEmail.contains(where: \.isWhitespace) else { return false }
        let domain = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return domain.count > 1 && domain.allSatisfy { !$0.isEmpty }
    }

    private var destination: Binding<Bool> {
        Binding {
            page == .notifications || page == .support
        } set: { shown in
            if !shown { page = .overview }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 12) {
                        avatar(for: isEditing ? draft : account.profile)

                        if isEditing {
                            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                Text("Изменить фотографию")
                                    .font(.subheadline.weight(.medium))
                                    .frame(minHeight: 44)
                            }
                            .tint(.white)
                            .transition(.opacity)
                        } else {
                            profileDetails
                                .transition(.opacity)
                        }
                    }

                    if isEditing {
                        editor
                            .transition(.opacity)
                    } else {
                        settingsOptions
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, PlayerHeaderLayout.sideInset)
                .padding(.top, 14)
                .padding(.bottom, 28)
                .frame(maxWidth: PlayerHeaderLayout.contentWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .scrollPosition($scrollPosition)
            .overlay(alignment: .top) { profileControls }
            .toolbarVisibility(.hidden, for: .navigationBar)
            .toolbarVisibility(isEditing ? .hidden : .automatic, for: .tabBar)
            .navigationDestination(isPresented: destination) {
                Group {
                    if page == .notifications {
                        notificationSettings
                            .navigationTitle("Уведомления и звуки")
                    } else {
                        PlayerSupportView(account: account)
                            .navigationTitle("Поддержка")
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbarVisibility(.visible, for: .navigationBar)
                .toolbarVisibility(.hidden, for: .tabBar)
            }
            .background { Color.black.ignoresSafeArea() }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .task(id: selectedPhoto) {
            if let selectedPhoto { await loadPhoto(selectedPhoto) }
        }
        .alert("Не удалось открыть фото", isPresented: $photoFailed) {
            Button("ОК", role: .cancel) {}
        }
        .alert("Выйти из аккаунта?", isPresented: $confirmsSignOut) {
            Button("Отмена", role: .cancel) {}
            Button("Выйти", role: .destructive, action: onSignOut)
        }
    }

    private var profileControls: some View {
        HStack {
            if isEditing {
                Button("Отмена", systemImage: "xmark") { finishEditing() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
            } else {
                overviewLeadingControl
            }

            Spacer()

            if isEditing {
                Button("Сохранить", systemImage: "checkmark", action: save)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .foregroundStyle(.black)
                    .disabled(cleanGivenName.isEmpty || !emailIsValid || isLoadingPhoto)
            } else {
                Button("Редактировать профиль", systemImage: "pencil", action: startEditing)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .accessibilityIdentifier("profile.edit")
            }
        }
        .frame(height: PlayerHeaderLayout.height)
        .padding(.horizontal, PlayerHeaderLayout.sideInset)
        .padding(.top, PlayerHeaderLayout.topInset)
        .frame(maxWidth: PlayerHeaderLayout.contentWidth)
    }

    private func avatar(for profile: PlayerProfile) -> some View {
        Group {
            if let data = profile.avatar, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(profile.name.split(whereSeparator: \.isWhitespace).prefix(2)
                    .compactMap(\.first).map(String.init).joined().uppercased())
                    .font(.system(size: 24, weight: .semibold))
            }
        }
        .frame(width: 96, height: 96)
        .background(.white.opacity(0.12), in: .circle)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }

    private var profileDetails: some View {
        VStack(spacing: 4) {
            Text(account.profile.name)
                .font(.display(.title2, weight: .semibold))
            Text(verbatim: account.profile.email.replacingOccurrences(of: "@", with: "@\u{200B}"))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.74))
                .accessibilityLabel(Text(verbatim: account.profile.email))
            if !account.profile.phone.isEmpty {
                Text(account.profile.phone)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.74))
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var settingsOptions: some View {
        VStack(spacing: 0) {
            settingsRow("Уведомления и звуки", symbol: "bell", destination: .notifications)
            Divider().padding(.leading, 48)
            settingsRow("Поддержка", symbol: "bubble.left.and.bubble.right", destination: .support)
        }
        .background(.white.opacity(0.075), in: .rect(cornerRadius: 22))
        .clipShape(.rect(cornerRadius: 22))
    }

    private func settingsRow(_ title: String, symbol: String, destination: PlayerSettingsPage) -> some View {
        Button {
            page = destination
        } label: {
            HStack(spacing: 12) {
                Label {
                    Text(title).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: symbol).frame(width: 24)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 52)
        }
        .buttonStyle(PlayerRowButtonStyle())
    }

    private var notificationSettings: some View {
        Form {
            Toggle("Тренировки", isOn: $account.profile.trainingNotifications)
            Toggle("Абонемент", isOn: $account.profile.subscriptionNotifications)
            Toggle("Ответы поддержки", isOn: $account.profile.supportNotifications)
        }
        .tint(Color(uiColor: .systemGreen))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 0) {
                field("Имя", text: $draftGivenName, focus: .givenName, identifier: "profile.name")
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                Divider().padding(.leading, 16)
                field("Фамилия", text: $draftFamilyName, focus: .familyName, identifier: "profile.familyName")
                    .textContentType(.familyName)
                    .textInputAutocapitalization(.words)
                Divider().padding(.leading, 16)
                field("Почта", text: $draft.email, focus: .email, identifier: "profile.email")
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Divider().padding(.leading, 16)
                field("Телефон", text: $draft.phone, focus: .phone, identifier: "profile.phone")
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
            }
            .background(.white.opacity(0.075), in: .rect(cornerRadius: 22))

            if focusedField == .email && !cleanEmail.isEmpty && !emailIsValid {
                Text("Введите почту в формате name@example.com.")
                    .font(.footnote)
                    .foregroundStyle(Theme.warningOnDark)
            }

            Button {
                focusedField = nil
                confirmsSignOut = true
            } label: {
                Text("Выйти")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.warningOnDark)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .padding(.horizontal, 16)
            }
            .buttonStyle(PlayerRowButtonStyle(cornerRadius: 18))
            .background(.white.opacity(0.075), in: .rect(cornerRadius: 18))
        }
    }

    private func field(_ title: String, text: Binding<String>, focus: Field, identifier: String) -> some View {
        TextField(title, text: text)
            .focused($focusedField, equals: focus)
            .accessibilityIdentifier(identifier)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(minHeight: 52)
    }

    private func startEditing() {
        draft = account.profile
        let legacyName = draft.name.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        draftGivenName = draft.givenName ?? legacyName.first.map(String.init) ?? ""
        draftFamilyName = draft.familyName ?? legacyName.dropFirst().first.map(String.init) ?? ""
        withAnimation(reduceMotion ? nil : Motion.standard) {
            scrollPosition.scrollTo(edge: .top)
            page = .editProfile
        }
    }

    private func finishEditing() {
        focusedField = nil
        selectedPhoto = nil
        isLoadingPhoto = false
        withAnimation(reduceMotion ? nil : Motion.standard) {
            scrollPosition.scrollTo(edge: .top)
            page = .overview
        }
    }

    private func save() {
        var profile = account.profile
        profile.givenName = cleanGivenName
        profile.familyName = cleanFamilyName
        profile.name = cleanFamilyName.isEmpty ? cleanGivenName : "\(cleanGivenName) \(cleanFamilyName)"
        profile.email = cleanEmail
        profile.phone = draft.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.avatar = draft.avatar
        account.profile = profile
        finishEditing()
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        isLoadingPhoto = true
        let jpeg: Data?
        do {
            let data = try await item.loadTransferable(type: Data.self)
            jpeg = data.flatMap { PlayerPhoto.thumbnail(from: $0, maxPixelSize: 384)?.jpegData(compressionQuality: 0.86) }
        } catch {
            jpeg = nil
        }
        guard !Task.isCancelled, selectedPhoto == item, isEditing else { return }
        isLoadingPhoto = false
        if let jpeg {
            draft.avatar = jpeg
        } else {
            selectedPhoto = nil
            photoFailed = true
        }
    }
}
