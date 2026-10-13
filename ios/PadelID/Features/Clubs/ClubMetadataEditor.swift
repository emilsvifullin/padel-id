import SwiftUI

struct ClubMetadataEditor: View {
    let club: ClubCatalogEntry
    let saved: (ClubCatalogEntry) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ClubMetadataDraft
    @State private var working = false
    @State private var failure: APIError?
    @State private var hasConflict = false
    @State private var permissionRevoked = false

    init(club: ClubCatalogEntry, saved: @escaping (ClubCatalogEntry) -> Void) {
        self.club = club
        self.saved = saved
        _draft = State(initialValue: ClubMetadataDraft(club: club))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Описание") {
                    TextField("Описание клуба", text: $draft.description, axis: .vertical).lineLimit(4...12)
                    TextField("Адрес", text: $draft.address, axis: .vertical).lineLimit(1...3)
                }
                Section {
                    TextField("Широта", text: $draft.latitude).keyboardType(.numbersAndPunctuation)
                    TextField("Долгота", text: $draft.longitude).keyboardType(.numbersAndPunctuation)
                } header: { Text("Координаты") } footer: {
                    Text("Укажите оба значения в десятичных градусах или оставьте оба поля пустыми. Карта появится после сохранения координат.")
                }
                Section {
                    TextField("Фотографии: один HTTPS-адрес на строку", text: $draft.photos, axis: .vertical)
                        .lineLimit(3...8).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Инфраструктура: один пункт на строку", text: $draft.amenities, axis: .vertical).lineLimit(3...8)
                } header: { Text("Фотографии и инфраструктура") }
                footer: { Text("До 12 фотографий по публичным HTTPS-адресам и до 24 пунктов инфраструктуры.") }
                Section("Контакты") {
                    TextField("Телефон", text: $draft.phone).keyboardType(.phonePad)
                    TextField("Сайт клуба", text: $draft.website).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    TextField("Официальный сервис бронирования", text: $draft.booking).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !draft.booking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Toggle("Проверил, что это официальный сервис клуба", isOn: $draft.bookingVerified)
                    }
                } header: { Text("Бронирование") }
                footer: { Text("Ссылка открывает внешний сервис. Расписание, оплата и подтверждение бронирования остаются у клуба. Сохраняйте только проверенную официальную ссылку.") }
                Section("Основание изменения") {
                    TextField("Что проверено и откуда получены сведения", text: $draft.reason, axis: .vertical).lineLimit(2...5).accessibilityIdentifier("clubEditor.reason")
                }
                if let validation = draft.validationMessage {
                    Section { Text(validation).font(.footnote).foregroundStyle(.secondary) }
                }
                if let failure {
                    Section {
                        Label(failure.message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.negative)
                        if hasConflict {
                            Text("Клуб изменён другим администратором. Загрузите текущую информацию и проверьте её перед сохранением.")
                                .font(.subheadline)
                            Button("Загрузить текущую информацию") { Task { await reload() } }
                        }
                    }
                }
            }
            .disabled(working).scrollContentBackground(.hidden).background(Theme.canvas)
            .navigationTitle("О клубе").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(working) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { Task { await save() } }.accessibilityIdentifier("clubEditor.save")
                        .disabled(working || hasConflict || permissionRevoked || draft.validationMessage != nil || !app.isOnline || app.me?.isAdmin != true)
                }
            }
            .interactiveDismissDisabled(working)
            .onChange(of: draft.booking) { _, _ in draft.bookingVerified = false }
        }
    }

    private func save() async {
        guard !working, !hasConflict, !permissionRevoked, draft.validationMessage == nil, app.me?.isAdmin == true else { return }
        working = true; failure = nil
        defer { working = false }
        do {
            let result = try await app.api.send(.json(.patch, "v1/admin/clubs/\(club.id)", draft.body), as: ClubCatalogEntry.self)
            saved(result)
            app.dataDidChange()
            dismiss()
        } catch let error as APIError { failure = error; hasConflict = error.status == 409; permissionRevoked = error.status == 401 || error.status == 403 }
        catch { failure = APIError(kind: .decoding, code: "decoding", serverMessage: nil) }
    }

    private func reload() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            let result = try await app.api.send(.get("v1/clubs/\(club.id)"), as: ClubCatalogEntry.self)
            guard result.viewer?.canEdit == true else {
                failure = APIError(kind: .server(status: 403), code: "forbidden", serverMessage: nil)
                return
            }
            draft = ClubMetadataDraft(club: result)
            saved(result)
            failure = nil; hasConflict = false
        } catch let error as APIError { failure = error }
        catch { failure = APIError(kind: .decoding, code: "decoding", serverMessage: nil) }
    }
}

