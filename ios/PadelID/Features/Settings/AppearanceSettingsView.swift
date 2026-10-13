import SwiftUI
import UIKit
import Observation

nonisolated enum AppAppearance: String, CaseIterable, Identifiable {
    case automatic, light, dark
    static let storageKey = "padelid.appearance"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Автоматически"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

nonisolated enum AppIconChoice: String, CaseIterable, Identifiable {
    case lime, charcoal, ball
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lime: "Лайм"
        case .charcoal: "Графит"
        case .ball: "Мяч"
        }
    }
    var alternateName: String? {
        switch self {
        case .lime: nil
        case .charcoal: "AppIconCharcoal"
        case .ball: "AppIconBall"
        }
    }
    var previewName: String { "IconPreview-" + rawValue }
    static func current(named name: String?) -> Self? {
        allCases.first { $0.alternateName == name }
    }
}

protocol AppIconChanging {
    var supportsAlternateIcons: Bool { get }
    var alternateIconName: String? { get }
    func changeIcon(to name: String?) async throws
}

struct SystemAppIconChanger: AppIconChanging {
    var supportsAlternateIcons: Bool { UIApplication.shared.supportsAlternateIcons }
    var alternateIconName: String? { UIApplication.shared.alternateIconName }
    func changeIcon(to name: String?) async throws {
        try await UIApplication.shared.setAlternateIconName(name)
    }
}

/// iOS owns the persistent selection. A failed request never selects a preview.
@Observable
final class AppIconSelection {
    private let system: any AppIconChanging
    private(set) var selected: AppIconChoice?
    private(set) var isChanging = false
    var errorMessage: String?
    var isSupported: Bool { system.supportsAlternateIcons }

    init(system: any AppIconChanging = SystemAppIconChanger()) {
        self.system = system
        refresh()
    }

    func refresh() { selected = AppIconChoice.current(named: system.alternateIconName) }

    func choose(_ icon: AppIconChoice) async {
        guard !isChanging else { return }
        refresh()
        guard selected != icon else { return }
        guard isSupported else {
            errorMessage = "На этом устройстве смена иконки недоступна."
            return
        }
        isChanging = true
        errorMessage = nil
        defer { isChanging = false; refresh() }
        do {
            try await system.changeIcon(to: icon.alternateName)
        } catch {
            errorMessage = "iOS не смогла изменить иконку. Попробуйте ещё раз, когда приложение активно."
        }
    }
}

struct AppearanceSettingsView: View {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.automatic.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @State private var icons = AppIconSelection()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            Section {
                Picker(selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.title).font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .tag(option.rawValue)
                            .accessibilityIdentifier("appearance.theme." + option.rawValue)
                    }
                } label: {
                    Text("Тема").font(.body).fixedSize(horizontal: false, vertical: true)
                }
                .font(.body)
                .pickerStyle(.inline)
                .accessibilityIdentifier("appearance.theme")
            } header: {
                Text("Оформление").foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } footer: {
                Text("Автоматический режим следует оформлению iPhone. Тема применяется сразу ко всем экранам.").foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                ForEach(AppIconChoice.allCases) { icon in
                    Button {
                        Task { await icons.choose(icon) }
                    } label: {
                        HStack(spacing: 16) {
                            Image(icon.previewName)
                                .resizable()
                                .frame(width: 24, height: 24)
                                .clipShape(.rect(cornerRadius: 6))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(icon.title).foregroundStyle(Color.primary)
                                if icon == .lime {
                                    Text("По умолчанию").font(.caption).foregroundStyle(Color.primary)
                                        .accessibilityHidden(true)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                            Spacer()
                            if icons.selected == icon {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(.rect)
                    }
                    .disabled(icons.isChanging || !icons.isSupported)
                    .accessibilityValue(icons.selected == icon ? "Выбрана" : "Не выбрана")
                    .accessibilityHint(icon == .lime ? "Иконка по умолчанию" : "Меняет иконку на домашнем экране")
                    .accessibilityIdentifier("appearance.icon." + icon.rawValue)
                }
                if icons.isChanging {
                    ProgressView("Меняем иконку…")
                }
                if let error = icons.errorMessage {
                    SettingsErrorRow(message: error)
                        .accessibilityIdentifier("appearance.icon.error")
                }
                if !icons.isSupported {
                    Text("На этом устройстве смена иконки недоступна.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Иконка приложения").foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } footer: {
                Text("Изменяется иконка Padel ID на домашнем экране iPhone. Системное оформление иконок выбирается в настройках домашнего экрана.").foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("appearance.icon.help")
            }
        }
        .contentMargins(.bottom, 24, for: .scrollContent)
        .navigationTitle("Оформление")
        // Every screen changes colour at once: dissolve into the new theme
        // instead of cutting to it.
        .onChange(of: appearance) {
            guard !reduceMotion else { return }
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.3
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for scene in UIApplication.shared.connectedScenes {
                (scene as? UIWindowScene)?.keyWindow?.layer.add(fade, forKey: "theme")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { icons.refresh() }
        }
    }
}

