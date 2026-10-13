import SwiftUI

// MARK: - Level

/// The player's level as the primary numeral of the product.
struct LevelNumeral: View {
    let level: Double?
    @ScaledMetric private var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(level: Double?, size: CGFloat = 56) {
        self.level = level
        _size = ScaledMetric(wrappedValue: size, relativeTo: .largeTitle)
    }

    var body: some View {
        Text(Format.level(level))
            .font(.display(size: size))
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText(value: level ?? 0))
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
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(isReliable ? AnyShapeStyle(Theme.lime) : AnyShapeStyle(Theme.inset), in: .capsule)
            .foregroundStyle(isReliable ? Theme.ink : Color.secondary)
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
            .fixedSize()
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

/// Rating reliability as the racket holes of the icon: the more of the six
/// are filled, the more the level can be trusted. The same mark as on the
/// player card of the Home.
struct ReliabilityMark: View {
    let reliability: Int
    @ScaledMetric private var size: CGFloat

    init(reliability: Int, size: CGFloat = 44) {
        self.reliability = reliability
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        PerforationGrid(filled: PerforationGrid.holes(for: reliability), dot: size * 0.23, gap: size * 0.12,
                        color: Theme.accent)
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
    @ScaledMetric private var size: CGFloat
    let deleted: Bool

    init(id: UUID, name: String, path: String?, size: CGFloat = 40, deleted: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.deleted = deleted
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

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
                    .font(.display(size: size * 0.34, weight: .bold))
                    .foregroundStyle(.primary)
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

/// Avatar access follows live profile visibility; old public-cache entries
/// are removed before the first protected fetch.
enum AvatarLoader {
    /// Emptied on sign-out: the next account must not inherit the photos the
    /// previous one browsed.
    static let cache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024)

    static let invalidateLegacyCache: Void = cache.removeAllCachedResponses()

    static func url(for path: String) -> URL? {
        AppEnvironment.apiBaseURL.appending(path: "v1/avatars/\(path)")
    }

    static func requestPath(for url: URL, baseURL: URL) -> String? {
        guard url.scheme == baseURL.scheme, url.host() == baseURL.host(), url.port == baseURL.port,
              url.query() == nil, url.fragment() == nil else { return nil }
        let prefix = baseURL.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relative: String
        if prefix.isEmpty { relative = path }
        else {
            guard path.hasPrefix(prefix + "/") else { return nil }
            relative = String(path.dropFirst(prefix.count + 1))
        }
        guard relative.hasPrefix("v1/avatars/") else { return nil }
        return relative
    }
}

struct RemoteImage<Placeholder: View>: View {
    @Environment(AppModel.self) private var app
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
        .task(id: "\(url.absoluteString):\(app.dataRevision)") {
            _ = AvatarLoader.invalidateLegacyCache
            image = nil
            loadedURL = nil
            guard let path = AvatarLoader.requestPath(for: url, baseURL: app.api.baseURL) else { return }
            if let data = try? await app.api.data(.get(path)), !Task.isCancelled, let loaded = UIImage(data: data) {
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
            Text(subtitle ?? defaultSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(textLineLimit)
                .fixedSize(horizontal: false, vertical: textLineLimit == nil)
            if !card.deleted, !facts.isEmpty {
                Text(facts)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(textLineLimit)
                    .fixedSize(horizontal: false, vertical: textLineLimit == nil)
            }
        }
    }

    /// What helps choose a partner: how settled the rating is and the side played.
    private var facts: String {
        var parts: [String] = []
        if let reliability = card.reliability { parts.append("надёжность \(reliability)%") }
        if let side = card.preferredSide {
            parts.append(side == .both ? "обе стороны" : Narratives.sideShort(side).lowercased())
        }
        return parts.joined(separator: ", ").capitalizedFirst
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
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: .capsule)
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
        PerforationLoader()
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
                .buttonStyle(.padelPrimary)
                .fixedSize()
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

/// Small items in rows that wrap, like words in a line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1] = (last.indices + [index], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}

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