/// A complete snapshot is sent with its original metadata version. Explicit
/// null values remove fields instead of silently leaving the old value behind.
nonisolated struct ClubMetadataDraft {
    var version: Int
    var description: String
    var address: String
    var latitude: String
    var longitude: String
    var photos: String
    var amenities: String
    var phone: String
    var website: String
    var booking: String
    var bookingVerified: Bool
    var reason = ""

    init(club: ClubCatalogEntry) {
        version = club.metadataVersion ?? 0
        description = club.description ?? ""
        address = club.address ?? ""
        latitude = club.latitude.map { String($0) } ?? ""
        longitude = club.longitude.map { String($0) } ?? ""
        photos = (club.photoUrls ?? []).joined(separator: "\n")
        amenities = (club.amenities ?? []).joined(separator: "\n")
        phone = club.contactPhone ?? ""
        website = club.websiteUrl ?? ""
        booking = club.bookingUrl ?? ""
        bookingVerified = club.bookingVerifiedAt != nil
    }

    var validationMessage: String? {
        if description.count > 2_000 { return "Описание должно быть не длиннее 2000 символов." }
        if address.count > 300 { return "Адрес должен быть не длиннее 300 символов." }
        let lat = number(latitude), lon = number(longitude)
        if trimmed(latitude).isEmpty != trimmed(longitude).isEmpty { return "Укажите широту и долготу вместе." }
        if !trimmed(latitude).isEmpty && (lat == nil || lon == nil || !(-90...90).contains(lat ?? 91) || !(-180...180).contains(lon ?? 181)) {
            return "Проверьте координаты: широта от −90 до 90, долгота от −180 до 180."
        }
        let images = lines(photos)
        if images.count > 12 || images.contains(where: { ClubExternalURL.publicHTTPS($0) == nil }) { return "Укажите до 12 публичных HTTPS-адресов фотографий." }
        let facilities = lines(amenities)
        if facilities.count > 24 || facilities.contains(where: { !(2...60).contains($0.count) }) || Set(facilities).count != facilities.count {
            return "Укажите до 24 разных пунктов инфраструктуры, каждый от 2 до 60 символов."
        }
        if !trimmed(phone).isEmpty && (!(5...32).contains(trimmed(phone).count) || trimmed(phone).contains(where: { !"+0123456789 ()-".contains($0) })) { return "Телефон: от 5 до 32 символов, цифры, пробелы, +, скобки и дефисы." }
        if !trimmed(address).isEmpty && trimmed(address).count < 2 { return "Адрес должен содержать не менее 2 символов." }
        if !trimmed(website).isEmpty && ClubExternalURL.publicHTTPS(trimmed(website)) == nil { return "Сайт клуба должен иметь публичный HTTPS-адрес." }
        if !trimmed(booking).isEmpty && (ClubExternalURL.publicHTTPS(trimmed(booking)) == nil || !bookingVerified) { return "Проверьте официальный HTTPS-адрес бронирования и подтвердите проверку." }
        if !(5...400).contains(trimmed(reason).count) { return "Укажите основание изменения: от 5 до 400 символов." }
        if version < 1 { return "Сначала загрузите текущую информацию о клубе." }
        return nil
    }

    var body: ClubMetadataBody {
        ClubMetadataBody(version: version, description: trimmed(description), address: optional(address),
                         latitude: number(latitude), longitude: number(longitude), photoUrls: lines(photos),
                         amenities: lines(amenities), contactPhone: optional(phone), websiteUrl: optional(website),
                         bookingUrl: optional(booking), bookingVerified: !trimmed(booking).isEmpty && bookingVerified, reason: trimmed(reason))
    }
    private func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func optional(_ value: String) -> String? { trimmed(value).isEmpty ? nil : trimmed(value) }
    private func lines(_ value: String) -> [String] { value.split(whereSeparator: \.isNewline).map { trimmed(String($0)) }.filter { !$0.isEmpty } }
    private func number(_ value: String) -> Double? {
        guard let result = Double(trimmed(value).replacingOccurrences(of: ",", with: ".")), result.isFinite else { return nil }
        return result
    }
}
