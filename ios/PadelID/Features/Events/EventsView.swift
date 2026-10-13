import SwiftUI

/// Push inside Games. All catalog content comes from persisted event records.
struct EventsView: View {
    var organizerId: UUID? = nil
    var initialMine = false
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var kind: SportEventKind = .training
    @State private var mine = false
    @State private var city: NamedRef?
    @State private var allCities = false
    @State private var events = CommunityCollection<SportEvent>("v1/events", windowLimit: 150)
    @State private var collectionKey = ""
    private var items: [SportEvent] { events.items }
    private var nextOffset: Int? { events.nextOffset }
    private var isLoading: Bool { events.isLoading }
    private var error: APIError? { events.error }
    private var hasLoaded: Bool { events.hasLoaded }
    @State private var isCreating = false
    @State private var prepared = false
    @State private var isPickingCity = false

    var body: some View {
        List {
            Section {
                if organizerId == nil {
                    VStack(spacing: 10) {
                        Picker("События", selection: $kind) {
                            ForEach(SportEventKind.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("events.kind")
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { scopePicker; cityFilter }
                            VStack(alignment: .leading, spacing: 10) { scopePicker; cityFilter }
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } else {
                    Text("Доступные занятия этого тренера. Условия и свободные места указаны в каждом событии.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error {
                Section {
                    Label(error.message, systemImage: error.isNetwork ? "wifi.slash" : "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Повторить") { Task { await load(offset: 0) } }.disabled(isLoading)
                }
            }
            ForEach(items) { event in
                NavigationLink(value: Route.event(event.id)) { EventCatalogRow(event: event) }
                    .accessibilityIdentifier("events.row")
            }
            if isLoading { ProgressView().frame(maxWidth: .infinity, minHeight: 60) }
            else if hasLoaded && items.isEmpty && error == nil {
                ContentUnavailableView(mine ? "Пока нет ваших событий" : "Событий пока нет", systemImage: kind.symbol,
                                       description: Text(organizerId != nil ? "Тренер пока не опубликовал ближайшие занятия. Проверьте расписание позже." : mine ? "Здесь появятся ваши записи, приглашения и созданные события." : "Проверьте другой город или опубликуйте своё событие."))
                    .accessibilityIdentifier("events.empty")
            }
            if let nextOffset {
                Button("Ещё события") { Task { await load(offset: nextOffset) } }.disabled(isLoading)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .navigationTitle(organizerId == nil ? "Тренировки и турниры" : "Занятия тренера")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if organizerId == nil { ToolbarItem(placement: .topBarTrailing) {
                Button("Создать событие", systemImage: "plus") { isCreating = true }
                    .disabled(!app.isOnline).accessibilityIdentifier("events.create")
            } }
        }
        .sheet(isPresented: $isCreating) { EventCreateView(initialKind: kind) }
        .navigationDestination(isPresented: $isPickingCity) { CityPickerView(selection: $city) }
        .onChange(of: city) { allCities = false }
        .refreshable { await load(offset: 0) }
        .onAppear {
            guard !prepared else { return }
            prepared = true
            mine = initialMine
            if organizerId == nil { city = app.me?.profile?.city }
        }
        .task(id: taskKey) {
            guard scenePhase == .active else { return }
            configureCollection()
            if events.hasLoaded { await events.refreshVisibleWindow(using: app) }
            else { await events.load(using: app) }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard app.isOnline, scenePhase == .active else { continue }
                await events.refreshVisibleWindow(using: app)
            }
        }
        .padelRoutes()
    }

    private var scopePicker: some View {
        Picker("Участие", selection: $mine) {
            Text("Ближайшие").tag(false)
            Text("Мои").tag(true)
        }.pickerStyle(.segmented).accessibilityIdentifier("events.scope")
    }

    /// Where to look, next to whose events: the catalog narrows to one city
    /// or opens to all of them. Own events are not tied to a city.
    @ViewBuilder
    private var cityFilter: some View {
        if !mine {
            Menu {
                Button("Все города", systemImage: "globe") { allCities = true }
                Button("Выбрать город", systemImage: "mappin.and.ellipse") { isPickingCity = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: allCities ? "globe" : "mappin.and.ellipse").imageScale(.small)
                    Text(allCities ? "Все города" : city?.name ?? "Город").lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(Theme.surface, in: .capsule)
                .contentShape(.capsule)
            }
            .accessibilityLabel("Город")
            .accessibilityValue(allCities ? "Все города" : city?.name ?? "Не выбран")
            .accessibilityIdentifier("events.city")
        }
    }

    private var taskKey: String { "\(filterKey).\(app.dataRevision).\(scenePhase)" }
    private var filterKey: String { "\(kind.rawValue).\(mine).\(organizerId?.uuidString ?? "all").\(mine || allCities ? 0 : city?.id ?? 0)" }

    private func configureCollection() {
        guard collectionKey != filterKey else { return }
        var query = [URLQueryItem(name: "kind", value: kind.rawValue),
                     URLQueryItem(name: "scope", value: mine ? "mine" : "upcoming")]
        if let organizerId {
            query.append(URLQueryItem(name: "organizer_id", value: organizerId.uuidString.lowercased()))
        } else if !mine && !allCities, let city { query.append(URLQueryItem(name: "city_id", value: String(city.id))) }
        events = CommunityCollection("v1/events", query: query, windowLimit: 150)
        collectionKey = filterKey
    }

    private func load(offset: Int) async {
        configureCollection()
        await events.load(using: app, more: offset > 0)
    }

}

/// A training or tournament in the catalog: what, when, where and how full.
private struct EventCatalogRow: View {
    let event: SportEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                SymbolPlate(symbol: event.kind.symbol)
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text([event.format.title, event.priceTitle].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(event.startsAt, format: .dateTime.day().month(.wide).hour().minute())
                    .font(.display(.subheadline, weight: .bold))
                Text([event.city.name, event.club?.name, event.location].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack { status; Spacer(minLength: 8); capacity }
                VStack(alignment: .leading, spacing: 6) { status; capacity }
            }
            if event.viewer.registration == "invited" {
                Label("Приглашение в пару", systemImage: "person.2.badge.plus").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
    private var status: some View {
        StatusPill(text: event.viewer.registration == "accepted" ? "Вы записаны" : event.status.title,
                   color: event.status == .cancelled ? Theme.negative : Theme.accent,
                   symbol: event.viewer.registration == "accepted" ? "checkmark" : nil)
    }
    private var capacity: some View {
        Text("\(event.registeredCount) / \(event.capacity) мест")
            .font(.footnote.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
    }
}
