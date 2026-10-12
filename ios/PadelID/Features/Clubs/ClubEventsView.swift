import SwiftUI

/// Server filtering occurs before pagination, so a busy city's unrelated events
/// cannot make this club incorrectly appear empty.
struct ClubEventsView: View {
    let clubID: Int
    let name: String
    @Environment(AppModel.self) private var app
    @State private var kind: SportEventKind = .training
    @State private var events: [SportEvent] = []
    @State private var nextOffset: Int?
    @State private var working = false
    @State private var loaded = false
    @State private var failure: APIError?
    @State private var requestID = UUID()

    var body: some View {
        List {
            Section { Picker("События", selection: $kind) { ForEach(SportEventKind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented) }
            if let failure {
                Section {
                    Label(failure.message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Button("Повторить") { Task { await load(offset: 0) } }.disabled(working)
                }
            }
            ForEach(events) { event in
                NavigationLink(value: Route.event(event.id)) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(event.title).font(.headline)
                        Text(event.format.title).font(.subheadline).foregroundStyle(.secondary)
                        Text(event.startsAt, format: .dateTime.day().month(.wide).hour().minute())
                            .font(.subheadline.weight(.semibold))
                        Text("\(event.registeredCount) / \(event.capacity) мест").font(.caption).monospacedDigit()
                    }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 5)
                }.accessibilityIdentifier("club.event")
            }
            if working { ProgressView().frame(maxWidth: .infinity, minHeight: 80) }
            else if loaded && events.isEmpty && failure == nil {
                ContentUnavailableView("Событий пока нет", systemImage: kind.symbol,
                                       description: Text("Здесь появятся опубликованные \(kind == .training ? "тренировки" : "турниры") этого клуба."))
            }
            if let nextOffset { Button("Ещё события") { Task { await load(offset: nextOffset) } }.disabled(working) }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle(name).navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(offset: 0) }
        .task(id: "\(kind.rawValue).\(app.dataRevision)") { await load(offset: 0) }
    }

    private func load(offset: Int) async {
        let id = UUID(); requestID = id; working = true
        if offset == 0 { events = []; nextOffset = nil; loaded = false; failure = nil }
        defer { if requestID == id { working = false } }
        do {
            let page = try await app.api.send(.get("v1/clubs/\(clubID)/events", query: [
                URLQueryItem(name: "kind", value: kind.rawValue), URLQueryItem(name: "scope", value: "upcoming"),
                URLQueryItem(name: "limit", value: "30"), URLQueryItem(name: "offset", value: String(offset))
            ]), as: SportEventsPage.self)
            guard requestID == id, !Task.isCancelled else { return }
            let valid = page.items.filter { $0.club?.id == clubID }
            if offset == 0 { events = valid }
            else { let existing = Set(events.map(\.id)); events += valid.filter { !existing.contains($0.id) } }
            nextOffset = page.nextOffset; loaded = true; failure = nil
        } catch is CancellationError { }
        catch let error as APIError {
            guard requestID == id, !Task.isCancelled else { return }
            failure = error
            if error.status == 401 || error.status == 403 { events = []; nextOffset = nil }
        } catch {
            guard requestID == id, !Task.isCancelled else { return }
            failure = APIError(kind: .decoding, code: "decoding", serverMessage: nil)
        }
    }
}
