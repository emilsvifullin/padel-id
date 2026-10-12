import SwiftUI

/// Padel ID visual language: quiet grouped surfaces, court-green accents and
/// the lime ball colour. System controls keep their native material rendering.
enum Theme {
    static let accent = Color("AccentColor")
    static let ball = Color("Ball")
    static let background = Color("LaunchBackground")
    static let ink = Color(red: 0.035, green: 0.085, blue: 0.095)
    static let lime = Color(red: 0.82, green: 0.98, blue: 0.34)
    /// Semantic colours (asset catalog): darker in Light mode so that text
    /// in them keeps a 4.5:1 contrast, the vivid system hues in Dark mode.
    static let positive = Color("Positive")
    static let negative = Color("Negative")
    static let attention = Color("Attention")
    /// Opaque supporting text stays readable on the custom Home background
    /// as well as grouped cards, including at small Dynamic Type sizes.
    static let supportingText = Color("SupportingText")

    static let cornerRadius: CGFloat = 24
    static let smallCornerRadius: CGFloat = 16
    static let horizontalPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 28

    static func deltaColor(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        if value > 0.0005 { return positive }
        if value < -0.0005 { return negative }
        return .secondary
    }

    static func sentimentColor(_ sentiment: Sentiment) -> Color {
        switch sentiment {
        case .positive: positive
        case .neutral: accent
        case .attention: attention
        }
    }

    /// Deterministic tint for monogram avatars.
    static func monogramTint(for id: UUID) -> Color {
        let palette: [Color] = [.blue, .indigo, .teal, .mint, .cyan, .purple, .orange, .pink, .green, .brown]
        let hash = id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[hash % palette.count]
    }
}

/// Grouped content container used for primary sections.
struct SectionContainer<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.045), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

/// A solid, high-contrast action surface. Glass remains reserved for native
/// navigation and transient controls rather than every content card.
struct PadelPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Theme.lime.opacity(configuration.isPressed ? 0.8 : 1),
                        in: .rect(cornerRadius: Theme.smallCornerRadius, style: .continuous))
    }
}

/// Abstract court markings are decorative; no stock photo or invented club
/// is used for the player's identity card.
nonisolated struct CourtMarkings: Shape {
    func path(in rect: CGRect) -> Path {
        let court = rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.12)
        var path = Path()
        path.addRect(court)
        path.move(to: CGPoint(x: court.midX, y: court.minY))
        path.addLine(to: CGPoint(x: court.midX, y: court.maxY))
        for fraction in [0.25, 0.75] {
            let y = court.minY + court.height * fraction
            path.move(to: CGPoint(x: court.minX, y: y))
            path.addLine(to: CGPoint(x: court.maxX, y: y))
        }
        path.move(to: CGPoint(x: court.minX, y: court.midY))
        path.addLine(to: CGPoint(x: court.maxX, y: court.midY))
        return path
    }
}

/// Section header with an optional trailing action.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 4)
    }
}

extension View {
    /// Card-like navigation affordance: whole area tappable, chevron hint.
    func tappableCard() -> some View {
        contentShape(.rect(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}
