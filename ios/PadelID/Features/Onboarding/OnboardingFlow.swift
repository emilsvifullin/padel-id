import SwiftUI

/// Four-step onboarding shown while `app.phase == .onboarding`: profile, game,
/// calibration questions and the Padel DNA self-assessment, followed by the
/// starting level.
struct OnboardingFlow: View {
    @State private var model = OnboardingModel()

    init() {}

    var body: some View {
        ZStack {
            if let me = model.result {
                OnboardingResultView(me: me)
                    .transition(.opacity)
            } else {
                NavigationStack(path: $model.path) {
                    OnboardingProfileStep(model: model)
                        .navigationDestination(for: OnboardingDestination.self) { destination in
                            switch destination {
                            case .game:
                                OnboardingGameStep(model: model)
                            case .level:
                                OnboardingLevelStep(model: model)
                            case .style:
                                OnboardingStyleStep(model: model)
                            case .city:
                                CityPickerView(selection: $model.citySelection)
                            case .club(let cityId):
                                ClubPickerView(cityId: cityId, selection: $model.clubSelection)
                            }
                        }
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth, value: model.result != nil)
        .sensoryFeedback(.success, trigger: model.result != nil) { _, isDone in isDone }
        .sensoryFeedback(.error, trigger: model.failureCount)
    }
}

// MARK: - Step 1: profile

private nonisolated enum OnboardingProfileField: Hashable, Sendable {
    case name, username
}

private struct OnboardingProfileStep: View {
    @Environment(AppModel.self) private var app
    @Bindable private var model: OnboardingModel
    @FocusState private var focus: OnboardingProfileField?

    init(model: OnboardingModel) {
        _model = Bindable(model)
    }

    var body: some View {
        OnboardingStepScreen(step: .profile, canContinue: model.isProfileComplete, action: {
            focus = nil
            model.path.append(.game)
        }) {
            nameSection
            usernameSection
            locationSection
        }
        .onChange(of: model.displayName) {
            model.displayNameDidChange(api: app.api)
        }
    }

    private var nameSection: some View {
        Section {
            TextField("Имя и фамилия", text: $model.displayName)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .name)
                .onSubmit { focus = .username }
                .accessibilityIdentifier("onboarding.displayName")
        } header: {
            Text("Имя")
        } footer: {
            if let message = model.nameMessage {
                Text(message)
                    .foregroundStyle(Theme.negative)
            } else {
                Text("От 2 до 40 букв; можно пробел, дефис, точку и апостроф.")
            }
        }
    }

    private var usernameSection: some View {
        Section {
            HStack(spacing: 6) {
                Text("@")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Латиница, цифры и «_»", text: Binding(
                    get: { model.username },
                    set: { model.editUsername($0, api: app.api) }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .submitLabel(.done)
                .focused($focus, equals: .username)
                .onSubmit { focus = nil }
                .accessibilityLabel("Имя пользователя")
                .accessibilityIdentifier("onboarding.username")
                OnboardingUsernameIndicator(status: model.usernameStatus)
            }
        } header: {
            Text("Имя пользователя")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let status = OnboardingUsernameText.status(model.usernameStatus, username: model.username) {
                    Text(status)
                        .foregroundStyle(OnboardingUsernameText.tint(model.usernameStatus))
                }
                Text("От 3 до 20 символов. По имени пользователя вас найдут в поиске.")
            }
            .animation(.default, value: model.usernameStatus)
        }
    }

    private var locationSection: some View {
        Section {
            NavigationLink(value: OnboardingDestination.city) {
                LabeledContent("Город") {
                    Text(model.city?.name ?? "Выбрать")
                }
            }
            .accessibilityIdentifier("onboarding.city")
            if let city = model.city {
                NavigationLink(value: OnboardingDestination.club(cityId: city.id)) {
                    LabeledContent("Клуб") {
                        Text(model.club?.name ?? "Необязательно")
                    }
                }
                .accessibilityIdentifier("onboarding.club")
            }
        } header: {
            Text("Где вы играете")
        } footer: {
            if let error = model.locationError {
                Text(error)
                    .foregroundStyle(Theme.negative)
            } else {
                Text("Город нужен, чтобы находить партнёров и соперников рядом. Клуб — по желанию.")
            }
        }
    }
}

/// Wording of the live username check.
private enum OnboardingUsernameText {
    static func status(_ status: OnboardingUsernameStatus, username: String) -> String? {
        switch status {
        case .empty: nil
        case .checking: "Проверяем…"
        case .available: "@\(username) свободно"
        case .taken: "Занято — выберите другое имя"
        case .invalid(let reason): "Недопустимо: \(reason)"
        case .unverified: "Не удалось проверить — проверим при сохранении"
        }
    }

