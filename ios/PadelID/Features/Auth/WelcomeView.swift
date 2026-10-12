import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @State private var path: [AuthRoute] = []

    enum AuthRoute: Hashable {
        case signIn, signUp, recover, network
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 16) {
                        Image("IconPreview-lime")
                            .resizable().frame(width: 72, height: 72)
                            .clipShape(.rect(cornerRadius: 18)).accessibilityHidden(true)
                        Text("Padel ID")
                            .font(.largeTitle.bold())
                        Text("Ваше место\nв мире падела.")
                            .font(.largeTitle.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Text("Игроки, общение и спортивный прогресс — в одном приложении.")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.white)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        ZStack(alignment: .topTrailing) {
                            Theme.ink
                            CourtMarkings().stroke(Theme.lime.opacity(0.12), lineWidth: 1)
                                .frame(width: 180, height: 220).rotationEffect(.degrees(-15)).offset(x: 40, y: -35)
                        }
                        .clipShape(.rect(cornerRadius: Theme.cornerRadius))
                        .accessibilityHidden(true)
                    }
                    .padding(.top, 16)

                    VStack(alignment: .leading, spacing: 20) {
                        FeatureRow(symbol: "person.2",
                                   title: "Собирайте свою игру",
                                   text: "Находите партнёров, общайтесь и договаривайтесь о встречах на корте.")
                        FeatureRow(symbol: "hexagon",
                                   title: "Padel DNA",
                                   text: "Шесть направлений игры по оценкам партнёров, тренеров и результатам матчей.")
                        FeatureRow(symbol: "checkmark.seal",
                                   title: "Подтверждённые результаты",
                                   text: "Результат засчитывается, только когда его подтвердили все четыре игрока.")
                    }

                    if let notice = app.signOutNotice {
                        Label(notice, systemImage: "info.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    NavigationLink("Проверка сети", value: AuthRoute.network)
                        .font(.footnote)
                        .accessibilityIdentifier("welcome.network")
                }
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.bottom, 24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollEdgeEffectStyle(.hard, for: .bottom)
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
                case .network: NetworkDiagnosticsView()
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
