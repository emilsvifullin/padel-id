import SwiftUI

/// Padel DNA of any player: the hexagon, the style archetype and every
/// dimension with its level, confidence and evidence. The current user can
/// update the self-assessment from here.
struct DNADetailView: View {
    let playerId: UUID
    @Environment(AppModel.self) private var app
    @State private var dna: Resource<PadelDNA>
    @State private var isEditingSelfAssessment = false
    @State private var savedCount = 0

    init(playerId: UUID) {
        self.playerId = playerId
        let path = "v1/players/\(playerId.uuidString.lowercased())/dna"
        _dna = State(initialValue: Resource<PadelDNA>(cacheKey: CacheKey.dna(playerId)) { .get(path) })
    }

    var body: some View {
        ZStack {
            if let value = dna.value {
                content(value)
            } else if let error = dna.error {
                ErrorStateView(error: error) {
                    Task { await dna.load(using: app) }
                }
            } else {
                LoadingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Padel DNA")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isMe {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Самооценка") {
                        isEditingSelfAssessment = true
                    }
                    .accessibilityHint("Изменить самооценку по направлениям игры")
                }
            }
        }
        .sheet(isPresented: $isEditingSelfAssessment) {
            DNADetailSelfAssessmentSheet(initial: initialSelfAssessment) { updated in
                applySaved(updated)
            }
        }
        .sensoryFeedback(.success, trigger: savedCount)
        .task(id: app.dataRevision) { await dna.load(using: app) }
    }

    private var isMe: Bool { app.me?.userId == playerId }

    /// The stored self-assessment (keys arrive camelCase after key conversion).
    private var initialSelfAssessment: [DNADimension: Int] {
        var values: [DNADimension: Int] = [:]
        for dimension in DNADimension.allCases {
            values[dimension] = 0
        }
        for (key, value) in app.me?.dnaSelf ?? [:] {
            if let dimension = DNADimension(apiKey: key) {
                values[dimension] = min(2, max(-2, value))
            }
        }
        return values
    }

    private func applySaved(_ updated: PadelDNA) {
        var merged = updated
        if let current = dna.value {
            if merged.history == nil { merged.history = current.history }
            if merged.rating == nil { merged.rating = current.rating }
        }
        dna.replace(with: merged)
        savedCount += 1
        app.dataDidChange()
        Task { await app.refreshMe() }
    }

    @ViewBuilder
    private func content(_ value: PadelDNA) -> some View {
        if value.dimensions.isEmpty {
            ContentUnavailableView {
                Label("Padel DNA формируется", systemImage: "hexagon")
            } description: {
                Text(DNAArchetype.forming.summary)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if dna.isStale, let error = dna.error {
                        StaleDataBanner(error: error)
                    }
                    DNADetailHero(dna: value)
                    ForEach(DNADimension.allCases) { dimension in
                        if let state = value.dimensions.first(where: { $0.dimension == dimension }) {
                            DNADetailDimensionCard(dimension: dimension, state: state)
                        }
                    }
                    DNADetailFooter()
                }
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .refreshable { [dna = self.dna, app = self.app] in
                await dna.load(using: app)
            }
        }
    }
}

// MARK: - Hero

private struct DNADetailHero: View {
    let dna: PadelDNA
    @State private var presentation: DNADetailPresentation = .chart

