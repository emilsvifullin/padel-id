import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @State private var path: [AuthRoute] = []

    enum AuthRoute: Hashable {
        case signIn, signUp, recover
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 16) {
                        BrandMark(size: 72)
                        Text("Padel ID")
                            .font(.largeTitle.bold())
                        Text("Ваш уровень, стиль игры и подтверждённые матчи — в одном профиле игрока.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 24)

                    VStack(alignment: .leading, spacing: 20) {
                        FeatureRow(symbol: "chart.line.uptrend.xyaxis",
                                   title: "Честный рейтинг 0–7",
                                   text: "Учитывает партнёра, соперников и счёт. Показывает надёжность и объясняет каждое изменение.")
                        FeatureRow(symbol: "hexagon",
                                   title: "Padel DNA",
                                   text: "Шесть направлений игры по оценкам партнёров, тренеров и результатам матчей.")
                        FeatureRow(symbol: "checkmark.seal",
                                   title: "Матчи без споров",
                                   text: "Результат засчитывается, только когда его подтвердили все четыре игрока.")
                    }

                    if let notice = app.signOutNotice {
                        Label(notice, systemImage: "info.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.bottom, 24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color(.systemGroupedBackground))
            .safeAreaBar(edge: .bottom) {
                GlassEffectContainer {
                    VStack(spacing: 12) {
                        Button {
                            path.append(.signUp)
                        } label: {
                            Text("Создать аккаунт")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("welcome.signUp")

                        Button {
                            path.append(.signIn)
                        } label: {
                            Text("Войти")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("welcome.signIn")
                    }
                }
                .controlSize(.large)
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.bottom, 8)
            }
            .navigationDestination(for: AuthRoute.self) { route in
                switch route {
                case .signIn: SignInView(onForgotPassword: { path.append(.recover) })
                case .signUp: SignUpView()
                case .recover: RecoverView()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Theme.accent)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
