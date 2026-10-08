import SwiftUI

/// Full match card: scoreboard, confirmations, rating impact, analysis and the
/// participant's actions (confirm, dispute, edit, cancel, feedback).
struct MatchDetailView: View {
    let matchId: UUID

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var detail: Resource<MatchDetail>
    @State private var isWorking = false
    @State private var isDisputePresented = false
    @State private var isFeedbackPresented = false
    @State private var isCancelConfirmationPresented = false
    @State private var sheetResult: MatchActionResult?
    @State private var actionAlert: MatchDetailAlert?
    @State private var successFeedback = 0
    @State private var warningFeedback = 0

    init(matchId: UUID) {
        self.matchId = matchId
        _detail = State(initialValue: Resource<MatchDetail>(cacheKey: CacheKey.match(matchId)) {
            Endpoint.get("v1/matches/\(matchId.uuidString.lowercased())")
        })
    }

    var body: some View {
        Group {
            if let match = detail.value {
                content(match)
            } else if let error = detail.error {
                ErrorStateView(error: error) {
                    Task { await detail.load(using: app) }
                }
            } else {
                LoadingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Матч")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .safeAreaBar(edge: .bottom) {
            if let match = detail.value {
                actionBar(match)
            }
        }
        .task(id: app.dataRevision) {
            await detail.load(using: app)
        }
        .sheet(isPresented: $isDisputePresented, onDismiss: {
            finishSheet(haptic: .warning, done: "Возражение отправлено",
                        queued: "Ответ отправится при подключении")
        }) {
            if let match = detail.value {
                MatchDisputeSheet(match: match) { result in
                    sheetResult = result
                }
            }
        }
        .sheet(isPresented: $isFeedbackPresented, onDismiss: {
            finishSheet(haptic: .success, done: "Отметки сохранены",
                        queued: "Отметки отправятся при подключении")
        }) {
            if let match = detail.value {
                MatchFeedbackSheet(match: match, viewerId: app.me?.userId) { result in
                    sheetResult = result
                }
            }
        }
        .confirmationDialog("Отменить матч?", isPresented: $isCancelConfirmationPresented, titleVisibility: .visible) {
            Button("Отменить матч", role: .destructive) {
                Task { await cancelMatch() }
            }
            Button("Не отменять", role: .cancel) {}
        } message: {
            Text("Матч исчезнет у всех участников и не будет учтён. Восстановить его не получится.")
        }
        .alert(actionAlert?.title ?? "", isPresented: alertBinding, presenting: actionAlert) { _ in
            Button("Понятно", role: .cancel) {}
        } message: { item in
            Text(item.message)
        }
        .sensoryFeedback(.success, trigger: successFeedback)
        .sensoryFeedback(.warning, trigger: warningFeedback)
    }

    // MARK: - Content

    private func content(_ match: MatchDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                if detail.isStale, let error = detail.error {
                    StaleDataBanner(error: error)
                }
                MatchDetailScoreboard(match: match, viewerId: viewerId)
                if match.status != .confirmed {
                    MatchDetailStatusSection(match: match, viewerId: viewerId,
                                             failedAnswer: MatchActions.failedAnswer(for: match.id, app: app),
                                             isOnline: app.isOnline)
                }
                if let projection = projection(match) {
                    MatchDetailProjectionSection(projection: projection)
                }
                if match.ratingApplied {
                    MatchDetailRatingSection(match: match, viewerId: viewerId)
                }
                if match.viewer.canGiveFeedback {
                    feedbackSection(match)
                }
                MatchDetailAnalysisSection(match: match)
                MatchDetailMetaSection(match: match)
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable {
            await detail.load(using: app)
        }
    }

    private var viewerId: UUID? { app.me?.userId }

    private func projection(_ match: MatchDetail) -> ProjectedChange? {
        guard match.matchType == .ranked, !match.ratingApplied,
              match.status == .pending || match.status == .disputed else { return nil }
        return match.analysis.projectedChange
    }

    // MARK: - Feedback

    private func feedbackSection(_ match: MatchDetail) -> some View {
        let given = (match.viewer.feedback ?? []).filter { !$0.strengths.isEmpty || !$0.improvements.isEmpty }.count
        let isQueued = app.outbox.operations.contains {
            $0.kind == .submitFeedback && $0.matchId == match.id && $0.failure == nil
        }
        return MatchDetailSection("Отметки игрокам", footer: feedbackFooter(match)) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Отметьте сильные стороны и зоны роста партнёра и соперников — так их Padel DNA станет точнее.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if given > 0 {
                    Label("Отмечено: \(Format.count(given, "игрок", "игрока", "игроков"))", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.positive)
                }
                if isQueued {
                    Label("Отметки отправятся при подключении", systemImage: "icloud.and.arrow.up")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button {
                    isFeedbackPresented = true
                } label: {
                    Text(given > 0 ? "Изменить отметки" : "Отметить игроков")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("match.feedback")
            }
        }
    }

    private func feedbackFooter(_ match: MatchDetail) -> String? {
        guard let confirmedAt = match.confirmedAt else { return nil }
        let deadline = confirmedAt.addingTimeInterval(14 * 24 * 60 * 60)
        return "Отметки можно изменить до \(Format.date(deadline))."
    }

    // MARK: - Actions bar

    @ViewBuilder
    private func actionBar(_ match: MatchDetail) -> some View {
        if MatchActions.hasQueuedAnswer(for: match.id, app: app) {
            GlassEffectContainer {
                Label("Ответ отправится при подключении", systemImage: "icloud.and.arrow.up")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .glassEffect()
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.bottom, 8)
        } else if match.viewer.canConfirm || match.viewer.canDispute {
            GlassEffectContainer {
                // Equal halves side by side only while both titles fit on
                // one line in a half; otherwise (large text) one above the other.
                ViewThatFits(in: .horizontal) {
                    EqualWidthHStack(spacing: 12) {
                        answerButtons(match)
                    }
                    VStack(spacing: 10) {
                        answerButtons(match)
                    }
                }
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.bottom, 8)
        } else if match.viewer.canEdit && match.status == .disputed {
            GlassEffectContainer {
                Button {
                    edit(match)
                } label: {
                    Text("Исправить матч")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!app.isOnline)
                .accessibilityIdentifier("match.fix")
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func answerButtons(_ match: MatchDetail) -> some View {
        if match.viewer.canDispute {
            Button {
                isDisputePresented = true
            } label: {
                Text("Оспорить")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(isWorking)
            .accessibilityIdentifier("match.dispute")
        }
        if match.viewer.canConfirm {
            Button {
                Task { await confirm() }
            } label: {
                ZStack {
                    Text("Подтвердить")
                        .opacity(isWorking ? 0 : 1)
                    if isWorking {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(isWorking)
            .accessibilityIdentifier("match.confirm")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let match = detail.value, match.viewer.canEdit || match.viewer.canCancel {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        if match.viewer.canEdit {
                            Button {
                                edit(match)
                            } label: {
                                Label("Изменить", systemImage: "pencil")
                            }
                            .accessibilityIdentifier("match.edit")
                        }
                        if match.viewer.canCancel {
                            Button(role: .destructive) {
                                isCancelConfirmationPresented = true
                            } label: {
                                Label("Отменить матч", systemImage: "xmark.circle")
                            }
                            .accessibilityIdentifier("match.cancel")
                        }
                    } header: {
                        if !app.isOnline {
                            Text("Нужно подключение к интернету")
                        }
                    }
                    .disabled(!app.isOnline || isWorking)
                } label: {
                    Label("Действия с матчем", systemImage: "ellipsis")
                }
                .accessibilityIdentifier("match.more")
            }
        }
    }

    // MARK: - Mutations

    private func edit(_ match: MatchDetail) {
        guard app.isOnline else {
            actionAlert = MatchDetailAlert(title: "Нет подключения",
                                     message: "Изменить матч можно только при подключении к интернету.")
            return
        }
        app.matchEditor = MatchEditorRequest(mode: .edit(match))
    }

    private func confirm() async {
        guard let match = detail.value, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let result = await MatchActions.confirm(match, app: app)
        await apply(result, haptic: .success, done: "Результат подтверждён",
                    queued: "Ответ отправится при подключении")
    }

    private func cancelMatch() async {
        guard let match = detail.value, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let result = await MatchActions.cancel(match, app: app)
        if case .updated(let updated, _) = result {
            detail.replace(with: updated)
            successFeedback += 1
            Announce.post("Матч отменён")
            dismiss()
        } else {
            await apply(result, haptic: .success, done: "Матч отменён", queued: "")
        }
    }

    private func finishSheet(haptic: MatchDetailHaptic, done: String, queued: String) {
        guard let result = sheetResult else { return }
        sheetResult = nil
        Task { await apply(result, haptic: haptic, done: done, queued: queued) }
    }

    /// Shows the outcome of an action; `done` and `queued` are spoken to
    /// VoiceOver, whose focus was on a control that is gone now.
    private func apply(_ result: MatchActionResult, haptic: MatchDetailHaptic, done: String, queued: String) async {
        switch result {
        case .updated(let updated, _):
            detail.replace(with: updated)
            switch haptic {
            case .success: successFeedback += 1
            case .warning: warningFeedback += 1
            }
            Announce.post(done)
        case .queued:
            if !queued.isEmpty {
                Announce.post(queued)
            }
        case .conflict(let error):
            await detail.load(using: app)
            actionAlert = MatchDetailAlert(title: "Матч изменился", message: error.message)
        case .failed(let error):
            actionAlert = MatchDetailAlert(title: error.isNetwork ? "Нет подключения" : "Не получилось", message: error.message)
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { actionAlert != nil },
            set: { if !$0 { actionAlert = nil } }
        )
    }
}

private struct MatchDetailAlert {
    let title: String
    let message: String
}

private enum MatchDetailHaptic {
    case success, warning
}
