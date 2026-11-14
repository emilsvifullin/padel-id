import SwiftUI

struct HomeView: View {
    @Namespace private var appearanceTransition

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero

                NavigationLink {
                    AppearanceSettingsView()
                        .navigationTransition(.zoom(sourceID: "appearance", in: appearanceTransition))
                } label: {
                    SectionContainer {
                        HStack(spacing: 14) {
                            SymbolPlate(symbol: "paintpalette")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Оформление").font(.headline)
                                Text("Тема и иконка").font(.subheadline).foregroundStyle(.secondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Chevron()
                        }
                    }
                }
                .buttonStyle(.padelCard)
                .foregroundStyle(.primary)
                .tappableCard()
                .matchedTransitionSource(id: "appearance", in: appearanceTransition)
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .closeToBar()
        .padelCanvas()
        .navigationTitle("Главная")
        .mainTabTitle()
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                Image("IconPreview-lime")
                    .resizable()
                    .frame(width: 52, height: 52)
                    .clipShape(.rect(cornerRadius: 13))
                    .accessibilityHidden(true)

                Spacer()
                PerforationGrid(dot: 16, gap: 8, color: Theme.ink.opacity(0.9))
            }

            Text("Padel ID")
                .font(.display(.largeTitle, weight: .heavy))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .limeCard()
    }
}
