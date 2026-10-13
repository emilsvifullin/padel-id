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
                VStack(alignment: .leading, spacing: 28) {
                    hero
                    VStack(alignment: .leading, spacing: 22) {
                        FeatureRow(symbol: "person.2.fill",
                                   title: "Собирайте свою игру",
                                   text: "Находите партнёров, общайтесь и договаривайтесь о встречах на корте.")
                        FeatureRow(symbol: "hexagon.fill",
                                   title: "Padel DNA",
                                   text: "Шесть направлений игры по оценкам партнёров, тренеров и результатам матчей.")
                        FeatureRow(symbol: "checkmark.seal.fill",
                                   title: "Подтверждённые результаты",
                                   text: "Результат засчитывается, только когда его подтвердили все четыре игрока.")
                    }
                    .padding(.horizontal, Theme.horizontalPadding)

                    VStack(alignment: .leading, spacing: 12) {
                        if let notice = app.signOutNotice {
                            Label(notice, systemImage: "info.circle")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        NavigationLink("Проверка сети", value: AuthRoute.network)
                            .font(.footnote)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("welcome.network")
                    }
                    .padding(.horizontal, Theme.horizontalPadding)
                }
                .padding(.bottom, 24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .ignoresSafeArea(edges: .top)
            .scrollBounceBehavior(.basedOnSize)
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .padelCanvas()
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
                        .padelGlassProminent()
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

private extension WelcomeView {
    /// The app icon opened up: its lime, its ink and the racket's six holes.
    var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image("IconPreview-lime")
                    .resizable().frame(width: 64, height: 64)
                    .clipShape(.rect(cornerRadius: 16, style: .continuous))
                    .shadow(color: Theme.ink.opacity(0.18), radius: 12, y: 6)
                    .accessibilityHidden(true)
                Spacer()
                PerforationGrid(dot: 22, gap: 12, color: Theme.ink.opacity(0.9))
            }
            Spacer(minLength: 56)
            Text("Padel ID")
                .font(.display(.largeTitle, weight: .heavy))
            Text("Ваше место\nв мире падела.")
                .font(.display(.title, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Text("Игроки, общение и спортивный прогресс — в одном приложении.")
                .font(.body)
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .padding(.horizontal, Theme.horizontalPadding + 4)
        .padding(.top, 76)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, minHeight: 420, alignment: .leading)
        .foregroundStyle(Theme.ink)
        .background {
            LimeSurface()
                .clipShape(.rect(bottomLeadingRadius: 40, bottomTrailingRadius: 40, style: .continuous))
        }
        .environment(\.colorScheme, .light)
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            SymbolPlate(symbol: symbol)
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
