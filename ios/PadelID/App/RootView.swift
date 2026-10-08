import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastForegroundRefresh = Date.distantPast

    var body: some View {
        @Bindable var app = app
        ZStack {
            if app.isClientOutdated {
                UpdateRequiredView()
                    .transition(.opacity)
            } else {
                phaseContent
            }
        }
        .animation(.smooth, value: app.phase)
        .animation(.smooth, value: app.isClientOutdated)
        .task { await app.bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                // Keeps the match reminders scheduled even if iOS dropped the request.
                NotificationService.shared.scheduleBackgroundRefresh()
            }
            guard phase == .active, app.phase == .ready else { return }
            if Date.now.timeIntervalSince(lastForegroundRefresh) > 30 {
                lastForegroundRefresh = .now
                app.dataDidChange()
                Task { await app.flushOutbox() }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { app.recoveryKeyToShow != nil && app.phase != .launching },
            set: { if !$0 { app.recoveryKeyToShow = nil } }
        )) {
            if let key = app.recoveryKeyToShow {
                RecoveryKeyView(recoveryKey: key) {
                    app.recoveryKeyToShow = nil
                }
            }
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        ZStack {
            switch app.phase {
            case .launching:
                LaunchView()
                    .transition(.opacity)
            case .unavailable:
                LaunchFailureView()
                    .transition(.opacity)
            case .signedOut:
                WelcomeView()
                    .transition(.opacity)
            case .onboarding:
                OnboardingFlow()
                    .transition(.opacity)
            case .ready:
                MainTabView()
                    .transition(.opacity)
            }
        }
    }
}

/// Shown when the server no longer supports this build (426 client_outdated).
struct UpdateRequiredView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Обновите Padel ID", systemImage: "arrow.down.app")
        } description: {
            Text("Эта версия приложения больше не поддерживается. Установите новую версию — аккаунт, матчи и рейтинг сохранятся.")
        }
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("updateRequired")
    }
}

/// Branded launch state while the session is being restored.
struct LaunchView: View {
    var body: some View {
        VStack(spacing: 20) {
            BrandMark(size: 88)
            ProgressView()
                .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Padel ID загружается")
    }
}

/// Shown when the session exists but the first request failed and no cached
/// profile is available.
struct LaunchFailureView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ContentUnavailableView {
            Label(app.launchError?.isNetwork == false ? "Сервис недоступен" : "Нет подключения",
                  systemImage: app.launchError?.isNetwork == false ? "exclamationmark.icloud" : "wifi.slash")
        } description: {
            Text(app.launchError?.message ?? APIError.offline.message)
        } actions: {
            Button("Повторить") {
                Task { await app.retryLaunch() }
            }
            .buttonStyle(.borderedProminent)
            Button("Выйти из аккаунта", role: .destructive) {
                app.resetLocalState()
            }
            .buttonStyle(.borderless)
        }
        .background(Color(.systemGroupedBackground))
    }
}

/// The Padel ID mark: a ball inside a hexagon (the DNA shape).
struct BrandMark: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            HexagonShape()
                .fill(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            Circle()
                .fill(Theme.ball)
                .frame(width: size * 0.42, height: size * 0.42)
                .overlay {
                    Circle()
                        .trim(from: 0.1, to: 0.4)
                        .stroke(.white.opacity(0.9), lineWidth: size * 0.025)
                        .frame(width: size * 0.42, height: size * 0.42)
                        .offset(x: -size * 0.13)
                }
                .clipShape(.circle)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct HexagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for index in 0..<6 {
            let angle = (-90 + Double(index) * 60) * .pi / 180
            let point = CGPoint(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
