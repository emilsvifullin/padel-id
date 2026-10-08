import SwiftUI

/// A valid result of a regular set from team 1's perspective.
nonisolated struct EditorScoreOption: Hashable, Identifiable, Sendable {
    let t1: Int
    let t2: Int

    var id: String { "\(t1)-\(t2)" }
    var team1Won: Bool { t1 > t2 }
    /// 7:6 or 6:7 — the set was decided by a tie-break.
    var isTiebreakSet: Bool { max(t1, t2) == 7 && min(t1, t2) == 6 }
}

/// Score entry for one regular set: every valid result as a large button,
/// plus optional tie-break points for 7:6 and 6:7.
struct EditorScoreGrid: View {
    let setNumber: Int
    let initial: SetScore?
    let onCommit: (SetScore?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title3) private var minimumButtonWidth: CGFloat = 76

    @State private var selection: EditorScoreOption?
    @State private var tiebreakEnabled: Bool
    @State private var tiebreak1: Int
    @State private var tiebreak2: Int
    @State private var detent: PresentationDetent = .medium
    @State private var selectionCount = 0

    private static let options: [EditorScoreOption] = ScoreRules.regularSetResults.map { result in
        EditorScoreOption(t1: result.0, t2: result.1)
    }
    private static let tiebreakAnchor = "score.tiebreak.section"

    init(setNumber: Int, initial: SetScore?, onCommit: @escaping (SetScore?) -> Void) {
        self.setNumber = setNumber
        self.initial = initial
        self.onCommit = onCommit
        _selection = State(initialValue: initial.map { EditorScoreOption(t1: $0.t1, t2: $0.t2) })
        if let initial, let tb1 = initial.tb1, let tb2 = initial.tb2 {
            _tiebreakEnabled = State(initialValue: true)
            _tiebreak1 = State(initialValue: tb1)
            _tiebreak2 = State(initialValue: tb2)
        } else {
            let team1Won = (initial?.t1 ?? 1) > (initial?.t2 ?? 0)
            _tiebreakEnabled = State(initialValue: false)
            _tiebreak1 = State(initialValue: team1Won ? 7 : 5)
            _tiebreak2 = State(initialValue: team1Won ? 5 : 7)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        optionGroup("Победа вашей пары", options: Self.options.filter(\.team1Won))
                        optionGroup("Победа соперников", options: Self.options.filter { !$0.team1Won })
                        if let selection, selection.isTiebreakSet {
                            tiebreakEditor(for: selection)
                                .id(Self.tiebreakAnchor)
                        }
                        if initial != nil {
                            clearButton
                        }
                    }
                    .padding(.horizontal, Theme.horizontalPadding)
                    .padding(.vertical, 16)
                }
                .onChange(of: selection) { _, newValue in
                    guard newValue?.isTiebreakSet == true else { return }
                    detent = .large
                    withAnimation(.smooth) {
                        proxy.scrollTo(Self.tiebreakAnchor, anchor: .bottom)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Сет \(setNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                if let selection, selection.isTiebreakSet {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") { commitTiebreakSet(selection) }
                            .disabled(!isTiebreakValid(selection))
                            .accessibilityIdentifier("score.done")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.selection, trigger: selectionCount)
        .onAppear {
            if dynamicTypeSize.isAccessibilitySize || selection?.isTiebreakSet == true {
                detent = .large
            }
        }
    }

    // MARK: Options

    private func optionGroup(_ title: String, options: [EditorScoreOption]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumButtonWidth), spacing: 10)], spacing: 10) {
                ForEach(options) { option in
                    optionButton(option)
                }
            }
        }
    }

    private func optionButton(_ option: EditorScoreOption) -> some View {
        let isSelected = selection == option
        return Button {
            choose(option)
        } label: {
            Text(verbatim: "\(option.t1) : \(option.t2)")
                .font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonBorderShape(.roundedRectangle(radius: Theme.smallCornerRadius))
        .controlSize(.large)
        .modifier(EditorScoreButtonStyle(isSelected: isSelected))
        .accessibilityLabel(Text(verbatim: "\(option.t1):\(option.t2)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("score.\(option.t1)-\(option.t2)")
    }

    // MARK: Tie-break

    private func tiebreakEditor(for option: EditorScoreOption) -> some View {
        SectionContainer {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Указать счёт тай-брейка", isOn: $tiebreakEnabled.animation(.smooth))
                    .accessibilityIdentifier("score.tiebreak")
                if tiebreakEnabled {
                    Stepper(value: $tiebreak1, in: 0...40) {
                        pointsLabel("Ваша пара", value: tiebreak1)
                    }
                    .accessibilityIdentifier("score.tb1")
                    Stepper(value: $tiebreak2, in: 0...40) {
                        pointsLabel("Соперники", value: tiebreak2)
                    }
                    .accessibilityIdentifier("score.tb2")
                }
                Text(tiebreakHint(for: option))
                    .font(.footnote)
                    .foregroundStyle(isTiebreakValid(option) ? Color.secondary : Theme.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pointsLabel(_ title: String, value: Int) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Text(verbatim: "\(value)")
                .font(.body.weight(.semibold))
                .monospacedDigit()
        }
    }

    private func tiebreakHint(for option: EditorScoreOption) -> String {
        if !tiebreakEnabled {
            return "Необязательно: укажите очки, если помните счёт тай-брейка."
        }
        if isTiebreakValid(option) {
            return "Тай-брейк играется до 7 очков, а после 6:6 — до разницы в 2 очка."
        }
        return "Такой счёт тай-брейка невозможен: победитель набирает 7 очков, а после 6:6 — на 2 очка больше соперника."
    }

    private func isTiebreakValid(_ option: EditorScoreOption) -> Bool {
        guard tiebreakEnabled else { return true }
        return option.team1Won
            ? ScoreRules.isValidTiebreak(winnerPoints: tiebreak1, loserPoints: tiebreak2)
            : ScoreRules.isValidTiebreak(winnerPoints: tiebreak2, loserPoints: tiebreak1)
    }

    private var clearButton: some View {
        Button(role: .destructive) {
            onCommit(nil)
            dismiss()
        } label: {
            Text("Очистить счёт сета")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityIdentifier("score.clear")
    }

    // MARK: Actions

    private func choose(_ option: EditorScoreOption) {
        selectionCount += 1
        guard option.isTiebreakSet else {
            onCommit(SetScore(t1: option.t1, t2: option.t2))
            dismiss()
            return
        }
        guard selection != option else { return }
        selection = option
        tiebreak1 = option.team1Won ? 7 : 5
        tiebreak2 = option.team1Won ? 5 : 7
    }

    private func commitTiebreakSet(_ option: EditorScoreOption) {
        var set = SetScore(t1: option.t1, t2: option.t2)
        if tiebreakEnabled && isTiebreakValid(option) {
            set.tb1 = tiebreak1
            set.tb2 = tiebreak2
        }
        onCommit(set)
        dismiss()
    }
}

/// Selected result: prominent; others: bordered.
private struct EditorScoreButtonStyle: ViewModifier {
    let isSelected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
