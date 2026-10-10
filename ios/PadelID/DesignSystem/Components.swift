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
        // VoiceOver declines «%» itself (a hard-coded «процентов» did not).
        .accessibilityLabel("Надёжность рейтинга " + String(reliability) + "%")
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
    /// Emptied on sign-out: the next account must not inherit the photos the
    /// previous one browsed.
    static let cache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024)

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache
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
    /// The URL `image` was loaded from: a changed URL (a new photo) reloads.
    @State private var loadedURL: URL?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder
            }
        }
        .task(id: url) {
            guard loadedURL != url else { return }
            if let result = try? await AvatarLoader.session.data(from: url), let loaded = UIImage(data: result.0) {
                image = loaded
                loadedURL = url
            } else if !Task.isCancelled {
                // Never keep showing the photo of a previous URL.
                image = nil
                loadedURL = nil
            }
        }
    }
}

// MARK: - Rows

struct PlayerRow<Trailing: View>: View {
    let card: PlayerCard
    var subtitle: String?
    @ViewBuilder var trailing: Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(card: PlayerCard, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.card = card
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        // At accessibility sizes names wrap and the trailing content moves
        // under them instead of squeezing the name to a few letters.
        if dynamicTypeSize.isAccessibilitySize {
            HStack(alignment: .top, spacing: 12) {
                AvatarView(card: card, size: 44)
                VStack(alignment: .leading, spacing: 6) {
                    details
                    trailing
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 12) {
                AvatarView(card: card, size: 44)
                details
                Spacer(minLength: 8)
                trailing
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(card.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(textLineLimit)
                    .fixedSize(horizontal: false, vertical: textLineLimit == nil)
                if card.isCoach {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("Тренер")
                }
            }
            if !card.deleted {
                Text("Надёжность: \(card.reliability.map { String($0) + "%" } ?? "—")")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Предпочитает: \(card.preferredSide.map { $0 == .both ? "обе стороны" : Narratives.sideShort($0).lowercased() } ?? "не указано")")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(subtitle ?? defaultSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(textLineLimit)
                .fixedSize(horizontal: false, vertical: textLineLimit == nil)
        }
    }

    /// One line normally; wrapping at accessibility sizes.
    private var textLineLimit: Int? {
        dynamicTypeSize.isAccessibilitySize ? nil : 1
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
    var systemImage = "wifi.slash"

    var body: some View {
        Label(message, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: Theme.smallCornerRadius, style: .continuous))
    }
}

/// Banner above cached data that could not be refreshed: the offline banner
/// for network failures, the server's explanation otherwise (for example
/// «Сервис временно недоступен»), so stale data is never shown silently.
struct StaleDataBanner: View {
    let error: APIError

    var body: some View {
        if error.isNetwork {
            OfflineBanner()
        } else {
            OfflineBanner(message: error.message + " Показаны сохранённые данные.",
                          systemImage: "exclamationmark.triangle")
        }
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

// MARK: - Results

/// One match result of a form row: a filled dot for a win, a hollow ring for
/// a loss, so the two differ by shape and not only by colour.
struct FormResultDot: View {
    let won: Bool
    let size: CGFloat

    var body: some View {
        if won {
            Circle()
                .fill(Theme.positive)
                .frame(width: size, height: size)
        } else {
            Circle()
                .strokeBorder(Theme.negative, lineWidth: max(1.5, size * 0.2))
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Layout

/// Places its subviews side by side in equal widths. Its ideal width is the
/// widest subview's ideal width times the count, so inside
/// `ViewThatFits(in: .horizontal)` it gives way to a vertical stack before
/// any label would have to wrap in its half.
struct EqualWidthHStack: Layout {
    /// Distance between neighbouring subviews.
    private let gap: CGFloat

    init(spacing: CGFloat = 12) {
        gap = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let count = CGFloat(subviews.count)
        let gaps = gap * (count - 1)
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = proposed
        } else {
            let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            width = widest * count + gaps
        }
        let column = max(0, (width - gaps) / count)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let count = CGFloat(subviews.count)
        let column = max(0, (bounds.width - gap * (count - 1)) / count)
        var x = bounds.minX
        for subview in subviews {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: column, height: nil))
            x += column + gap
        }
    }
}

// MARK: - VoiceOver

/// Speaks the result of an action (an error, a saved change) that appears
/// away from the control VoiceOver is focused on.
enum Announce {
    static func post(_ text: String) {
        Task {
            // VoiceOver drops announcements posted while the screen is still
            // changing (a sheet closing, a button disappearing).
            try? await Task.sleep(for: .milliseconds(350))
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }
}
