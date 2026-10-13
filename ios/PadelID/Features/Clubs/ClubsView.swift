import SwiftUI
import Observation
import MapKit

/// The existing club directory, surfaced as a destination in its own right.
/// A club's player count means profile affiliations, not verified customers.
struct ClubsView: View {
    @Environment(AppModel.self) private var app
    @State private var city: NamedRef?
    @State private var searchText = ""
    @State private var model = ClubsCatalogModel()
    @State private var prepared = false
    @State private var showsMap = false
    @State private var isPickingCity = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        PadelNavigationStack {
            List {
                Section {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { cityChip; Spacer(minLength: 0); modePicker.frame(width: 190) }
                        VStack(alignment: .leading, spacing: 10) { cityChip; modePicker }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                if let city {
                    catalog(city)
                } else {
                    ContentUnavailableView("Выберите город", systemImage: "building.2",
                                           description: Text("Найдите клубы и игры там, где планируете играть."))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
            // The map stays in place above the list: a map inside the scrolling
            // list would take every drag that starts on it.
            .safeAreaInset(edge: .top, spacing: 0) {
                if showsMap, let city, model.cityID == city.id {
                    let clubs = model.visibleClubs(city: city, query: query)
                    if clubs.contains(where: { $0.coordinates != nil }) {
                        ClubDirectoryMap(clubs: clubs, city: city)
                            .frame(height: dynamicTypeSize.isAccessibilitySize ? 200 : 260)
                            .clipShape(.rect(cornerRadius: Theme.cornerRadius, style: .continuous))
                            .padding(.horizontal, Theme.horizontalPadding)
                            .padding(.bottom, 8)
                            .background(Theme.canvas)
                    }
                }
            }
            .navigationDestination(isPresented: $isPickingCity) { CityPickerView(selection: $city) }
            .navigationTitle("Клубы")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Название или адрес клуба")
            .autocorrectionDisabled()
            .refreshable {
                await model.load(city: city, using: app)
                await model.search(city: city, query: query, using: app, debounce: false)
            }
            .padelRoutes()
        }
        .onAppear {
            guard !prepared else { return }
            prepared = true
            city = app.me?.profile?.city
        }
        .task(id: "\(city?.id ?? 0).\(app.dataRevision)") { await model.load(city: city, using: app) }
        .task(id: "\(city?.id ?? 0).\(query).\(app.dataRevision)") {
            await model.search(city: city, query: query, using: app)
        }
    }

    /// The city the catalog shows, as one compact control next to the view switch.
    private var cityChip: some View {
        Button { isPickingCity = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "mappin.and.ellipse").imageScale(.small).foregroundStyle(Theme.accent)
                Text(city?.name ?? "Выберите город").lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(Theme.surface, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.padelCard)
        .accessibilityLabel("Город")
        .accessibilityValue(city?.name ?? "Не выбран")
        .accessibilityIdentifier("clubs.city")
    }

    @ViewBuilder
    private var modePicker: some View {
        if city != nil {
            Picker("Вид каталога", selection: $showsMap) {
                Text("Список").tag(false)
                Text("Карта").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("clubs.mode")
        }
    }

    private var query: String {
        String(searchText.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(60))
    }

    @ViewBuilder
    private func catalog(_ city: NamedRef) -> some View {
        let clubs = model.visibleClubs(city: city, query: query)
        if let resource = model.resource, model.cityID == city.id {
            if resource.isStale, let error = resource.error {
                Section { StaleDataBanner(error: error) }
            }
            if let error = model.searchFailure(city: city, query: query) {
                Section {
                    Label(error.message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Повторить поиск") {
                        Task { await model.search(city: city, query: query, using: app, debounce: false) }
                    }
                }
            }
            if !clubs.isEmpty {
                if showsMap, !clubs.contains(where: { $0.coordinates != nil }) {
                    Section {
                        Text("У этих клубов ещё не опубликованы координаты. Адреса можно посмотреть в карточках.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section(query.isEmpty ? "Клубы города" : "Результаты поиска") {
                    ForEach(clubs) { club in
                        NavigationLink(value: Route.club(club.club, city: city)) {
                            ClubCatalogRow(club: club)
                        }
                        .accessibilityIdentifier("clubs.row")
                    }
                }
                if clubs.count >= 100 {
                    Section {
                        Text("Уточните название в поиске, чтобы найти нужный клуб.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else if resource.value == nil {
                Section {
                    if let error = resource.error {
                        ErrorStateView(error: error) { Task { await model.load(city: city, using: app) } }
                    } else { ProgressView().frame(maxWidth: .infinity, minHeight: 80) }
                }
            } else if model.isSearching(city: city, query: query) {
                Section { ProgressView("Ищем клубы…").frame(maxWidth: .infinity, minHeight: 80) }
            } else {
                Section {
                    ContentUnavailableView(query.isEmpty ? "Клубов пока нет" : "Клуб не найден",
                                           systemImage: query.isEmpty ? "building.2" : "magnifyingglass",
                                           description: Text(query.isEmpty
                                               ? "Выберите другой город или проверьте каталог позже."
                                               : "Попробуйте другое название или выберите другой город."))
                }
                .accessibilityIdentifier("clubs.empty")
            }
        } else {
            Section { ProgressView().frame(maxWidth: .infinity, minHeight: 80) }
        }
    }
}

private struct ClubCatalogRow: View {
    let club: ClubCatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                SymbolPlate(symbol: PadelSymbol.court)
                VStack(alignment: .leading, spacing: 3) {
                    Text(club.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                    if let address = club.address, !address.isEmpty {
                        Text(address).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // What the club has, at a glance: courts, players, the first amenities.
            FlowLayout(spacing: 6) { facts }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var facts: some View {
        if let courts = club.courtsCount, courts > 0 {
            ClubFact(text: Format.count(courts, "корт", "корта", "кортов"), symbol: PadelSymbol.court)
        }
        ClubFact(text: Format.count(club.playersCount, "игрок", "игрока", "игроков"), symbol: "person.2.fill")
        if club.bookingVerifiedAt != nil, club.bookingUrl != nil {
            ClubFact(text: "Запись на сайте", symbol: "calendar")
        }
        ForEach((club.amenities ?? []).prefix(1), id: \.self) { amenity in
            ClubFact(text: amenity, symbol: nil)
        }
    }
}

/// One fact about a club in the catalog row.
private struct ClubFact: View {
    let text: String
    let symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(symbol: symbol).imageScale(.small).accessibilityHidden(true) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Theme.supportingText)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Theme.inset, in: .capsule)
    }
}

@Observable
private final class ClubsCatalogModel {
    private(set) var resource: Resource<[ClubCatalogEntry]>?
    private(set) var cityID: Int?
    private var remote: ClubCatalogSearchResult?
    private var searching: ClubCatalogSearchKey?
    private var failure: ClubCatalogSearchFailure?
    private var searchID = UUID()

    func load(city: NamedRef?, using app: AppModel) async {
        guard let city else { return }
        prepare(city: city)
        await resource?.load(using: app)
    }

    private func prepare(city: NamedRef) {
        if cityID != city.id {
            cityID = city.id
            resource = Resource(cacheKey: CacheKey.clubs(city.id)) {
                .get("v1/clubs", query: [URLQueryItem(name: "city_id", value: String(city.id))])
            }
            remote = nil
            failure = nil
        }
    }

    func visibleClubs(city: NamedRef, query: String) -> [ClubCatalogEntry] {
        if let remote, remote.key == ClubCatalogSearchKey(cityID: city.id, query: query) {
            return remote.clubs
        }
        guard cityID == city.id else { return [] }
        return (resource?.value ?? []).filter {
            query.isEmpty || [$0.name, $0.address ?? ""].contains {
                $0.lowercased().replacingOccurrences(of: "ё", with: "е").contains(query)
            }
        }
    }

    func isSearching(city: NamedRef, query: String) -> Bool {
        searching == ClubCatalogSearchKey(cityID: city.id, query: query)
    }

    func searchFailure(city: NamedRef, query: String) -> APIError? {
        guard failure?.key == ClubCatalogSearchKey(cityID: city.id, query: query) else { return nil }
        return failure?.error
    }

    func search(city: NamedRef?, query: String, using app: AppModel, debounce: Bool = true) async {
        let id = UUID()
        searchID = id
        failure = nil
        guard let city, !query.isEmpty else { searching = nil; return }
        prepare(city: city)
        let key = ClubCatalogSearchKey(cityID: city.id, query: query)
        searching = key
        defer { if searchID == id { searching = nil } }
        do {
            if debounce { try await Task.sleep(for: .milliseconds(300)) }
            let clubs = try await app.api.send(.get("v1/clubs", query: [
                URLQueryItem(name: "city_id", value: String(city.id)), URLQueryItem(name: "query", value: query)
            ]), as: [ClubCatalogEntry].self)
            guard searchID == id, !Task.isCancelled else { return }
            remote = ClubCatalogSearchResult(key: key, clubs: clubs)
        } catch is CancellationError { }
        catch let error as APIError {
            guard searchID == id, !Task.isCancelled else { return }
            failure = ClubCatalogSearchFailure(key: key, error: error)
        } catch {
            guard searchID == id, !Task.isCancelled else { return }
            failure = ClubCatalogSearchFailure(key: key, error: APIError(kind: .decoding, code: "decoding", serverMessage: nil))
        }
    }
}

private nonisolated struct ClubCatalogSearchKey: Equatable { let cityID: Int; let query: String }
private nonisolated struct ClubCatalogSearchResult { let key: ClubCatalogSearchKey; let clubs: [ClubCatalogEntry] }
private nonisolated struct ClubCatalogSearchFailure { let key: ClubCatalogSearchKey; let error: APIError }


private struct ClubDirectoryMap: View {
    let clubs: [ClubCatalogEntry]
    let city: NamedRef
    var body: some View {
        Map {
            ForEach(clubs) { club in
                if let location = club.coordinates {
                    Annotation(club.name, coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)) {
                        NavigationLink(value: Route.club(club.club, city: city)) {
                            Image(PadelSymbol.racket)
                                .font(.title3.bold()).padding(12)
                                .foregroundStyle(Theme.ink).background(Theme.lime, in: .circle)
                        }
                        .accessibilityLabel("Клуб «\(club.name)»")
                    }.annotationTitles(.hidden)
                }
            }
        }
        .mapControlVisibility(.visible)
        .accessibilityLabel("Клубы с опубликованными координатами. Те же клубы доступны в списке ниже.")
    }
}