    static func tint(_ status: OnboardingUsernameStatus) -> Color {
        switch status {
        case .available: Theme.positive
        case .taken, .invalid: Theme.negative
        case .empty, .checking, .unverified: Color.secondary
        }
    }
}

private struct OnboardingUsernameIndicator: View {
    let status: OnboardingUsernameStatus

    var body: some View {
        Group {
            switch status {
            case .empty:
                EmptyView()
            case .checking:
                ProgressView()
                    .controlSize(.small)
            case .available:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.positive)
            case .taken, .invalid:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.negative)
            case .unverified:
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Step 2: game

private struct OnboardingGameStep: View {
    @Bindable private var model: OnboardingModel

    init(model: OnboardingModel) {
        _model = Bindable(model)
    }

    var body: some View {
        OnboardingStepScreen(step: .game, canContinue: model.isGameComplete, action: {
            model.path.append(.level)
        }) {
            OnboardingQuestionSection(
                question: "На какой стороне корта вы играете?",
                options: [CourtSide.right, .left, .both],
                selection: $model.side,
                title: { Narratives.sideShort($0) },
                detail: { OnboardingGameStep.sideDetail($0) },
                footer: "В паре один игрок играет справа, другой — слева. Сторона помогает подбирать партнёров.")

            Section {
                ForEach(Hand.allCases, id: \.self) { hand in
                    OnboardingChoiceRow(title: hand == .right ? "Правая" : "Левая", isSelected: model.hand == hand) {
                        model.hand = hand
                    }
                }
            } header: {
                Text("Игровая рука")
            }
            .headerProminence(.increased)

            Section {
                Picker("Год начала", selection: $model.playingSince) {
                    Text("Не указывать")
                        .tag(Int?.none)
                    ForEach(OnboardingModel.yearOptions, id: \.self) { year in
                        Text(String(year))
                            .tag(Int?.some(year))
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Когда начали играть")
            } footer: {
                Text("Необязательно. Год будет виден в вашем профиле.")
            }
            .headerProminence(.increased)
        }
    }

    static func sideDetail(_ side: CourtSide) -> String {
        switch side {
        case .right: "Стабильность, приём и игра через центр"
        case .left: "Атака и завершение розыгрыша ударами над головой"
        case .both: "Одинаково уверенно на обеих сторонах"
        }
    }
}

// MARK: - Step 3: level

private struct OnboardingLevelStep: View {
    @Bindable private var model: OnboardingModel

    init(model: OnboardingModel) {
        _model = Bindable(model)
    }

    var body: some View {
        OnboardingStepScreen(step: .level, canContinue: model.isLevelComplete, action: {
            model.path.append(.style)
        }) {
            OnboardingQuestionSection(
                question: OnboardingExperience.question,
                options: OnboardingExperience.allCases,
                selection: $model.experience,
                title: { $0.title })
            OnboardingQuestionSection(
                question: OnboardingFrequency.question,
                options: OnboardingFrequency.allCases,
                selection: $model.frequency,
                title: { $0.title })
            OnboardingQuestionSection(
                question: OnboardingRacket.question,
                options: OnboardingRacket.allCases,
                selection: $model.racket,
                title: { $0.title },
                detail: { $0.detail })
            scaleSection(.glass, selection: $model.glass)
            scaleSection(.net, selection: $model.net)
            scaleSection(.competition, selection: $model.competition, footer: remainingText)
        }
    }

    private var remainingText: String? {
        let remaining = model.remainingLevelAnswers
        guard remaining > 0 else { return nil }
        return "Осталось ответить на " + Format.count(remaining, "вопрос", "вопроса", "вопросов") + "."
    }

    private func scaleSection(_ question: OnboardingScaleQuestion, selection: Binding<Int?>,
                              footer: String? = nil) -> some View {
        let options = question.options
        return OnboardingQuestionSection(
            question: question.question,
            options: Array(options.indices),
            selection: selection,
            title: { options[$0] },
            footer: footer)
    }
}

// MARK: - Step 4: style

private struct OnboardingStyleStep: View {
    @Environment(AppModel.self) private var app
    @Bindable private var model: OnboardingModel

    init(model: OnboardingModel) {
        _model = Bindable(model)
    }

    var body: some View {
        OnboardingStepScreen(
            step: .style,
            primaryTitle: "Завершить",
            primaryIdentifier: "onboarding.finish",
            canContinue: model.canFinish && app.isOnline,
            isWorking: model.isSubmitting,
            scrollRequest: model.failureCount,
            action: {
                Task { await model.finish(app: app) }
            }
        ) {
            Section {
                DNASelfAssessmentEditor(values: $model.dna)
            }

            if !app.isOnline {
                Section {
                    Label("Нет подключения к интернету. Ответы останутся на этом экране — завершите, когда сеть появится.",
                          systemImage: "wifi.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.submitError {
                Section {
                    Label(error.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.negative)
                        .id(OnboardingScrollAnchor.bottom)
                }
            }
        }
        .disabled(model.isSubmitting)
    }
}

// MARK: - Shared step chrome

private nonisolated enum OnboardingScrollAnchor {
    static let bottom = "onboarding.bottom"
}

/// A step screen: progress header, form content, the primary action pinned to
/// the bottom in a glass container and the sign-out menu.
private struct OnboardingStepScreen<Content: View>: View {
    @Environment(AppModel.self) private var app
    @State private var isSignOutPresented = false

    private let step: OnboardingStep
    private let primaryTitle: String
    private let primaryIdentifier: String
    private let canContinue: Bool
    private let isWorking: Bool
    private let scrollRequest: Int
    private let action: () -> Void
    private let content: Content

    init(step: OnboardingStep,
         primaryTitle: String = "Далее",
         primaryIdentifier: String = "onboarding.next",
         canContinue: Bool,
         isWorking: Bool = false,
         scrollRequest: Int = 0,
         action: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.step = step
        self.primaryTitle = primaryTitle
        self.primaryIdentifier = primaryIdentifier
        self.canContinue = canContinue
        self.isWorking = isWorking
        self.scrollRequest = scrollRequest
        self.action = action
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    OnboardingProgressHeader(step: step)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                content
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: scrollRequest) {
                withAnimation(.smooth) {
                    proxy.scrollTo(OnboardingScrollAnchor.bottom, anchor: .bottom)
                }
            }
            .safeAreaBar(edge: .bottom) {
                OnboardingActionBar(title: primaryTitle, identifier: primaryIdentifier,
                                    isEnabled: canContinue, isWorking: isWorking, action: action)
            }
        }
        .navigationTitle(step.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        isSignOutPresented = true
                    } label: {
                        Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Label("Ещё", systemImage: "ellipsis")
                }
                .accessibilityIdentifier("onboarding.menu")
            }
        }
        .confirmationDialog("Выйти из аккаунта?", isPresented: $isSignOutPresented, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) {
                Task { await app.signOut() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Ответы не сохранятся. Заполнить профиль можно будет после входа.")
        }
    }
}

/// "Шаг N из 4" with a segmented progress bar and the step's purpose.
private struct OnboardingProgressHeader: View {
    let step: OnboardingStep

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Theme.accent : Color(.tertiarySystemFill))
                        .frame(height: 4)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(stepText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text(step.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var stepText: String {
        "Шаг \(step.rawValue) из \(OnboardingStep.allCases.count)"
    }
}

/// A single-choice option row with a trailing checkmark.
private struct OnboardingChoiceRow: View {
    let title: String
    var detail: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        // Color.secondary: inside a button `.secondary` would be
                        // a lighter shade of the accent tint.
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isSelected) { _, selected in selected }
    }
}

/// A question with single-choice answers as a form section.
private struct OnboardingQuestionSection<Option: Hashable>: View {
    let question: String
    let options: [Option]
    @Binding var selection: Option?
    let title: (Option) -> String
    var detail: (Option) -> String? = { _ in nil }
    var footer: String? = nil

    var body: some View {
        Section {
            ForEach(options, id: \.self) { option in
                OnboardingChoiceRow(title: title(option), detail: detail(option), isSelected: selection == option) {
                    selection = option
                }
            }
        } header: {
            Text(question)
        } footer: {
            if let footer {
                Text(footer)
            }
        }
        .headerProminence(.increased)
    }
}

/// The bottom action area: one prominent glass button.
struct OnboardingActionBar: View {
    let title: String
    let identifier: String
    var isEnabled = true
    var isWorking = false
    let action: () -> Void

    var body: some View {
        GlassEffectContainer {
            Button(action: action) {
                Text(isWorking ? "Сохраняем…" : title)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .disabled(!isEnabled || isWorking)
            .accessibilityIdentifier(identifier)
        }
        .controlSize(.large)
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.bottom, 8)
    }
}
