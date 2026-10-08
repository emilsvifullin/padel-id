import SwiftUI

/// Administration: review of coach applications by status.
struct CoachReviewView: View {
    @Environment(AppModel.self) private var app
    @State private var status: CoachStatus = .pending
    @State private var lists: [CoachStatus: [CoachApplication]] = [:]
    @State private var errors: [CoachStatus: APIError] = [:]
    @State private var review: AdminReviewRequest?
    @State private var successCount = 0

    var body: some View {
        List {
            Section {
                AdminReviewStatusPicker(selection: $status)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            content
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Заявки тренеров")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: status) { await load(status) }
        .refreshable { await load(status) }
        .sheet(item: $review) { request in
            AdminReviewDecisionSheet(request: request) { updated in
                completed(updated)
            }
        }
        .sensoryFeedback(.selection, trigger: status)
        .sensoryFeedback(.success, trigger: successCount)
    }

    @ViewBuilder
    private var content: some View {
        if let items = lists[status] {
            if let error = errors[status] {
                Section {
                    StaleDataBanner(error: error)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            if items.isEmpty {
                Section {
                    ContentUnavailableView(AdminReviewCopy.emptyTitle(status),
                                           systemImage: "tray",
                                           description: Text(AdminReviewCopy.emptyDescription(status)))
                }
            } else {
                ForEach(items, id: \.player.id) { application in
                    Section {
                        AdminReviewApplicationRow(application: application) { action in
                            review = AdminReviewRequest(application: application, action: action)
                        }
                    }
                }
            }
        } else if let error = errors[status] {
            Section {
                ErrorStateView(error: error) {
                    Task { await load(status) }
                }
            }
        } else {
            Section {
                LoadingView()
            }
        }
    }

    private func load(_ requested: CoachStatus) async {
        do {
            let items = try await app.api.send(
                .get("v1/admin/coach-applications", query: [URLQueryItem(name: "status", value: requested.rawValue)]),
                as: [CoachApplication].self)
            lists[requested] = items
            errors[requested] = nil
        } catch is CancellationError {
            return
        } catch let error as APIError {
            errors[requested] = error
        } catch {
            errors[requested] = APIError(kind: .decoding, code: "decoding", serverMessage: nil)
        }
    }

    private func completed(_ updated: CoachApplication) {
        successCount += 1
        for key in Array(lists.keys) {
            lists[key]?.removeAll { $0.player.id == updated.player.id }
        }
        if updated.player.id == app.me?.userId {
            Task { await app.refreshMe() }
        }
        app.dataDidChange()
        Task { await load(status) }
    }
}

// MARK: - Status filter

private struct AdminReviewStatusPicker: View {
    @Binding var selection: CoachStatus

    var body: some View {
        ViewThatFits(in: .horizontal) {
            picker
                .pickerStyle(.segmented)
            picker
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var picker: some View {
        Picker("Статус заявок", selection: $selection) {
            ForEach(AdminReviewCopy.filters, id: \.self) { status in
                Text(AdminReviewCopy.filterTitle(status)).tag(status)
            }
        }
    }
}

// MARK: - Row

private struct AdminReviewApplicationRow: View {
    let application: CoachApplication
    let onAction: (AdminReviewAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlayerRow(card: application.player) {
                LevelChip(level: application.player.level, reliability: application.player.reliability)
            }
            VStack(alignment: .leading, spacing: 4) {
                fact("Тренерский стаж", Format.count(application.experienceYears, "год", "года", "лет"))
                if let certification = application.certification, !certification.isEmpty {
                    fact("Сертификация", certification)
                }
                if let club = application.club {
                    fact("Клуб", club.name)
                }
            }
            Text(application.about)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Подана \(Format.date(application.submittedAt))")
                if let reviewedAt = application.reviewedAt {
                    Text("Решение \(Format.date(reviewedAt))")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            if let note = application.reviewNote, !note.isEmpty {
                Text("Комментарий: \(note)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(.vertical, 6)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        Text("\(title): \(value)")
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var actions: some View {
        switch application.status {
        case .pending:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    approveButton
                    rejectButton
                }
                VStack(spacing: 10) {
                    approveButton
                    rejectButton
                }
            }
            .controlSize(.large)
        case .approved:
            actionButton("Отозвать статус", role: .destructive, prominent: false, action: .revoke)
                .controlSize(.large)
        case .rejected, .revoked:
            EmptyView()
        }
    }

    private var approveButton: some View {
        actionButton("Подтвердить", role: nil, prominent: true, action: .approve)
    }

    private var rejectButton: some View {
        actionButton("Отклонить", role: .destructive, prominent: false, action: .reject)
    }

    @ViewBuilder
    private func actionButton(_ title: String, role: ButtonRole?, prominent: Bool, action: AdminReviewAction) -> some View {
        let button = Button(role: role) {
            onAction(action)
        } label: {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

// MARK: - Decision sheet

private struct AdminReviewDecisionSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: AdminReviewRequest
    let onCompleted: (CoachApplication) -> Void

    @State private var note = ""
    @State private var isSubmitting = false
    @State private var error: APIError?
    @State private var failureCount = 0

    var body: some View {
        NavigationStack {
            Form {
                if !app.isOnline {
                    Section {
                        SettingsOfflineNotice(message: "Нет подключения к интернету. Решение можно отправить только онлайн.")
                    }
                }
                Section {
                    PlayerRow(card: request.application.player)
                    Text(AdminReviewCopy.consequence(request.action))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    TextField("Необязательно", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Комментарий для игрока")
                } footer: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Игрок увидит его на экране заявки.")
                        Spacer(minLength: 8)
                        SettingsCharacterCount(count: SettingsText.length(note), limit: AdminReviewCopy.noteLimit)
                    }
                }
                if let error {
                    Section {
                        SettingsErrorRow(message: error.message)
                    }
                }
            }
            .disabled(isSubmitting)
            .navigationTitle(AdminReviewCopy.title(request.action))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button(AdminReviewCopy.actionTitle(request.action),
                               role: request.action == .approve ? nil : .destructive,
                               action: submit)
                            .disabled(!canSubmit)
                    }
                }
            }
            .interactiveDismissDisabled(isSubmitting)
            .sensoryFeedback(.error, trigger: failureCount)
        }
        .presentationDetents([.medium, .large])
    }

    private var canSubmit: Bool {
        SettingsText.length(note) <= AdminReviewCopy.noteLimit && app.isOnline && !isSubmitting
    }

    private func submit() {
        guard canSubmit else { return }
        let trimmed = SettingsText.trimmed(note)
        let body = AdminReviewBody(decision: request.action.rawValue, note: trimmed.isEmpty ? nil : trimmed)
        let path = "v1/admin/coach-applications/\(request.application.player.id.uuidString.lowercased())"
        isSubmitting = true
        error = nil
        Task {
            defer { isSubmitting = false }
            do {
                let updated = try await app.api.send(.json(.post, path, body), as: CoachApplication.self)
                onCompleted(updated)
                dismiss()
            } catch is CancellationError {
                return
            } catch let apiError as APIError {
                error = apiError
                failureCount += 1
            } catch {
                self.error = APIError(kind: .decoding, code: "decoding", serverMessage: nil)
                failureCount += 1
            }
        }
    }
}

// MARK: - Data and copy

private nonisolated enum AdminReviewAction: String, Hashable, Sendable {
    case approve = "approved"
    case reject = "rejected"
    case revoke = "revoked"
}

private nonisolated struct AdminReviewRequest: Identifiable, Hashable, Sendable {
    let application: CoachApplication
    let action: AdminReviewAction

    var id: String { application.player.id.uuidString + "." + action.rawValue }
}

private nonisolated struct AdminReviewBody: Encodable, Sendable {
    let decision: String
    let note: String?
}

private nonisolated enum AdminReviewCopy {
    static let noteLimit = 300
    static let filters: [CoachStatus] = [.pending, .approved, .rejected, .revoked]

    static func filterTitle(_ status: CoachStatus) -> String {
        switch status {
        case .pending: "Заявки"
        case .approved: "Подтверждённые"
        case .rejected: "Отклонённые"
        case .revoked: "Отозванные"
        }
    }

    static func emptyTitle(_ status: CoachStatus) -> String {
        switch status {
        case .pending: "Новых заявок нет"
        case .approved: "Нет подтверждённых тренеров"
        case .rejected: "Нет отклонённых заявок"
        case .revoked: "Нет отозванных статусов"
        }
    }

    static func emptyDescription(_ status: CoachStatus) -> String {
        switch status {
        case .pending: "Заявки игроков на статус тренера появятся здесь."
        case .approved: "Здесь будут тренеры, чьи заявки вы подтвердили."
        case .rejected: "Здесь будут заявки, которые вы отклонили."
        case .revoked: "Здесь будут тренеры, у которых отозван статус."
        }
    }

    static func title(_ action: AdminReviewAction) -> String {
        switch action {
        case .approve: "Подтвердить тренера"
        case .reject: "Отклонить заявку"
        case .revoke: "Отозвать статус"
        }
    }

    static func actionTitle(_ action: AdminReviewAction) -> String {
        switch action {
        case .approve: "Подтвердить"
        case .reject: "Отклонить"
        case .revoke: "Отозвать"
        }
    }

    static func consequence(_ action: AdminReviewAction) -> String {
        switch action {
        case .approve:
            "Игрок получит статус тренера и сможет оценивать навыки других игроков в их Padel DNA."
        case .reject:
            "Игрок увидит, что заявка отклонена, и сможет отправить её повторно."
        case .revoke:
            "Игрок потеряет статус тренера, его оценки перестанут учитываться в Padel DNA игроков. Подать заявку снова будет нельзя."
        }
    }
}
