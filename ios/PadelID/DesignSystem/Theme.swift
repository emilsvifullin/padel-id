import SwiftUI

/// Padel ID visual language: system typography and materials, a court-blue
/// accent and a restrained ball-yellow highlight used only for the level.
enum Theme {
    static let accent = Color.accentColor
    static let ball = Color("Ball")
    /// Semantic colours (asset catalog): darker in Light mode so that text
    /// in them keeps a 4.5:1 contrast, the vivid system hues in Dark mode.
    static let positive = Color("Positive")
    static let negative = Color("Negative")
    static let attention = Color("Attention")

    static let cornerRadius: CGFloat = 22
    static let smallCornerRadius: CGFloat = 14
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
