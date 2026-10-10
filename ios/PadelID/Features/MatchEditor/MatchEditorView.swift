import SwiftUI

/// Entering a new match or editing a pending one created by the current user.
/// Presented as a sheet by MainTabView (`app.matchEditor`).
struct MatchEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title3) private var pointsFieldWidth: CGFloat = 56

    @State private var model: MatchEditorModel
    @State private var pickingSlot: EditorSlot?
    @State private var editingSet: EditorSetTarget?
    @State private var isConfirmingDiscard = false
    @State private var successCount = 0
    @FocusState private var focusedField: EditorFocusField?

    private static let topAnchor = "editor.top"

    init(request: MatchEditorRequest) {
        _model = State(initialValue: MatchEditorModel(request: request))
    }

    private var meId: UUID? { app.me?.userId ?? model.editorId }
    private var meCard: PlayerCard? { app.me?.profile?.card ?? model.editorCard }
    private var cityId: Int? { app.me?.profile?.city?.id }

    private var canSubmit: Bool {
        model.canSubmit(meId: meId, isOnline: app.isOnline, now: .now)
    }

    var body: some View {
        let previewKey = model.previewKey(meId: meId)
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    statusSection
                    typeSection
                    lineupSection
                    scoreSection
                    whenSection
                    if let previewKey {
                        previewSection(for: previewKey)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.failureCount) {
                    withAnimation(reduceMotion ? nil : .smooth) {
                        proxy.scrollTo(Self.topAnchor, anchor: .top)
                    }
                    if let error = model.visibleError {
                        Announce.post(error.message)
                    }
                }
            }
            .navigationTitle(model.isEditing ? "Изменить матч" : model.upcomingMatch != nil ? "Внести результат" : "Новый матч")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(item: $pickingSlot) { slot in
                pickerSheet(for: slot)
            }
            .sheet(item: $editingSet) { target in
                scoreSheet(for: target)
            }
        }
        .alert(model.isEditing ? "Отменить изменения?" : "Отменить ввод матча?", isPresented: $isConfirmingDiscard) {
            Button(model.isEditing ? "Не сохранять" : "Отменить ввод", role: .destructive) { dismiss() }
            Button(model.isEditing ? "Продолжить редактирование" : "Продолжить ввод", role: .cancel) {}
        }
        .interactiveDismissDisabled(model.isDirty || model.isSubmitting)
        .task(id: previewKey) {
            await model.loadPreview(previewKey, app: app)
        }
        .onAppear {
            model.prepare(meId: meId)
        }
        .onChange(of: model.draft.superTiebreakTeam1) { _, value in
            let clean = EditorDraft.sanitizedPoints(value)
            if clean != value { model.draft.superTiebreakTeam1 = clean }
        }
        .onChange(of: model.draft.superTiebreakTeam2) { _, value in
            let clean = EditorDraft.sanitizedPoints(value)
            if clean != value { model.draft.superTiebreakTeam2 = clean }
        }
        .sensoryFeedback(.success, trigger: successCount)
        .sensoryFeedback(.error, trigger: model.failureCount)
        .sensoryFeedback(.selection, trigger: model.draft.lineupSignature)
        .sensoryFeedback(.selection, trigger: model.draft.matchType)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Отмена", action: cancel)
                .disabled(model.isSubmitting)

        }
        ToolbarItem(placement: .confirmationAction) {
            Button(action: submit) {
                if model.isSubmitting {
                    ProgressView()
                } else {
                    Text(model.isEditing ? "Сохранить" : "Отправить")
                }
            }
            .disabled(!canSubmit)
            .accessibilityLabel(model.isEditing ? "Сохранить" : "Отправить")
            .accessibilityIdentifier("editor.submit")
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Готово") { focusedField = nil }
        }
    }

    // MARK: Status

    @ViewBuilder
    private var statusSection: some View {
        let error = model.visibleError
        if error != nil || !app.isOnline || model.isEditing {
            Section {
                if let error {
                    Label {
                        Text(error.message)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.negative)
                    .id(Self.topAnchor)
                }
                if !app.isOnline {
                    Label(model.isEditing
                          ? "Нет подключения. Изменить матч можно только онлайн."
                          : "Нет подключения. Матч сохранится на устройстве и отправится, когда появится сеть.",
                          systemImage: "wifi.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if model.isEditing && !model.isLocked {
                    Label("После сохранения остальные игроки снова подтвердят результат.",
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Type

    private var typeSection: some View {
        Section {
            typePicker.disabled(model.isScheduledResult)
        } header: {
            Text("Тип матча")
        } footer: {
            Text("Рейтинговый матч изменит уровень всех четырёх игроков, когда каждый подтвердит результат. Товарищеский учитывается только в статистике.")
        }
    }

    @ViewBuilder
    private var typePicker: some View {
        let picker = Picker("Тип матча", selection: typeBinding) {
            Text("Рейтинговый").tag(MatchType.ranked)
            Text("Товарищеский").tag(MatchType.friendly)
        }
        if dynamicTypeSize.isAccessibilitySize {
            picker
                .pickerStyle(.menu)
                .accessibilityIdentifier("editor.type")
        } else {
            picker
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("editor.type")
        }
    }

    private var typeBinding: Binding<MatchType> {
        Binding(
            get: { model.draft.matchType },
            set: { value in
                model.setMatchType(value)
            })
    }

    // MARK: Line-up

    private var lineupSection: some View {
        Section {
            EditorCourtView(
                draft: model.draft,
                me: meCard,
                onSelect: { slot in pickingSlot = slot },
                onSwap: { team in
                    withAnimation(reduceMotion ? nil : .snappy) { model.swapSides(team: team) }
                })
                .listRowInsets(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
        } header: {
            Text("Состав")
        } footer: {
            Text(lineupFooter)
        }
    }

    private var lineupFooter: String {
        let draft = model.draft
        if draft.hasDeletedPlayer {
            return "Аккаунт одного из игроков удалён — выберите вместо него другого."
        }
        if !draft.isLineupComplete {
            return "Выберите партнёра и двух соперников, расставив их по сторонам корта, на которых они играли."
        }
        return "Каждый игрок получит запрос на подтверждение результата."
    }

    private func pickerSheet(for slot: EditorSlot) -> some View {
        var excluded = Set(model.draft.lineupIds)
        if model.isScheduledResult { excluded.removeAll() }
        if let meId { excluded.insert(meId) }
        return EditorPlayerPicker(
            title: slot.team == 1 ? "Партнёр" : "Соперник",
            current: model.draft.player(at: slot, me: meCard),
            excluded: excluded,
            allowedPlayers: model.allowedPlayers,
            onSelect: { card in model.setPlayer(card, at: slot) })
    }

    // MARK: Score

    private var scoreSection: some View {
        Section {
            Picker("Формат", selection: formatBinding) {
                ForEach(MatchFormat.allCases, id: \.self) { format in
                    Text(Narratives.format(format)).tag(format)
                }
            }
            .accessibilityIdentifier("editor.format")
            ForEach(0..<model.draft.expectedSetCount, id: \.self) { index in
                if model.draft.isSuperTiebreakRow(index) {
                    superTiebreakRow
                } else {
                    setRow(index)
                }
            }
        } header: {
            Text("Счёт")
        } footer: {
            scoreFooter
        }
    }

    private var formatBinding: Binding<MatchFormat> {
        Binding(
            get: { model.draft.format },
            set: { value in
                withAnimation(.smooth) { model.setFormat(value) }
            })
    }

    private func setRow(_ index: Int) -> some View {
        let score = model.draft.score(at: index)
        return Button {
            focusedField = nil
            editingSet = EditorSetTarget(index: index)
        } label: {
            HStack(spacing: 12) {
                Text("Сет \(index + 1)")
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                if let score {
                    Text(EditorScoreText.set(score))
                        .font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                } else {
                    Text("Указать счёт")
                        .foregroundStyle(Theme.accent)
                }
            }
            .contentShape(.rect)
        }
        .accessibilityLabel("Сет \(index + 1)")
        .accessibilityValue(score.map { EditorScoreText.spoken($0) } ?? "Счёт не указан")
        .accessibilityIdentifier("editor.set.\(index + 1)")
    }

    private var superTiebreakRow: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Text("Супертай-брейк")
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                pointsField($model.draft.superTiebreakTeam1, field: .superTiebreakTeam1,
                            label: "Супертай-брейк, очки вашей пары", identifier: "editor.stb.1")
                Text(verbatim: ":")
                    .font(.title3.weight(.semibold))
                    .accessibilityHidden(true)
                pointsField($model.draft.superTiebreakTeam2, field: .superTiebreakTeam2,
                            label: "Супертай-брейк, очки соперников", identifier: "editor.stb.2")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.set.3")
    }

    private func pointsField(_ text: Binding<String>, field: EditorFocusField, label: String,
                             identifier: String) -> some View {
        TextField("0", text: text)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
            .frame(width: pointsFieldWidth)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10, style: .continuous))
            .focused($focusedField, equals: field)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }

    private var scoreFooter: some View {
        let summary = scoreSummary
        return Text(summary.text)
            .foregroundStyle(summary.isError ? Theme.negative : Color.secondary)
    }

    private var scoreSummary: (text: String, isError: Bool) {
        let draft = model.draft
        if draft.expectedSetCount == 3, draft.isSuperTiebreakRow(2), let decider = draft.superTiebreakScore,
           !ScoreRules.isValidSuperTiebreak(decider.t1, decider.t2) {
            return ("Супертай-брейк играется до 10 очков, а после 9:9 — до разницы в 2 очка.", true)
        }
        if let issue = draft.scoreIssue {
            return (issue.message, true)
        }
        if let winner = draft.scoreWinner, let sets = draft.completeSets {
            let won = sets.filter { $0.t1 > $0.t2 }.count
            let lost = sets.count - won
            let text = winner == 1
                ? "Победа вашей пары — \(won):\(lost) по сетам."
                : "Победа соперников — \(won):\(lost) по сетам."
            return (text, false)
        }
        if draft.expectedSetCount == 3 && draft.isSuperTiebreakRow(2) && draft.superTiebreakScore == nil {
            return ("Решающий сет — супертай-брейк до 10 очков с разницей не меньше 2.", false)
        }
        return ("Счёт указывается с точки зрения вашей пары: сначала ваши геймы.", false)
    }

    private func scoreSheet(for target: EditorSetTarget) -> some View {
        EditorScoreGrid(setNumber: target.index + 1, initial: model.draft.regularSet(at: target.index)) { set in
            model.setScore(set, at: target.index)
        }
    }

    // MARK: When and where

    private var whenSection: some View {
        Section {
            DatePicker("Дата и время", selection: $model.draft.playedAt, in: dateRange,
                       displayedComponents: [.date, .hourAndMinute])
                .environment(\.locale, Format.locale)
                .accessibilityIdentifier("editor.date")
            if let cityId {
                NavigationLink {
                    ClubPickerView(cityId: cityId, selection: $model.draft.club)
                } label: {
                    LabeledContent("Клуб", value: model.draft.club?.name ?? "Не указан")
                }
                .accessibilityIdentifier("editor.club")
                .disabled(model.isScheduledResult)
            }
        } header: {
            Text("Когда и где")
        } footer: {
            dateFooter
        }
    }

    /// Ranked: the last 14 days, friendly: 90, never in the future. When
    /// editing, the stored date stays selectable even if it is out of range
    /// (the footer explains what to change).
    private var dateRange: ClosedRange<Date> {
        let now = Date.now
        var lower = model.draft.earliestSelectableDate(now: now)
        var upper = now
        if model.isEditing {
            lower = min(lower, model.initial.playedAt)
            upper = max(upper, model.initial.playedAt)
        }
        if let start = model.scheduledStartsAt { lower = min(upper, max(lower, start)) }
        return lower...upper
    }

    private var dateFooter: some View {
        let now = Date.now
        let draft = model.draft
        let ranked = draft.matchType == .ranked
        let text: String
        let isError: Bool
        if draft.playedAt > now.addingTimeInterval(3_600) {
            text = "Дата матча не может быть в будущем."
            isError = true
        } else if !draft.isPlayedAtValid(now: now) {
            text = ranked
                ? "Рейтинговый матч можно внести только в течение 14 дней после игры. Выберите другую дату или товарищеский тип."
                : "Товарищеский матч можно внести только в течение 90 дней после игры."
            isError = true
        } else {
            text = ranked
                ? "Рейтинговый матч можно внести в течение 14 дней после игры."
                : "Товарищеский матч можно внести в течение 90 дней после игры."
            isError = false
        }
        return Text(text)
            .foregroundStyle(isError ? Theme.negative : Color.secondary)
    }

    // MARK: Forecast

    @ViewBuilder
    private func previewSection(for key: EditorPreviewKey) -> some View {
        let isStale = model.previewSource != key.body
        Section {
            if let preview = model.preview {
                LabeledContent("Шансы вашей пары на победу") {
                    Text(Format.percent(preview.expectedWinTeam1))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                .opacity(isStale ? 0.5 : 1)
                if let mine = model.myPreview(meId: meId) {
                    myForecastRow(mine)
                        .opacity(isStale ? 0.5 : 1)
                }
            } else if model.previewFailed {
                Button {
                    model.retryPreview()
                } label: {
                    Label("Обновить прогноз", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                }
                .accessibilityIdentifier("editor.preview.retry")
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Рассчитываем прогноз…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Прогноз")
        } footer: {
            if let preview = model.preview, preview.weight < 0.999 {
                Text("Тот же состав играл недавно — матч учтётся с весом \(Format.percent(preview.weight)).")
            }
        }
    }

    private func myForecastRow(_ mine: PreviewPlayer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ваш уровень")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Победа: \(deltaText(mine.ifTeam1Wins)) · Поражение: \(deltaText(mine.ifTeam2Wins))")
                .font(.body.weight(.medium))
            if let entered = mine.withEnteredScore {
                Text("С введённым счётом: \(deltaText(entered))")
                    .font(.body.weight(.medium))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(forecastAccessibility(mine))
    }

    private func deltaText(_ value: Double) -> Text {
        Text(Format.delta(value))
            .monospacedDigit()
            .foregroundStyle(Theme.deltaColor(value))
    }

    private func forecastAccessibility(_ mine: PreviewPlayer) -> String {
        var text = "Ваш уровень: при победе \(Format.delta(mine.ifTeam1Wins)), при поражении \(Format.delta(mine.ifTeam2Wins))"
        if let entered = mine.withEnteredScore {
            text += ", с введённым счётом \(Format.delta(entered))"
        }
        return text
    }

    // MARK: Actions

    private func cancel() {
        if model.isDirty {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func submit() {
        guard let meId, canSubmit else { return }
        focusedField = nil
        Task {
            let outcome = await model.submit(app: app, meId: meId)
            switch outcome {
            case .saved, .queued:
                successCount += 1
                dismiss()
            case .failed:
                break
            }
        }
    }
}
