import SwiftUI
import UIKit

/// Padel ID visual language.
///
/// Neutrals are the system's own grouped colours, so lists, forms, sheets and
/// bars stay native in both themes. The brand comes from the app icon: a lime
/// surface carrying ink, the racket's perforation dots, and expanded display
/// type for titles and numerals. Liquid Glass belongs to navigation and to
/// controls that float above content; content itself sits on solid surfaces.
enum Theme {
    // MARK: Brand

    /// Text and symbols on neutral surfaces: deep court green in Light, lime
    /// in Dark. Never a fill behind white text — use `lime` with `ink`.
    static let accent = Color("AccentColor")
    static let ball = Color("Ball")
    /// The icon's lime. Always carries `ink`, in both themes.
    static let lime = Color(red: 0.824, green: 0.980, blue: 0.341)
    static let limePale = Color(red: 0.925, green: 1.0, blue: 0.620)
    static let limeDeep = Color(red: 0.553, green: 0.898, blue: 0.357)
    /// The icon's glyph colour.
    static let ink = Color(red: 0.027, green: 0.067, blue: 0.059)
    static let inkRaised = Color(red: 0.090, green: 0.165, blue: 0.145)
    /// Supporting text on lime: still ink, a step quieter.
    static let inkSoft = ink.opacity(0.86)

    // MARK: Neutrals

    static let canvas = Color(.systemGroupedBackground)
    static let surface = Color(.secondarySystemGroupedBackground)
    /// A tile nested inside a surface.
    static let inset = Color(.tertiarySystemFill)
    static let hairline = Color(.separator).opacity(0.5)

    // MARK: Semantic

    /// Asset-catalog colours: darker in Light so text keeps 4.5:1, the vivid
    /// system hues in Dark.
    static let positive = Color("Positive")
    static let negative = Color("Negative")
    static let attention = Color("Attention")
    static let supportingText = Color("SupportingText")

    // MARK: Metrics

    static let cornerRadius: CGFloat = 26
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
        let palette: [Color] = [.green, .mint, .teal, .cyan, .blue, .indigo, .orange, .yellow, .brown, .pink]
        let hash = id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[hash % palette.count]
    }

    /// Expanded SF Pro in large navigation titles. Inline titles keep the
    /// system face: between two bar buttons the wider one truncates. Fonts
    /// only — bar backgrounds stay the system's glass.
    @MainActor
    static func applyNavigationTypography() {
        let font = UIFontMetrics(forTextStyle: .largeTitle)
            .scaledFont(for: .systemFont(ofSize: 32, weight: .bold, width: .expanded), maximumPointSize: 44)
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: font]
    }
}

// MARK: - Type

extension Font {
    /// Expanded SF Pro: the scoreboard voice for titles and numerals.
    static func display(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .system(style, weight: weight).width(.expanded)
    }

    static func display(size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight).width(.expanded)
    }
}

// MARK: - Motion

/// One vocabulary of movement. Every use goes through `padelAnimation` or
/// `Motion.perform`, which drop the movement under Reduce Motion.
enum Motion {
    /// A control answering a touch: selection, toggles, chips.
    static let quick = Animation.snappy(duration: 0.24)
    /// Content changing in place: lists, numbers, expanding rows.
    static let standard = Animation.smooth(duration: 0.34)
    /// One element taking the stage: a sheet's content, a confirmation.
    static let emphasized = Animation.spring(response: 0.46, dampingFraction: 0.82)

    @MainActor
    static func perform(_ animation: Animation = standard, _ body: () -> Void) {
        if UIAccessibility.isReduceMotionEnabled { body() } else { withAnimation(animation, body) }
    }
}

private struct ReduceMotionAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

private struct PressFeedback: ViewModifier {
    let isPressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && !reduceMotion ? 0.975 : 1)
            .opacity(isPressed ? 0.86 : 1)
            .animation(reduceMotion ? nil : Motion.quick, value: isPressed)
    }
}

/// A short task opens at half height; at accessibility text sizes its form no
/// longer fits there, so it opens full height.
private struct CompactSheet: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content
            .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
            .presentationDragIndicator(.visible)
    }
}

extension View {
    func compactSheet() -> some View { modifier(CompactSheet()) }

    func padelAnimation<Value: Equatable>(_ animation: Animation = Motion.standard, value: Value) -> some View {
        modifier(ReduceMotionAnimation(animation: animation, value: value))
    }

    /// Card-like navigation affordance: whole area tappable.
    func tappableCard() -> some View {
        contentShape(.rect(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    /// The canvas behind a scrolling screen; lists and forms keep their rows.
    func padelCanvas() -> some View {
        background(Theme.canvas.ignoresSafeArea())
    }
}

// MARK: - Surfaces

/// Grouped content container used for primary sections.
struct SectionContainer<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.cornerRadius, style: .continuous))
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
                .font(.display(.title3, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Buttons

/// The main action of a screen when it sits in content: ink on lime, as on
/// the app icon. Bars that float above content use `padelGlassProminent`.
struct PadelPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .foregroundStyle(isEnabled ? Theme.ink : Color.secondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(isEnabled ? AnyShapeStyle(Theme.lime) : AnyShapeStyle(Theme.inset), in: .capsule)
            .contentShape(.capsule)
            .modifier(PressFeedback(isPressed: configuration.isPressed))
    }
}

/// A supporting action next to a primary one.
struct PadelSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.inset, in: .capsule)
            .contentShape(.capsule)
            .modifier(PressFeedback(isPressed: configuration.isPressed))
    }
}

/// A compact main action inside a row, a card or an inline form.
struct PadelProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isEnabled ? Theme.ink : Color.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(minHeight: 40)
            .background(isEnabled ? AnyShapeStyle(Theme.lime) : AnyShapeStyle(Theme.inset), in: .capsule)
            .contentShape(.capsule)
            .modifier(PressFeedback(isPressed: configuration.isPressed))
    }
}

/// A tappable row or card that only answers the touch.
struct PadelCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(PressFeedback(isPressed: configuration.isPressed))
    }
}

extension ButtonStyle where Self == PadelPrimaryButtonStyle {
    static var padelPrimary: PadelPrimaryButtonStyle { PadelPrimaryButtonStyle() }
}

extension ButtonStyle where Self == PadelProminentButtonStyle {
    static var padelProminent: PadelProminentButtonStyle { PadelProminentButtonStyle() }
}

extension ButtonStyle where Self == PadelSecondaryButtonStyle {
    static var padelSecondary: PadelSecondaryButtonStyle { PadelSecondaryButtonStyle() }
}

extension ButtonStyle where Self == PadelCardButtonStyle {
    static var padelCard: PadelCardButtonStyle { PadelCardButtonStyle() }
}

extension View {
    /// A prominent glass button in a floating bar: lime glass, ink label.
    func padelGlassProminent() -> some View {
        buttonStyle(.glassProminent).tint(Theme.lime).foregroundStyle(Theme.ink)
    }
}
