import SwiftUI

struct OnboardingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onBackFromIntro: (() -> Void)?
    let onResult: (AssessmentRole) -> Void
    let onFinish: () -> Void

    @State private var showsIntro = true
    @State private var step = 0
    @State private var answers: [Int?] = Array(repeating: nil, count: questions.count)
    @State private var result: AssessmentRole?

    // Adapted from Old College Tennis Club and the Tennis Canada Self-Rating Guide.
    private static let questions = [
        AssessmentQuestion(
            title: "Как вы оцениваете уровень своей игры?",
            options: ["Начинающий", "Любитель", "Продвинутый"]
        ),
        AssessmentQuestion(
            title: "Как часто вы играете в теннис?",
            options: [
                "Ещё ни разу не играл",
                "Играл раньше, сейчас не играю",
                "Реже раза в неделю",
                "Раз в неделю или чаще"
            ]
        ),
        AssessmentQuestion(
            title: "Как у вас получается подавать?",
            options: [
                "Только учусь подавать или часто допускаю двойные ошибки",
                "В матче обычно попадаю второй подачей в квадрат",
                "В матче направляю первую подачу и редко делаю двойные ошибки"
            ]
        ),
        AssessmentQuestion(
            title: "Как вы держите розыгрыш с задней линии?",
            options: [
                "В спокойном темпе часто ошибаюсь после нескольких ударов",
                "В среднем темпе держу мяч в игре ударами справа и слева",
                "В быстром темпе держу глубину и могу менять направление мяча"
            ]
        ),
        AssessmentQuestion(
            title: "Как вы принимаете подачу?",
            options: [
                "Ещё не пробовал или часто ошибаюсь даже на спокойной подаче",
                "Возвращаю большинство подач средней скорости",
                "Против быстрой подачи удерживаю мяч в игре, а на удобной могу перехватить инициативу"
            ]
        ),
        AssessmentQuestion(
            title: "Как вы играете у сетки?",
            options: [
                "Редко выхожу к сетке или часто ошибаюсь с лёта",
                "Попадаю в корт с лёта, когда мяч летит удобно",
                "После глубокого удара выхожу к сетке и с лёта направляю мяч в свободную часть корта"
            ]
        )
    ]

    private var question: AssessmentQuestion { Self.questions[step] }
    private var canContinue: Bool { answers[step] != nil }

    var body: some View {
        ZStack {
            MatchPointBackground()

            VStack(spacing: 0) {
                header

                ScrollView {
                    Group {
                        if showsIntro {
                            introduction
                                .transition(.opacity)
                        } else if let result {
                            resultContent(result)
                                .transition(.opacity)
                        } else {
                            questionnaire
                                .id(step)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(showsIntro || result != nil ? .center : .top, for: .alignment)

                primaryButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var introduction: some View {
        VStack(spacing: 14) {
            Text("Анкетирование")
                .font(.display(.largeTitle, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            Text("Отвечайте исходя из того, что обычно получается на корте. Мы подберём группу с игроками вашего уровня, а тренер при необходимости предложит другую.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.82))
                .lineSpacing(3)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
    }

    private var questionnaire: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 12) {
                Text("Шаг \(step + 1) из \(Self.questions.count)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.76))
                    .fixedSize()

                ProgressView(value: Double(step + 1), total: Double(Self.questions.count))
                    .tint(.white)
                    .accessibilityHidden(true)
            }

            Text(question.title)
                .font(.display(.largeTitle, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 10) {
                ForEach(question.options.indices, id: \.self) { index in
                    optionButton(index: index)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            if result == nil && (!showsIntro || onBackFromIntro != nil) {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Назад")
            } else {
                Color.clear
                    .frame(width: 48, height: 48)
            }

            Spacer()

            Text("Tennis ID")
                .font(.display(.subheadline, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))

            Spacer()

            Color.clear
                .frame(width: 48, height: 48)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func optionButton(index: Int) -> some View {
        let option = question.options[index]
        let selected = answers[step] == index

        return MatchPointOption(title: option, isSelected: selected) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.20)) {
                answers[step] = index
            }
        }
    }

    private var primaryButton: some View {
        let lastQuestion = step == Self.questions.count - 1
        let title = showsIntro ? "Начать" : lastQuestion && result == nil ? "Показать результат" : "Продолжить"

        return Button(title) {
            if result != nil {
                onFinish()
                return
            }

            guard showsIntro || canContinue else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                if showsIntro {
                    showsIntro = false
                } else if lastQuestion {
                    let assessedRole = assessLevel()
                    result = assessedRole
                    onResult(assessedRole)
                } else {
                    step += 1
                }
            }
        }
        .buttonStyle(AuthenticationButtonStyle())
        .disabled(!showsIntro && result == nil && !canContinue)
    }

    private func resultContent(_ result: AssessmentRole) -> some View {
        VStack(spacing: 12) {
            Text("Предварительный уровень")
                .font(.body)

            Text(result.title)
                .font(.display(.largeTitle, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
        }
        .multilineTextAlignment(.center)
    }

    private func goBack() {
        guard result == nil else { return }
        if showsIntro {
            onBackFromIntro?()
            return
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
            if step > 0 {
                step -= 1
            } else {
                showsIntro = true
            }
        }
    }

    private func assessLevel() -> AssessmentRole {
        let levels = answers.compactMap { $0 }
        guard levels.count == Self.questions.count else { return .beginner }

        // Self-rating and frequency don't add points. Players with no court experience start in the beginner group.
        let hasNeverPlayed = levels[1] == 0
        let skills = levels.dropFirst(2)
        if hasNeverPlayed || skills.prefix(3).contains(0) {
            return .beginner
        }
        return skills.allSatisfy { $0 == 2 } ? .advanced : .amateur
    }
}

enum AssessmentRole: String {
    case beginner, amateur, advanced

    var title: String {
        switch self {
        case .beginner: "Начинающий"
        case .amateur: "Любитель"
        case .advanced: "Продвинутый"
        }
    }
}

private struct AssessmentQuestion {
    let title: String
    let options: [String]
}
