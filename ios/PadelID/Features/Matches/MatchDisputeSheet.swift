import SwiftUI

/// Dispute form: a reason and an optional short comment for the match creator.
struct MatchDisputeSheet: View {
    let match: MatchDetail
    let onFinish: (MatchActionResult) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var reason: DisputeReason?
    @State private var comment = ""
    @State private var isSubmitting = false
    @State private var error: APIError?

    init(match: MatchDetail, onFinish: @escaping (MatchActionResult) -> Void) {
        self.match = match
        self.onFinish = onFinish
    }

    private var limit: Int { MatchActions.disputeCommentLimit }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(DisputeReason.allCases, id: \.self) { option in
                        reasonRow(option)
                    }
                } header: {
                    Text("Что не так?")
                } footer: {
                    Text("Автор матча увидит причину и сможет исправить счёт или состав. Пока есть возражение, матч не учитывается.")
                }

                Section {
                    TextField("Например, какой был счёт", text: $comment, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityLabel("Комментарий")
                } header: {
                    Text("Комментарий — необязательно")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Spacer()
                            Text("\(MatchActions.commentLength(comment)) из \(limit)")
                                .monospacedDigit()
                                .foregroundStyle(MatchActions.commentLength(comment) >= limit ? Theme.attention : Color.secondary)
                        }
                        if !app.isOnline {
                            Text("Нет подключения: ответ сохранится и отправится автоматически.")
                        }
                        if let error {
                            Text(error.message)
                                .foregroundStyle(Theme.negative)
                        }
                    }
                }
            }
            .disabled(isSubmitting)
            .navigationTitle("Оспорить результат")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("Отправить") {
                            submit()
                        }
                        .disabled(reason == nil)
                    }
                }
            }
            .onChange(of: comment) { _, newValue in
                if MatchActions.commentLength(newValue) > limit {
                    comment = MatchActions.clampComment(newValue)
                }
            }
            .sensoryFeedback(.selection, trigger: reason)
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    private func reasonRow(_ option: DisputeReason) -> some View {
        Button {
            reason = option
        } label: {
            HStack(spacing: 12) {
                Text(Narratives.disputeReason(option))
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if reason == option {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .accessibilityAddTraits(reason == option ? .isSelected : [])
    }

    private func submit() {
        guard let selected = reason, !isSubmitting else { return }
        isSubmitting = true
        error = nil
        Task {
            let result = await MatchActions.dispute(match, reason: selected, comment: comment, app: app)
            isSubmitting = false
            if case .failed(let failure) = result {
                error = failure
                Announce.post(failure.message)
            } else {
                onFinish(result)
                dismiss()
            }
        }
    }
}
