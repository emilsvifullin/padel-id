import SwiftUI

/// All analytic insights of the current user.
struct InsightsView: View {
    @Environment(AppModel.self) private var app
    @State private var home = Resource<HomeResponse>(cacheKey: CacheKey.home) { .get("v1/home") }

    var body: some View {
        ZStack {
            if let value = home.value {
                content(value)
            } else if let error = home.error {
                ErrorStateView(error: error) {
                    Task { await home.load(using: app) }
                }
            } else {
                LoadingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Анализ")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: app.dataRevision) { await home.load(using: app) }
    }

    @ViewBuilder
    private func content(_ value: HomeResponse) -> some View {
        let insights = value.insights.compactMap { Narratives.insight($0) }
        if insights.isEmpty {
            ContentUnavailableView {
                Label("Пока нет выводов", systemImage: "sparkles")
            } description: {
                Text("Анализ появится после нескольких подтверждённых матчей")
            }
        } else {
            List {
                if home.isStale, let error = home.error {
                    Section {
                        StaleDataBanner(error: error)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                ForEach(Array(insights.enumerated()), id: \.offset) { _, insight in
                    Section {
                        HomeInsightRow(insight: insight)
                            .padding(.vertical, 6)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .refreshable { [home = self.home, app = self.app] in
                await home.load(using: app)
            }
        }
    }
}
