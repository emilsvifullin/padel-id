import SwiftUI

// MARK: - Level

/// The player's level as the primary numeral of the product.
struct LevelNumeral: View {
    let level: Double?
    var size: CGFloat = 56

    var body: some View {
        Text(Format.level(level))
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText(value: level ?? 0))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityLabel("Уровень \(Format.level(level))")
    }
}

/// Compact level chip used in rows and line-ups.
struct LevelChip: View {
    let level: Double?
    var reliability: Int?

    var body: some View {
        Text(Format.level(level))
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.accent.opacity(isReliable ? 0.16 : 0.08), in: .capsule)
            .foregroundStyle(isReliable ? Theme.accent : .secondary)
            .accessibilityLabel(accessibility)
    }

    private var isReliable: Bool { (reliability ?? 0) >= 40 }

    private var accessibility: String {
        var text = "Уровень \(Format.level(level))"
        if let reliability { text += ", надёжность \(reliability)%" }
        return text
    }
}

/// Signed rating change.
struct DeltaText: View {
    let delta: Double?
    var digits = 2
    var font: Font = .subheadline.weight(.semibold)

    var body: some View {
        Text(Format.delta(delta, digits: digits))
            .font(font)
            .monospacedDigit()
            .foregroundStyle(Theme.deltaColor(delta))
            .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        guard let delta else { return "Без изменения" }
        if delta > 0.0005 { return "Рост на \(Format.level(delta))" }
        if delta < -0.0005 { return "Снижение на \(Format.level(abs(delta)))" }
        return "Без изменения"
    }
}

/// Circular reliability indicator.
struct ReliabilityRing: View {
    let reliability: Int
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: size * 0.11)
            Circle()
                .trim(from: 0, to: CGFloat(reliability) / 100)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(reliability)")
                .font(.system(size: size * 0.32, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Надёжность рейтинга \(reliability) процентов")
    }
}

// MARK: - Avatars

struct AvatarView: View {
    let id: UUID
    let name: String
    let path: String?
    var size: CGFloat = 40
    var deleted = false

    var body: some View {
        ZStack {
            if let path, let url = AvatarLoader.url(for: path) {
                RemoteImage(url: url) {
                    monogram
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }

    private var monogram: some View {
        ZStack {
            Circle().fill(deleted ? Color.secondary.opacity(0.25) : Theme.monogramTint(for: id).opacity(0.22))
            if deleted {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(.secondary)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.monogramTint(for: id))
            }
        }
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

extension AvatarView {
    init(card: PlayerCard, size: CGFloat = 40) {
        self.init(id: card.id, name: card.displayName, path: card.avatarPath, size: size, deleted: card.deleted)
    }

    init(profile: Profile, size: CGFloat = 40) {
        self.init(id: profile.id, name: profile.displayName, path: profile.avatarPath, size: size, deleted: profile.deleted)
    }
}

/// Loads immutable images through a dedicated, persistent URL cache.
enum AvatarLoader {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    static func url(for path: String) -> URL? {
        AppEnvironment.apiBaseURL.appending(path: "v1/avatars/\(path)")
    }
}

struct RemoteImage<Placeholder: View>: View {
    let url: URL
    @ViewBuilder var placeholder: Placeholder
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder
            }
        }
        .task(id: url) {
            guard image == nil else { return }
            if let result = try? await AvatarLoader.session.data(from: url), let loaded = UIImage(data: result.0) {
                image = loaded
            }
        }
    }
}

// MARK: - Rows

struct PlayerRow<Trailing: View>: View {
    let card: PlayerCard
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(card: PlayerCard, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.card = card
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(card: card, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(card.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if card.isCoach {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                            .accessibilityLabel("Тренер")
                    }
                }
                Text(subtitle ?? defaultSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var defaultSubtitle: String {
        var parts: [String] = []
        if let username = card.username { parts.append("@\(username)") }
        if let city = card.city?.name { parts.append(city) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Status

struct StatusPill: View {
    let text: String
    var color: Color = .secondary
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: .capsule)
    }
}

/// Thin banner shown while the device is offline or data is stale.
struct OfflineBanner: View {
    var message = "Нет подключения. Показаны сохранённые данные."

    var body: some View {
        Label(message, systemImage: "wifi.slash")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: Theme.smallCornerRadius, style: .continuous))
    }
}

/// Loading placeholder with consistent spacing.
struct LoadingView: View {
    var body: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 80)
    }
}

/// Full-screen error state with retry.
struct ErrorStateView: View {
    let error: APIError
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(error.isNetwork ? "Нет подключения" : "Не удалось загрузить",
                  systemImage: error.isNetwork ? "wifi.slash" : "exclamationmark.triangle")
        } description: {
            Text(error.message)
        } actions: {
            Button("Повторить", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}
