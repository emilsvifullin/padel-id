import SwiftUI

/// Confirmed match history of any player, newest first, loaded page by page.
struct PlayerMatchesView: View {
    let playerId: UUID

    @Environment(AppModel.self) private var app
    @State private var pager: MatchesListPager

    init(playerId: UUID) {
        self.playerId = playerId
        _pager = State(initialValue: MatchesListPager.player(playerId))
    }

    var body: some View {
        Group {
            if pager.hasValue {
                list
            } else if let error = pager.firstPage.error {
                ErrorStateView(error: error) {
                    Task { await pager.load(using: app) }
                }
            } else {
                LoadingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Матчи")
        .task(id: app.dataRevision) {
            await pager.load(using: app)
        }
    }

    private var list: some View {
        List {
            if pager.firstPage.isStale && pager.firstPage.error?.isNetwork == true {
                OfflineBanner()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            let items = pager.items
            if !items.isEmpty {
                Section {
                    ForEach(items) { item in
                        NavigationLink(value: Route.match(item.id)) {
                            MatchRowView(item: item, perspectiveTeam: item.subjectTeam)
                        }
                        .accessibilityIdentifier("matchRow")
                    }
                    if pager.canLoadMore {
                        loadMoreRow
                    }
                } header: {
                    Text("Подтверждённые матчи")
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await pager.load(using: app)
        }
        .overlay {
            if pager.items.isEmpty {
                ContentUnavailableView(
                    "Матчей пока нет",
                    systemImage: "sportscourt",
                    description: Text("Здесь появятся матчи, подтверждённые всеми участниками."))
            }
        }
    }

    @ViewBuilder
    private var loadMoreRow: some View {
        if let error = pager.loadMoreError {
            VStack(alignment: .leading, spacing: 8) {
                Label(error.message, systemImage: error.isNetwork ? "wifi.slash" : "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Повторить") {
                    Task { await pager.loadMore(using: app) }
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
            }
            .padding(.vertical, 4)
        } else {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(minHeight: 44)
            .accessibilityLabel("Загрузка")
            .task(id: pager.nextBefore) {
                await pager.loadMore(using: app)
            }
        }
    }
}
