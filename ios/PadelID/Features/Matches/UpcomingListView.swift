import SwiftUI

struct UpcomingListView: View {
    @Environment(AppModel.self) private var app
    @State private var mine = false
    @State private var items: [UpcomingMatch] = []
    @State private var nextOffset: Int?
    @State private var isLoading = false
    @State private var error: APIError?
    @State private var isCreating = false
    @State private var requestID = UUID()

    var body: some View {
        List {
            Section {
                Picker("Игры", selection: $mine) {
                    Text("Открытые").tag(false)
                    Text("Мои").tag(true)
                }.pickerStyle(.segmented).accessibilityIdentifier("upcoming.scope")
            }
            if let error { StaleDataBanner(error: error) }
            ForEach(items) { match in
                NavigationLink(value: Route.upcoming(match.id)) { UpcomingMatchRow(match: match) }
            }
            if items.isEmpty && !isLoading && error == nil {
                ContentUnavailableView(mine ? "Пока нет ваших игр" : "Открытых игр пока нет", systemImage: "tennis.racket",
                                       description: Text("Опубликуйте игру и пригласите игроков занять свободные места."))
            }
            if let nextOffset {
                Button("Ещё игры") { Task { await load(offset: nextOffset) } }.disabled(isLoading)
            }
            if isLoading { ProgressView() }
        }
        .navigationTitle("Предстоящие игры")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Создать игру", systemImage: "plus") { isCreating = true }
                    .disabled(!app.isOnline).accessibilityIdentifier("upcoming.create")
            }
        }
        .sheet(isPresented: $isCreating) { UpcomingCreateView() }
        .task(id: "\(mine).\(app.dataRevision)") { await load(offset: 0) }
        .refreshable { await load(offset: 0) }
    }

    private func load(offset: Int) async {
        let id = UUID()
        requestID = id
        isLoading = true
        let scope = mine ? "mine" : "open"
        let key = mine ? CacheKey.upcomingMine : CacheKey.upcomingOpen
        if offset == 0 {
            items = app.cache.value(UpcomingPage.self, for: key)?.items ?? []
            nextOffset = nil
        }
        defer { if requestID == id { isLoading = false } }
        do {
            let data = try await app.api.data(.get("v1/upcoming-matches", query: [
                URLQueryItem(name: "scope", value: scope), URLQueryItem(name: "offset", value: String(offset))]))
            guard requestID == id, !Task.isCancelled else { return }
            let page = try JSONCoding.decoder.decode(UpcomingPage.self, from: data)
            if offset == 0 { items = page.items; app.cache.store(data, for: key) }
            else { let ids = Set(items.map(\.id)); items += page.items.filter { !ids.contains($0.id) } }
            nextOffset = page.nextOffset
            error = nil
        } catch is CancellationError { }
        catch let failure as APIError { if requestID == id { error = failure } }
        catch { if requestID == id { self.error = APIError(kind: .decoding, code: "decoding", serverMessage: nil) } }
    }
}
