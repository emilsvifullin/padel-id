import SwiftUI

struct ClubCourtEditor: View {
    let clubID: Int
    let court: ClubCourt?
    let saved: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var courtID: UUID
    @State private var version: Int
    @State private var name: String
    @State private var indoor: Bool
    @State private var surface: String
    @State private var description: String
    @State private var active: Bool
    @State private var reason = ""
    @State private var working = false
    @State private var failure: APIError?
    @State private var conflict = false
    @State private var permissionRevoked = false
    @State private var existingNames: [String] = []

    init(clubID: Int, court: ClubCourt?, saved: @escaping () -> Void) {
        self.clubID = clubID; self.court = court; self.saved = saved
        _courtID = State(initialValue: court?.id ?? UUID())
        _version = State(initialValue: court?.version ?? 0)
        _name = State(initialValue: court?.name ?? "")
        _indoor = State(initialValue: court?.indoor ?? true)
        _surface = State(initialValue: court?.surface ?? "")
        _description = State(initialValue: court?.description ?? "")
        _active = State(initialValue: court?.isActive ?? true)
    }

    var body: some View {
        SheetNavigationStack {
            Form {
                Section("Корт") {
                    TextField("Название", text: $name)
                    Toggle("Крытый корт", isOn: $indoor)
                    TextField("Покрытие", text: $surface)
                    TextField("Описание", text: $description, axis: .vertical).lineLimit(3...6)
                    Toggle("Показывать в каталоге", isOn: $active)
                }
                if !existingNames.isEmpty {
                    Section("Опубликованные корты клуба") { ForEach(existingNames, id: \.self) { Text($0) } }
                }
                Section("Основание изменения") { TextField("Источник проверенных сведений", text: $reason, axis: .vertical).lineLimit(2...5) }
                if let failure {
                    Section {
                        Label(failure.message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.negative)
                        if conflict {
                            Text("Корт изменён другим администратором. Загрузите его текущие сведения и проверьте их.")
                            Button("Загрузить текущие сведения") { Task { await reload() } }
                        }
                    }
                }
            }
            .disabled(working).scrollContentBackground(.hidden).background(Theme.canvas)
            .navigationTitle(court == nil ? "Добавить корт" : "Изменить корт").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(working) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { Task { await save() } }
                        .disabled(!valid || working || conflict || permissionRevoked || !app.isOnline || app.me?.isAdmin != true)
                }
            }.interactiveDismissDisabled(working)
        }
    }

    private var valid: Bool {
        (2...80).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count)
        && surface.count <= 80 && description.count <= 600
        && (5...400).contains(reason.trimmingCharacters(in: .whitespacesAndNewlines).count)
    }
    private func save() async {
        guard valid, !working, !conflict, !permissionRevoked, app.me?.isAdmin == true else { return }
        working = true; failure = nil
        defer { working = false }
        let body = ClubCourtBody(version: version, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                 indoor: indoor, surface: surface.trimmingCharacters(in: .whitespacesAndNewlines),
                                 description: description.trimmingCharacters(in: .whitespacesAndNewlines), isActive: active,
                                 reason: reason.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            _ = try await app.api.send(.json(.put, "v1/admin/clubs/\(clubID)/courts/\(courtID)", body), as: ClubCourt.self)
            app.dataDidChange(); saved(); dismiss()
        } catch let error as APIError { failure = error; conflict = error.status == 409; permissionRevoked = error.status == 401 || error.status == 403 }
        catch { failure = APIError(kind: .decoding, code: "decoding", serverMessage: nil) }
    }
    private func reload() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            let club = try await app.api.send(.get("v1/clubs/\(clubID)"), as: ClubCatalogEntry.self)
            guard club.viewer?.canEdit == true else {
                failure = APIError(kind: .server(status: 403), code: "forbidden", serverMessage: nil)
                permissionRevoked = true
                return
            }
            guard let value = club.courts?.first(where: { $0.id == courtID }) else {
                // A new UUID can conflict with an existing court name. The
                // authorized reread lets the administrator choose another name
                // without pretending that the new court was created.
                if version == 0 {
                    existingNames = (club.courts ?? []).map(\.name)
                    name = ""; reason = ""; conflict = false; failure = nil
                    saved()
                }
                return
            }
            version = value.version; name = value.name; indoor = value.indoor; surface = value.surface
            description = value.description; active = value.isActive; reason = ""; conflict = false; failure = nil
            saved()
        } catch let error as APIError { failure = error }
        catch { failure = APIError(kind: .decoding, code: "decoding", serverMessage: nil) }
    }
}
