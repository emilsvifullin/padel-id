import SwiftUI

enum TrainingHistory: String, CaseIterable {
    case firstTime, current, returning

    var title: String {
        switch self {
        case .firstTime: "Нет, я впервые"
        case .current: "Да, занимаюсь сейчас"
        case .returning: "Да, занимался раньше"
        }
    }
}

struct MatchPointView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var history: TrainingHistory?
    @Binding var assessment: AssessmentRole?
    var onOpenSchedule: (() -> Void)? = nil
    let onSignOut: () -> Void

    @State private var selection: TrainingHistory?
    @State private var showsResult = false

    var body: some View {
        Group {
            if let history {
                if history == .current || (assessment != nil && !showsResult) {
                    statusScreen(for: history)
                } else {
                    OnboardingView(onBackFromIntro: { changeHistory(to: nil) }) { role in
                        showsResult = true
                        assessment = role
                    } onFinish: {
                        withAnimation(reduceMotion ? nil : Motion.standard) {
                            showsResult = false
                        }
                    }
                }
            } else {
                historyScreen
            }
        }
    }

    private var historyScreen: some View {
        MatchPointScreen(onSignOut: onSignOut) {
            VStack(alignment: .leading, spacing: 26) {
                Text("Вы уже тренировались в MatchPoint?")
                    .font(.display(.largeTitle, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: 10) {
                    ForEach(TrainingHistory.allCases, id: \.self) { option in
                        MatchPointOption(title: option.title, isSelected: selection == option) {
                            withAnimation(reduceMotion ? nil : Motion.quick) {
                                selection = option
                            }
                        }
                    }
                }
            }
        } footer: {
            Button("Продолжить") {
                if let selection { changeHistory(to: selection) }
            }
            .buttonStyle(AuthenticationButtonStyle())
            .disabled(selection == nil)

        }
    }

    private func statusScreen(for history: TrainingHistory) -> some View {
        let openSchedule = history == .current ? onOpenSchedule : nil
        return MatchPointScreen(centerContent: true, onSignOut: onSignOut) {
            VStack(spacing: 12) {
                Text(openSchedule == nil ? statusTitle(for: history) : "Вы в группе")
                    .font(.display(.title, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                Text(openSchedule != nil ? "Ближайшие тренировки уже в расписании." : (history == .firstTime
                     ? "Чтобы записаться на пробную тренировку, свяжитесь с администратором."
                     : "После назначения в группу здесь появится расписание."))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineSpacing(3)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 332)
        } footer: {
            if let openSchedule {
                Button("К расписанию", action: openSchedule)
                    .buttonStyle(AuthenticationButtonStyle())
            }
        }
    }

    private func statusTitle(for history: TrainingHistory) -> String {
        switch history {
        case .current: "Ожидаем назначения"
        case .returning: "Лист ожидания"
        case .firstTime: "Пробная тренировка"
        }
    }

    private func changeHistory(to value: TrainingHistory?) {
        withAnimation(reduceMotion ? nil : Motion.standard) {
            history = value
        }
    }
}

struct CompletePlayerNameView: View {
    @Environment(TennisAuth.self) private var auth
    @State private var firstName = ""
    @State private var lastName = ""

    private var playerName: PlayerName? { PlayerName(first: firstName, last: lastName) }

    var body: some View {
        MatchPointScreen(onSignOut: { Task { await auth.signOut() } }) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Как вас зовут?")
                    .font(.display(.largeTitle, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: 0) {
                    TextField("Имя", text: $firstName)
                        .textContentType(.givenName)
                        .padding(18)

                    Divider().overlay(.white.opacity(0.10)).padding(.horizontal, 18)

                    TextField("Фамилия", text: $lastName)
                        .textContentType(.familyName)
                        .padding(18)
                }
                .textInputAutocapitalization(.words)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
                .tint(.white)

                if let error = auth.accountError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                }
            }
        } footer: {
            Button("Продолжить") {
                guard let playerName else { return }
                Task { await auth.savePlayerName(playerName) }
            }
            .buttonStyle(AuthenticationButtonStyle())
            .disabled(playerName == nil)

        }
        .disabled(auth.isBusy)
        .onChange(of: firstName) { auth.clearAccountError() }
        .onChange(of: lastName) { auth.clearAccountError() }
    }
}

private struct MatchPointScreen<Content: View, Footer: View>: View {
    var centerContent = false
    let onSignOut: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    @State private var confirmsSignOut = false

    var body: some View {
        ZStack {
            MatchPointBackground()

            VStack(spacing: 0) {
                Text("Tennis ID")
                    .font(.display(.subheadline, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(height: 48)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                ScrollView {
                    content()
                        .padding(24)
                        .frame(maxWidth: 480)
                        .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(centerContent ? .center : .top, for: .alignment)

                VStack(spacing: 4) {
                    footer()

                    Button {
                        confirmsSignOut = true
                    } label: {
                        Text(centerContent ? "Выйти из аккаунта" : "Выход")
                            .font(centerContent ? .subheadline.weight(.medium) : .body)
                            .foregroundStyle(.white.opacity(centerContent ? 0.72 : 1))
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white)
        .alert("Выйти из аккаунта?", isPresented: $confirmsSignOut) {
            Button("Отменить", role: .cancel) {}
            Button("Выйти", role: .destructive, action: onSignOut)
        }
    }
}

struct MatchPointBackground: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                Image("TennisCourt")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .opacity(0.30)
                LinearGradient(
                    colors: [.black.opacity(0.50), .black.opacity(0.86), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct MatchPointOption: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20)

        Button(action: action) {
            HStack(spacing: 14) {
                Text(title)
                    .font(.body.weight(.medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(isSelected ? .black : .white.opacity(0.46))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(isSelected ? .black : .white)
            .padding(.horizontal, 18)
            .padding(.vertical, 17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? .white : .white.opacity(0.08), in: shape)
            .overlay { shape.strokeBorder(.white.opacity(isSelected ? 0 : 0.16), lineWidth: 1) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
