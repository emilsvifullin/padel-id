import SwiftUI

/// Search filters of the players tab. Changes apply with "Готово".
struct PlayersFilterSheet: View {
    let myCity: NamedRef?
    let onApply: (PlayersFilter) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: PlayersFilter
    @State private var city: NamedRef?

    init(filter: PlayersFilter, myCity: NamedRef?, onApply: @escaping (PlayersFilter) -> Void) {
        self.myCity = myCity
        self.onApply = onApply
        _draft = State(initialValue: filter)
        _city = State(initialValue: filter.cityScope.resolve(myCity: myCity))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        CityPickerView(selection: $city)
                    } label: {
                        LabeledContent("Город", value: city?.name ?? "Все города")
                    }
                    if city != nil {
                        Button("Искать во всех городах") {
                            city = nil
                        }
                    }
                }

                Section {
                    PlayersLevelSlider(title: "От", accessibilityTitle: "Уровень от", value: $draft.minLevel)
                    PlayersLevelSlider(title: "До", accessibilityTitle: "Уровень до", value: $draft.maxLevel)
                } header: {
                    Text("Уровень")
                }

                Section {
                    Picker("Сторона корта", selection: $draft.side) {
                        ForEach(PlayersSideFilter.allCases) { side in
                            Text(side.title).tag(side)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Сторона корта")
                } footer: {
                    Text("Игроки, которые играют на обеих сторонах, подходят под любой вариант.")
                }

                Section {
                    Toggle("Только надёжный рейтинг", isOn: $draft.reliableOnly)
                    Toggle("Только тренеры", isOn: $draft.coachesOnly)
                } footer: {
                    Text(verbatim: "Надёжный рейтинг подтверждён рейтинговыми матчами: надёжность от 50%. Тренеры проверены Padel ID.")
                }

                Section {
                    Button("Сбросить фильтры") {
                        draft = PlayersFilter()
                        city = myCity
                    }
                    .disabled(isDefault)
                }
            }
            .navigationTitle("Фильтры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        onApply(result)
                        dismiss()
                    }
                }
            }
            .onChange(of: draft.minLevel) { _, newValue in
                if draft.maxLevel < newValue { draft.maxLevel = newValue }
            }
            .onChange(of: draft.maxLevel) { _, newValue in
                if draft.minLevel > newValue { draft.minLevel = newValue }
            }
            .sensoryFeedback(.selection, trigger: draft.minLevel)
            .sensoryFeedback(.selection, trigger: draft.maxLevel)
            .sensoryFeedback(.selection, trigger: draft.side)
        }
    }

    private var result: PlayersFilter {
        var value = draft
        value.cityScope = PlayersCityScope(selection: city, myCity: myCity)
        return value
    }

    private var isDefault: Bool {
        result.activeCount(myCity: myCity) == 0
    }
}

/// One bound of the level range: 0–7 in steps of 0.5.
private struct PlayersLevelSlider: View {
    let title: String
    let accessibilityTitle: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                Text(Format.level(value) + " · " + LevelBand(level: value).title)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityHidden(true)
            Slider(value: $value, in: PlayersFilter.levelBounds, step: 0.5)
                .accessibilityLabel(accessibilityTitle)
                .accessibilityValue(Format.level(value) + ", " + LevelBand(level: value).title)
        }
        .padding(.vertical, 4)
    }
}