    var body: some View {
        SectionContainer(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Вид Padel DNA", selection: $presentation) {
                    Text("Диаграмма").tag(DNADetailPresentation.chart)
                    Text("Показатели").tag(DNADetailPresentation.values)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("dna.presentation")
                if presentation == .chart {
                    DNAHexagon(dimensions: dna.dimensions)
                        .frame(maxWidth: 320)
                        .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(DNADimension.allCases) { dimension in
                            if let state = dna.dimensions.first(where: { $0.dimension == dimension }) {
                                DNADetailLevelBar(dimension: dimension, state: state)
                            }
                        }
                    }
                    .accessibilityIdentifier("dna.values")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(archetype.title)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(archetype.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let mu = dna.rating?.mu {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Общий уровень")
                            .font(.subheadline)
                        Spacer(minLength: 8)
                        Text(Format.level(mu))
                            .font(.headline)
                            .fontDesign(.rounded)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(presentation == .chart
                     ? "Пунктир на диаграмме — общий уровень, вершины показывают направления выше или ниже него. Закрашенные точки — направления, по которым уже достаточно данных."
                     : "Уровень по шкале 0–7. Это тот же Padel DNA, что на диаграмме: оценка направления относительно общего уровня, а не отдельное измерение навыка. Достоверность и источники — ниже.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var archetype: DNAArchetype { DNAArchetype(rawValue: dna.archetype) ?? .forming }
}

private nonisolated enum DNADetailPresentation: Hashable, Sendable {
    case chart, values
}

private struct DNADetailLevelBar: View {
    let dimension: DNADimension
    let state: DNADimensionState

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(dimension.title)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(Format.level(state.level))
                    .font(.headline)
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .fixedSize()
            }
            ProgressView(value: min(7, max(0, state.level)), total: 7)
                .tint(Theme.accent)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dimension.title)
        .accessibilityValue("Уровень \(Format.level(state.level)) из 7; \(Confidence(state.confidence).title)")
    }
}

// MARK: - Dimension

private struct DNADetailDimensionCard: View {
    let dimension: DNADimension
    let state: DNADimensionState

    var body: some View {
        SectionContainer {
            VStack(alignment: .leading, spacing: 12) {
                header
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        DeltaText(delta: state.offset)
                        Text("к общему уровню")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(offsetDescription)
                    if let trend = state.trend30d {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            DeltaText(delta: trend)
                            Text("за 30 дней")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                confidence
                Text(sources)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let verifiedAt = state.coachVerifiedAt {
                    Label("Подтверждено тренером · \(Format.date(verifiedAt))", systemImage: "checkmark.seal.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
                Text(dimension.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: dimension.symbol)
                .font(.headline)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(dimension.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(Format.level(state.level))
                .font(.title3.weight(.semibold))
                .fontDesign(.rounded)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var confidence: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Confidence(state.confidence).title)
                .font(.subheadline)
            ProgressView(value: min(1, max(0, state.confidence)))
                .tint(Theme.accent)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Достоверность")
        .accessibilityValue("\(Confidence(state.confidence).title), \(Format.percent(min(1, max(0, state.confidence))))")
    }

    private var offsetDescription: String {
        let magnitude = Format.level(abs(state.offset))
        if state.offset >= 0.005 { return "На \(magnitude) выше общего уровня" }
        if state.offset <= -0.005 { return "На \(magnitude) ниже общего уровня" }
        return "На уровне общего рейтинга"
    }

    private var sources: String {
        var parts: [String] = []
        if state.peerSignals > 0 {
            parts.append(Format.count(state.peerSignals, "оценка", "оценки", "оценок") + " партнёров и соперников")
        }
        if state.coachSignals > 0 {
            parts.append(Format.count(state.coachSignals, "оценка тренера", "оценки тренеров", "оценок тренеров"))
        }
        if state.selfSignal {
            parts.append("самооценка")
        }
        if state.matchSignal {
            parts.append("результаты упорных сетов")
        }
        guard !parts.isEmpty else { return "Данных по этому направлению пока нет." }
        return "Источники: " + parts.joined(separator: ", ")
    }
}

// MARK: - Footer

private struct DNADetailFooter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Как формируется Padel DNA")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Padel DNA описывает стиль игры: какие элементы сильнее или слабее общего уровня. Среднее шести направлений равно рейтингу игрока. Профиль складывается из самооценки, отметок партнёров и соперников после подтверждённых матчей, оценок тренеров и результатов упорных сетов. Оценки тренеров весят больше всего, отметки игроков с надёжным рейтингом — больше обычных, а старые оценки со временем теряют вес.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }
}

// MARK: - Self-assessment

private struct DNADetailSelfAssessmentSheet: View {
    let onSaved: (PadelDNA) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var values: [DNADimension: Int]
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isShowingError = false

    init(initial: [DNADimension: Int], onSaved: @escaping (PadelDNA) -> Void) {
        self.onSaved = onSaved
        _values = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Оцените каждое направление относительно своего общего уровня. Самооценка — лишь один из источников: со временем её уточняют отметки партнёров, оценки тренеров и результаты матчей.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DNASelfAssessmentEditor(values: $values)
                if !app.isOnline {
                    Section {
                        Label("Нет подключения. Сохранить самооценку можно после восстановления сети.", systemImage: "wifi.slash")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Самооценка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Сохранить") {
                            save()
                        }
                        .disabled(!app.isOnline)
                    }
                }
            }
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
            .alert("Не удалось сохранить", isPresented: $isShowingError) {
                Button("ОК", role: .cancel) {}
            } message: {
                Text(errorMessage ?? APIError.offline.message)
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        let answers: [String: Int] = Dictionary(uniqueKeysWithValues: DNADimension.allCases.map { dimension in
            (dimension.rawValue, min(2, max(-2, values[dimension] ?? 0)))
        })
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let updated = try await app.api.send(.json(.put, "v1/me/dna-self", answers), as: PadelDNA.self)
                onSaved(updated)
                dismiss()
            } catch let error as APIError {
                errorMessage = error.message
                isShowingError = true
            } catch {
                // Cancelled together with the sheet: nothing to report.
            }
        }
    }
}
