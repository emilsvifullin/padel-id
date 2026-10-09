import SwiftUI

/// The starting level calculated from the onboarding answers, shown once
/// before the user enters the app.
struct OnboardingResultView: View {
    @Environment(AppModel.self) private var app
    private let me: Me

    init(me: Me) {
        self.me = me
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                if let rating = me.rating {
                    levelHero(rating)
                    reliabilityBlock(rating)
                } else {
                    profileReady
                }
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.top, 32)
            .padding(.bottom, 24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(.systemGroupedBackground))
        .safeAreaBar(edge: .bottom) {
            OnboardingActionBar(title: "Открыть Padel ID", identifier: "onboarding.open") {
                app.apply(me: me)
            }
        }
    }

    // MARK: Blocks

    private func levelHero(_ rating: RatingSummary) -> some View {
        let band = LevelBand(level: rating.mu)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Профиль готов")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text("Ваш стартовый уровень")
                    .font(.title.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }

            SectionContainer(padding: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    LevelNumeral(level: rating.mu, size: 72)
                    OnboardingLevelScale(level: rating.mu)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(band.title)
                            .font(.headline)
                        Text(band.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func reliabilityBlock(_ rating: RatingSummary) -> some View {
        SectionContainer(padding: 20) {
            HStack(alignment: .top, spacing: 16) {
                ReliabilityRing(reliability: rating.reliability, size: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(rating.provisional ? "Предварительный рейтинг" : "Надёжность рейтинга")
                        .font(.headline)
                    Text(reliabilityText(rating))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var profileReady: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Профиль готов")
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Уровень появится после первого подтверждённого рейтингового матча.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reliabilityText(_ rating: RatingSummary) -> String {
        let reliability = "\(rating.reliability)%"
        if rating.provisional {
            return "Уровень рассчитан по вашим ответам, поэтому надёжность пока \(reliability). "
                + "Каждый подтверждённый рейтинговый матч уточняет оценку с учётом партнёра, соперников и счёта: "
                + "первые матчи меняют уровень сильнее всего, а надёжность быстро растёт."
        }
        return "Надёжность — \(reliability). Дальше уровень меняется после каждого подтверждённого "
            + "рейтингового матча с учётом партнёра, соперников и счёта."
    }
}

/// The level's position on the 0–7 scale.
private struct OnboardingLevelScale: View {
    let level: Double

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let fraction = CGFloat(min(1, max(0, level / 7)))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.tertiarySystemFill))
                    Capsule()
                        .fill(Theme.ball)
                        .frame(width: max(8, proxy.size.width * fraction))
                }
            }
            .frame(height: 8)
            HStack {
                Text("0")
                Spacer()
                Text("7")
            }
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}
