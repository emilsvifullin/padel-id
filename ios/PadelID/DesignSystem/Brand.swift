import SwiftUI

// Shapes and surfaces taken from the app icon.

/// The app's own glyphs, drawn by `scripts/ios/make-symbols.py`: the system
/// set only has a tennis racket and a pitch with a centre circle.
enum PadelSymbol {
    /// A padel racket with the six holes of the app icon: matches and games.
    static let racket = "padel.racket"
    /// A padel court from above: clubs and courts.
    static let court = "padel.court"
}

extension Image {
    /// A symbol by name: the app's own glyphs first, then the system set.
    init(symbol name: String) {
        self = name.hasPrefix("padel.") ? Image(name) : Image(systemName: name)
    }
}

/// The racket face of the app icon: two rows of three holes. `filled` of the
/// six are solid, the rest are rings, so a level reads without colour.
struct PerforationGrid: View {
    var filled = 6
    var dot: CGFloat = 8
    var gap: CGFloat = 5
    var color: Color = Theme.ink
    /// Fills the holes one after another the first time the grid appears.
    var fillsIn = false
    @State private var shown = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let visible = fillsIn && !reduceMotion ? min(shown, filled) : filled
        return VStack(spacing: gap) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { column in
                        let index = row * 3 + column
                        Circle()
                            .fill(index < visible ? color : .clear)
                            .strokeBorder(color.opacity(index < visible ? 0 : 0.35), lineWidth: max(1, dot * 0.16))
                            .frame(width: dot, height: dot)
                    }
                }
            }
        }
        .accessibilityHidden(true)
        .task(id: filled) {
            guard fillsIn, !reduceMotion else { return }
            for count in shown...max(shown, filled) {
                withAnimation(Motion.quick) { shown = count }
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }

    /// Six holes for a 0–100 value; any non-zero value fills at least one.
    static func holes(for percent: Int) -> Int {
        guard percent > 0 else { return 0 }
        return min(6, max(1, Int((Double(percent) / 100 * 6).rounded())))
    }
}

/// The swell along the bottom of the app icon.
nonisolated struct IconSwell: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.94))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.62),
                      control1: CGPoint(x: rect.minX + rect.width * 0.34, y: rect.minY + rect.height * 0.70),
                      control2: CGPoint(x: rect.minX + rect.width * 0.62, y: rect.minY + rect.height * 0.56))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The lime of the default app icon. Content on it is always `Theme.ink`.
struct LimeSurface: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.limePale, Theme.lime, Theme.lime],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            IconSwell().fill(Theme.limeDeep.opacity(0.7))
        }
        .accessibilityHidden(true)
    }
}

/// The graphite of the alternate app icon: ink crossed by one lighter band.
struct InkSurface: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.inkRaised, Theme.ink], startPoint: .topLeading, endPoint: .bottomTrailing)
            IconSwell().fill(Theme.limeDeep.opacity(0.10))
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// Ink content on the icon's lime, in both themes.
    func limeCard(cornerRadius: CGFloat = Theme.cornerRadius) -> some View {
        foregroundStyle(Theme.ink)
            .background { LimeSurface().clipShape(.rect(cornerRadius: cornerRadius, style: .continuous)) }
            .environment(\.colorScheme, .light)
    }

    /// Light content on the icon's graphite, in both themes.
    func inkCard(cornerRadius: CGFloat = Theme.cornerRadius) -> some View {
        foregroundStyle(.white)
            .background { InkSurface().clipShape(.rect(cornerRadius: cornerRadius, style: .continuous)) }
            .environment(\.colorScheme, .dark)
    }
}

// MARK: - Loading

/// The racket holes lighting up in turn while something loads.
struct PerforationLoader: View {
    var dot: CGFloat = 9
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                ProgressView()
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate * 1.6
                    VStack(spacing: dot * 0.6) {
                        ForEach(0..<2, id: \.self) { row in
                            HStack(spacing: dot * 0.6) {
                                ForEach(0..<3, id: \.self) { column in
                                    let offset = Double(row * 3 + column) / 6
                                    let wave = (sin((phase - offset) * 2 * .pi) + 1) / 2
                                    Circle()
                                        .fill(Theme.accent)
                                        .opacity(0.22 + 0.78 * wave)
                                        .frame(width: dot, height: dot)
                                }
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Загрузка")
    }
}

// MARK: - Chips

/// A filter or option that is either chosen or not. Chosen is ink on lime.
struct PadelChip: View {
    let title: String
    var symbol: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(symbol: symbol).imageScale(.small) }
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .foregroundStyle(isSelected ? Theme.ink : Color.primary)
            .background(isSelected ? AnyShapeStyle(Theme.lime) : AnyShapeStyle(Theme.surface), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.padelCard)
        .padelAnimation(Motion.quick, value: isSelected)
        .sensoryFeedback(.selection, trigger: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A symbol on a round tinted plate, the leading mark of rows and tiles.
struct SymbolPlate: View {
    let symbol: String
    var tint: Color = Theme.accent
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 40

    var body: some View {
        Image(symbol: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: .circle)
            .accessibilityHidden(true)
    }
}

/// The trailing hint of a row that opens another screen.
struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

// MARK: - Empty states

/// Nothing here yet: what this place is for, and the one thing to do about it.
struct PadelEmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    init(symbol: String, title: String, message: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 14) {
            SymbolPlate(symbol: symbol)
            VStack(spacing: 6) {
                Text(title).font(.headline).multilineTextAlignment(.center)
                Text(message)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
    }
}

// MARK: - Composer

/// The message field that floats above a chat or a thread of comments.
struct ComposerBar: View {
    let placeholder: String
    @Binding var text: String
    var isLocked = false
    let canSend: Bool
    var draftIdentifier = "composer.draft"
    var sendIdentifier = "composer.send"
    let send: () -> Void

    var body: some View {
        GlassEffectContainer {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .frame(minHeight: 44)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
                    .disabled(isLocked)
                    .accessibilityIdentifier(draftIdentifier)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.headline.weight(.bold))
                        .frame(width: 28, height: 30)
                }
                .padelGlassProminent()
                .buttonBorderShape(.circle)
                .disabled(!canSend)
                .accessibilityLabel("Отправить")
                .accessibilityIdentifier(sendIdentifier)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
