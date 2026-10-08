import SwiftUI

/// Shows a freshly issued recovery key exactly once and asks the user to store it.
struct RecoveryKeyView: View {
    let recoveryKey: String
    let onDone: () -> Void

    @State private var confirmed = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    Text("Сохраните ключ восстановления")
                        .font(.title.bold())
                    Text("Это единственный способ вернуть доступ, если вы забудете пароль. Мы не храним ключ в открытом виде и не сможем показать его снова.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(recoveryKey)
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .minimumScaleFactor(0.6)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .padding(.horizontal, 12)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: Theme.cornerRadius, style: .continuous))
                        .accessibilityLabel("Ключ восстановления: " + recoveryKey.map { String($0) }.joined(separator: " "))
                        .accessibilityIdentifier("recoveryKey.value")

                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: recoveryKey]],
                                                          options: [.expirationDate: Date.now.addingTimeInterval(300)])
                            copied = true
                        } label: {
                            Label(copied ? "Скопировано" : "Скопировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .sensoryFeedback(.success, trigger: copied)

                        ShareLink(item: "Ключ восстановления Padel ID: \(recoveryKey)") {
                            Label("Сохранить", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.large)

                    Text("Например, сохраните его в приложении «Пароли» или «Заметки». Скопированный ключ удалится из буфера обмена через 5 минут.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Я сохранил ключ в надёжном месте", isOn: $confirmed)
                        .accessibilityIdentifier("recoveryKey.confirm")
                }
                .padding(Theme.horizontalPadding)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaBar(edge: .bottom) {
                Button {
                    onDone()
                } label: {
                    Text("Продолжить")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!confirmed)
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.bottom, 8)
                .accessibilityIdentifier("recoveryKey.done")
            }
            .interactiveDismissDisabled()
        }
    }
}
