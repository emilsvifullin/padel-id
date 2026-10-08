import SwiftUI

// MARK: - Search text

/// Normalisation of search text and names, mirroring the server's
/// `private.norm`: lowercase, «ё» → «е», collapsed whitespace.
private nonisolated enum SharedLocationSearchText {
    static func normalized(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// The text as typed, trimmed and with collapsed whitespace.
    static func cleaned(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

// MARK: - City picker

private nonisolated struct SharedCitySearchResult: Sendable {
    let query: String
    let cities: [City]
}

private nonisolated struct SharedCityCountryGroup: Identifiable, Sendable {
    let code: String
    let name: String
    let cities: [City]

    var id: String { code }

    private static let names: [String: String] = [
        "RU": "Россия", "BY": "Беларусь", "KZ": "Казахстан", "UZ": "Узбекистан", "KG": "Киргизия",
        "TJ": "Таджикистан", "AM": "Армения", "GE": "Грузия", "AZ": "Азербайджан", "LV": "Латвия",
        "EE": "Эстония", "LT": "Литва", "AE": "ОАЭ", "QA": "Катар", "TR": "Турция", "CY": "Кипр",
        "ES": "Испания", "IT": "Италия", "PT": "Португалия", "FR": "Франция", "GB": "Великобритания",
        "DE": "Германия", "SE": "Швеция", "NL": "Нидерланды", "BE": "Бельгия", "FI": "Финляндия",
        "DK": "Дания", "RS": "Сербия", "ME": "Черногория", "AR": "Аргентина", "MX": "Мексика",
        "US": "США", "TH": "Таиланд", "ID": "Индонезия",
    ]

    static func countryName(for code: String) -> String {
        if let name = names[code] { return name }
        return Locale(identifier: "ru_RU").localizedString(forRegionCode: code) ?? code
    }

    /// Groups cities by country: Russia first, then countries by Russian name.
    /// The server order (popular cities first, then alphabetical) is kept within a country.
    static func groups(_ cities: [City]) -> [SharedCityCountryGroup] {
        let locale = Locale(identifier: "ru_RU")
        return Dictionary(grouping: cities, by: { $0.countryCode })
            .map { SharedCityCountryGroup(code: $0.key, name: countryName(for: $0.key), cities: $0.value) }
            .sorted { lhs, rhs in
                if lhs.code == "RU" { return rhs.code != "RU" }
                if rhs.code == "RU" { return false }
                return lhs.name.compare(rhs.name, locale: locale) == .orderedAscending
            }
    }
}

/// City selection pushed inside a NavigationStack: searchable list grouped by
/// country. Selecting a city sets the binding and returns.
struct CityPickerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Binding private var selection: NamedRef?
    @State private var cities = Resource<[City]>(cacheKey: CacheKey.cities) { .get("v1/cities") }
    @State private var searchText = ""
    @State private var remote: SharedCitySearchResult?

    init(selection: Binding<NamedRef?>) {
        _selection = selection
    }

    var body: some View {
        List {
            if cities.isStale, cities.error?.isNetwork == true {
                Section {
                    OfflineBanner()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            ForEach(SharedCityCountryGroup.groups(visibleCities)) { country in
                Section(country.name) {
                    ForEach(country.cities) { city in
                        row(city)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            overlayContent
        }
        .navigationTitle("Город")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Название города")
        .autocorrectionDisabled()
        .sensoryFeedback(.selection, trigger: selection)
        .task { await cities.load(using: app) }
        .task(id: query) { await search(query) }
    }

    private var query: String { SharedLocationSearchText.normalized(searchText) }

    /// Server results for the current query once they arrive; until then (or
    /// offline) the full list filtered locally, so typing feels instant.
    private var visibleCities: [City] {
        guard !query.isEmpty else { return cities.value ?? [] }
        if let remote, remote.query == query { return remote.cities }
        return (cities.value ?? []).filter { SharedLocationSearchText.normalized($0.name).contains(query) }
    }

    @ViewBuilder
    private var overlayContent: some View {
        if visibleCities.isEmpty {
            if cities.value == nil && remote?.query != query {
                if let error = cities.error {
                    ErrorStateView(error: error) {
                        Task { await cities.load(using: app) }
                    }
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
            } else if !query.isEmpty {
                ContentUnavailableView {
                    Label("Город не найден", systemImage: "magnifyingglass")
                } description: {
                    Text("Проверьте название или выберите ближайший город.")
                }
            }
        }
    }

    private func row(_ city: City) -> some View {
        let isSelected = selection?.id == city.id
        return Button {
            selection = NamedRef(id: city.id, name: city.name)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(city.name)
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .contentShape(.rect)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func search(_ query: String) async {
        guard !query.isEmpty else { return }
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        let endpoint = Endpoint.get("v1/cities", query: [URLQueryItem(name: "query", value: query)])
        guard let found = try? await app.api.send(endpoint, as: [City].self) else { return }
        remote = SharedCitySearchResult(query: query, cities: found)
    }
}

// MARK: - Club picker

private nonisolated struct SharedClubSearchResult: Sendable {
    let query: String
    let clubs: [Club]
}

private nonisolated struct SharedClubCreateBody: Encodable, Sendable {
    let cityId: Int
    let name: String
}

/// Club selection for a city, pushed inside a NavigationStack. Offers "Без
/// клуба" and adding a missing club. Selecting sets the binding and returns.
struct ClubPickerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Binding private var selection: NamedRef?
    @State private var clubs: Resource<[Club]>
    @State private var searchText = ""
    @State private var remote: SharedClubSearchResult?
    @State private var isCreating = false
    @State private var createError: APIError?
    private let cityId: Int

    init(cityId: Int, selection: Binding<NamedRef?>) {
        self.cityId = cityId
        _selection = selection
        _clubs = State(initialValue: Resource<[Club]>(cacheKey: CacheKey.clubs(cityId)) {
            .get("v1/clubs", query: [URLQueryItem(name: "city_id", value: String(cityId))])
        })
    }

    var body: some View {
        List {
            if clubs.isStale, clubs.error?.isNetwork == true {
                Section {
                    OfflineBanner()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            if query.isEmpty {
                Section {
                    noClubRow
                }
            }

            clubsSection

            if showsAddRow {
                addSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Клуб")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Название клуба")
        .autocorrectionDisabled()
        .sensoryFeedback(.selection, trigger: selection)
        .sensoryFeedback(.error, trigger: createError) { _, new in new != nil }
        .task { await clubs.load(using: app) }
        .task(id: query) { await search(query) }
        .onChange(of: searchText) { createError = nil }
    }

    private var query: String { SharedLocationSearchText.normalized(searchText) }

    /// The club name as it would be created.
    private var newClubName: String { SharedLocationSearchText.cleaned(searchText) }

    private var visibleClubs: [Club] {
        guard !query.isEmpty else { return clubs.value ?? [] }
        if let remote, remote.query == query { return remote.clubs }
        return (clubs.value ?? []).filter { SharedLocationSearchText.normalized($0.name).contains(query) }
    }

    private var hasExactMatch: Bool {
        let known = visibleClubs + (clubs.value ?? [])
        return known.contains { SharedLocationSearchText.normalized($0.name) == query }
    }

    private var showsAddRow: Bool {
        newClubName.unicodeScalars.count >= 2 && !hasExactMatch
    }

    /// `public.create_club`: 2–60 characters with at least one letter or digit.
    private var isValidNewName: Bool {
        let length = newClubName.unicodeScalars.count
        return (2...60).contains(length) && newClubName.contains { $0.isLetter || $0.isNumber }
    }

    // MARK: Rows

    private var noClubRow: some View {
        Button {
            selection = nil
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text("Без клуба")
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selection == nil {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .contentShape(.rect)
        }
        .accessibilityAddTraits(selection == nil ? .isSelected : [])
    }

    @ViewBuilder
    private var clubsSection: some View {
        if !visibleClubs.isEmpty {
            Section {
                ForEach(visibleClubs) { club in
                    row(club)
                }
            } header: {
                Text(query.isEmpty ? "Клубы города" : "Найдено")
            }
        } else if clubs.value == nil && remote?.query != query {
            Section {
                if let error = clubs.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error.isNetwork ? "Нет подключения" : "Не удалось загрузить клубы",
                              systemImage: error.isNetwork ? "wifi.slash" : "exclamationmark.triangle")
                            .font(.headline)
                        Text(error.message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Повторить") {
                            Task { await clubs.load(using: app) }
                        }
                        .buttonStyle(.borderless)
                        .frame(minHeight: 44)
                    }
                    .padding(.vertical, 4)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        } else if query.isEmpty {
            Section {
                Text("В этом городе пока нет клубов. Введите название в поиске, чтобы добавить свой.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Section {
                Text("Клуб «\(newClubName)» не найден.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ club: Club) -> some View {
        let isSelected = selection?.id == club.id
        return Button {
            selection = NamedRef(id: club.id, name: club.name)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(club.name)
                        .foregroundStyle(Color.primary)
                    Text(playersText(club.playersCount))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .contentShape(.rect)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var addSection: some View {
        Section {
            Button {
                Task { await createClub() }
            } label: {
                HStack(spacing: 12) {
                    Label {
                        Text("Добавить клуб «\(newClubName)»")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if isCreating {
                        ProgressView()
                    }
                }
                .contentShape(.rect)
            }
            .disabled(isCreating || !isValidNewName || !app.isOnline)
        } footer: {
            if let createError {
                Text(createError.message)
                    .foregroundStyle(Theme.negative)
            } else if !isValidNewName {
                Text("Название клуба — от 2 до 60 символов.")
            } else if !app.isOnline {
                Text("Добавить клуб можно при подключении к интернету.")
            } else {
                Text("Клуб появится в списке для всех игроков города.")
            }
        }
    }

    private func playersText(_ count: Int) -> String {
        count == 0 ? "Пока нет игроков" : Format.count(count, "игрок", "игрока", "игроков")
    }

    // MARK: Actions

    private func search(_ query: String) async {
        guard !query.isEmpty else { return }
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        let endpoint = Endpoint.get("v1/clubs", query: [
            URLQueryItem(name: "city_id", value: String(cityId)),
            URLQueryItem(name: "query", value: query),
        ])
        guard let found = try? await app.api.send(endpoint, as: [Club].self) else { return }
        remote = SharedClubSearchResult(query: query, clubs: found)
    }

    private func createClub() async {
        let name = newClubName
        guard isValidNewName, !isCreating else { return }
        isCreating = true
        createError = nil
        defer { isCreating = false }
        do {
            let club = try await app.api.send(
                .json(.post, "v1/clubs", SharedClubCreateBody(cityId: cityId, name: name)),
                as: Club.self)
            selection = NamedRef(id: club.id, name: club.name)
            // The cached list no longer includes every club of the city.
            app.cache.remove(CacheKey.clubs(cityId))
            dismiss()
        } catch is CancellationError {
            return
        } catch let error as APIError {
            createError = error
        } catch {
            createError = APIError(kind: .decoding, code: "decoding", serverMessage: nil)
        }
    }
}
