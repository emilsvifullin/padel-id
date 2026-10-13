import SwiftUI
import MapKit

struct ClubDetailView: View {
    let club: Club
    let city: NamedRef
    @Environment(AppModel.self) private var app
    @State private var details: Resource<ClubCatalogEntry>
    @State private var games: [UpcomingMatch] = []
    @State private var nextOffset: Int?
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var error: APIError?
    @State private var requestID = UUID()
    @State private var lastAttemptedOffset = 0
    @State private var editing = false
    @State private var editingCourt: ClubCourt?
    @State private var addingCourt = false

    init(club: Club, city: NamedRef) {
        self.club = club
        self.city = city
        _details = State(initialValue: Resource(cacheKey: nil) { .get("v1/clubs/\(club.id)") })
    }

    var body: some View {
        List {
            header
            if let value = details.value {
                if details.isStale, let error = details.error { Section { StaleDataBanner(error: error) } }
                facts(value)
                courts(value)
                Section("Тренировки и турниры") {
                    NavigationLink(value: Route.clubEvents(club.id, name: club.name)) { Label("События в этом клубе", systemImage: "calendar") }.accessibilityIdentifier("club.events")
                }
                Section("Сообщество клуба") {
                    NavigationLink(value: Route.clubNews(club.id, name: club.name)) {
                        Label("Новости клуба", systemImage: "newspaper")
                    }.accessibilityIdentifier("club.news")
                }
                if canEdit(value) {
                    Section("Управление клубом") {
                        Button("Изменить информацию", systemImage: "pencil") { editing = true }
                            .disabled(!app.isOnline).accessibilityIdentifier("club.edit")
                        Button("Добавить корт", systemImage: "plus") { addingCourt = true }
                            .disabled(!app.isOnline)
                    }
                }
            } else if let error = details.error {
                Section { ErrorStateView(error: error) { Task { await details.load(using: app) } } }
            } else { Section { ProgressView("Загружаем информацию…") } }
            gameSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .navigationTitle("Клуб")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task(id: app.dataRevision) { await refresh() }
        .sheet(isPresented: $editing, onDismiss: { Task { await details.load(using: app) } }) {
            if let value = details.value {
                ClubMetadataEditor(club: value) { updated in details.replace(with: updated) }
            }
        }
        .sheet(item: $editingCourt) { court in
            ClubCourtEditor(clubID: club.id, court: court) { Task { await details.load(using: app) } }
        }
        .sheet(isPresented: $addingCourt) {
            ClubCourtEditor(clubID: club.id, court: nil) { Task { await details.load(using: app) } }
        }
    }

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                PerforationGrid(dot: 9, gap: 5, color: Theme.lime).padding(.bottom, 26)
                Text(club.name).font(.display(.title2, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                Label(city.name, systemImage: "mappin.and.ellipse").font(.subheadline)
                Text(Format.count(club.playersCount, "игрок", "игрока", "игроков") + " в сообществе клуба")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .inkCard()
            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            .accessibilityElement(children: .combine).accessibilityIdentifier("club.details")
        }
    }

    @ViewBuilder private func facts(_ value: ClubCatalogEntry) -> some View {
        if let description = value.description, !description.isEmpty {
            Section("О клубе") { Text(description).fixedSize(horizontal: false, vertical: true) }
        }
        if !value.photos.isEmpty {
            Section("Фотографии") {
                ForEach(Array(value.photos.enumerated()), id: \.offset) { index, url in
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFit() }
                        else if phase.error != nil {
                            Label("Фотография недоступна", systemImage: "photo").foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 100)
                        } else { ProgressView().frame(maxWidth: .infinity, minHeight: 100) }
                    }
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityLabel("Фотография клуба \(index + 1)")
                }
            }
        }
        Section("Как добраться") {
            if let address = value.address, !address.isEmpty {
                Label(address, systemImage: "mappin.and.ellipse").textSelection(.enabled)
            } else { Text("Адрес ещё не опубликован").foregroundStyle(.secondary) }
            if let location = value.coordinates {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)))) {
                    Marker(club.name, coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude))
                        .annotationTitles(.hidden)
                }.id(location).frame(height: 230).clipShape(.rect(cornerRadius: 12))
                    .accessibilityIdentifier("club.map").accessibilityLabel("Карта клуба. Координаты: \(location.latitude), \(location.longitude)")
                Button("Открыть в Картах", systemImage: "map") {
                    let item = MKMapItem(location: CLLocation(latitude: location.latitude, longitude: location.longitude), address: nil)
                    item.name = club.name
                    item.openInMaps()
                }
            }
        }
        if let amenities = value.amenities, !amenities.isEmpty {
            Section("Инфраструктура") { ForEach(amenities, id: \.self) { Text($0) } }
        }
        if value.contactPhone != nil || value.websiteUrl != nil || value.officialBookingURL != nil {
            Section {
                if let phone = value.contactPhone, !phone.isEmpty { Label(phone, systemImage: "phone").textSelection(.enabled) }
                if let website = value.websiteUrl.flatMap(ClubExternalURL.publicHTTPS) {
                    Link("Сайт клуба", destination: website)
                }
                if let booking = value.officialBookingURL {
                    Link("Бронировать на сайте клуба", destination: booking).accessibilityIdentifier("club.booking")
                }
            } header: { Text("Связаться с клубом") } footer: {
                if value.officialBookingURL != nil {
                    Text("Вы перейдёте на официальный сервис клуба. Расписание, подтверждение и оплата выполняются там.")
                }
            }
        }
    }

    @ViewBuilder private func courts(_ value: ClubCatalogEntry) -> some View {
        Section {
            if let courts = value.courts, !courts.isEmpty {
                ForEach(courts) { court in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(court.name).font(.headline)
                        Text(court.indoor ? "Крытый корт" : "Открытый корт").font(.subheadline).foregroundStyle(.secondary)
                        if !court.surface.isEmpty { Text(court.surface).font(.subheadline) }
                        if !court.description.isEmpty { Text(court.description).font(.subheadline) }
                        if !court.isActive { Label("Скрыт из каталога", systemImage: "eye.slash").font(.caption) }
                        if canEdit(value) {
                            Button("Изменить корт") { editingCourt = court }.disabled(!app.isOnline)
                        }
                    }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
                }
            } else { Text("Информация о кортах ещё не опубликована").foregroundStyle(.secondary) }
        } header: { Text("Корты") } footer: { Text("Каталог кортов не показывает свободные интервалы. Доступность уточняйте у клуба.") }
    }

    private func canEdit(_ value: ClubCatalogEntry) -> Bool { app.me?.isAdmin == true && value.viewer?.canEdit == true && !details.isStale }

    private var gameSection: some View {
        Section {
            if let error {
                Label(error.message, systemImage: error.isNetwork ? "wifi.slash" : "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Повторить") { Task { await loadGames(offset: lastAttemptedOffset) } }.disabled(isLoading)
            }
            ForEach(games) { match in
                NavigationLink(value: Route.upcoming(match.id)) { UpcomingMatchRow(match: match) }.accessibilityIdentifier("club.game")
            }
            if isLoading { ProgressView().frame(maxWidth: .infinity, minHeight: 60) }
            else if let nextOffset {
                Button("Ещё игры") { Task { await loadGames(offset: nextOffset) } }.disabled(isLoading).accessibilityIdentifier("club.moreGames")
            } else if hasLoaded && games.isEmpty && error == nil {
                ContentUnavailableView("Открытых игр пока нет", systemImage: "tennis.racket",
                                       description: Text("Игры в этом клубе появятся здесь после публикации участниками."))
                    .accessibilityIdentifier("club.gamesEmpty")
            }
        } header: { Text("Открытые игры в клубе") }
        footer: { Text("Участие в игре не является бронированием корта. Время и условия использования корта согласуйте с клубом.") }
    }

    private func refresh() async {
        await details.load(using: app)
        await loadGames(offset: 0)
    }

    private func loadGames(offset: Int) async {
        let id = UUID(); requestID = id; lastAttemptedOffset = offset; isLoading = true
        defer { if requestID == id { isLoading = false } }
        do {
            let page = try await app.api.send(.get("v1/upcoming-matches", query: [
                URLQueryItem(name: "scope", value: "open"), URLQueryItem(name: "city_id", value: String(city.id)),
                URLQueryItem(name: "club_id", value: String(club.id)), URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "offset", value: String(offset))
            ]), as: UpcomingPage.self)
            guard requestID == id, !Task.isCancelled else { return }
            // Defend against an older gateway that does not support the filter.
            let found = page.items.filter { $0.club?.id == club.id && !$0.isClosed && $0.startsAt > .now }
            if offset == 0 { games = found }
            else { let ids = Set(games.map(\.id)); games += found.filter { !ids.contains($0.id) } }
            nextOffset = page.nextOffset; hasLoaded = true; error = nil
        } catch is CancellationError { }
        catch let failure as APIError {
            guard requestID == id, !Task.isCancelled else { return }
            error = failure
            if failure.status == 401 || failure.status == 403 { games = []; nextOffset = nil }
        } catch {
            guard requestID == id, !Task.isCancelled else { return }
            self.error = APIError(kind: .decoding, code: "decoding", serverMessage: nil)
        }
    }
}
