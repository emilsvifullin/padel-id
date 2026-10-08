import SwiftUI

/// The line-up as a court: the user's pair above the net, the opponents
/// below, each with a left and a right position.
struct EditorCourtView: View {
    let draft: EditorDraft
    let me: PlayerCard?
    let onSelect: (EditorSlot) -> Void
    let onSwap: (Int) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 14) {
            team(1)
            Capsule()
                .fill(Color(.separator))
                .frame(height: 3)
                .padding(.horizontal, 4)
                .accessibilityHidden(true)
            team(2)
        }
    }

    private func team(_ number: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(number == 1 ? "Ваша пара" : "Соперники")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button {
                    onSwap(number)
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .disabled(number == 2 && draft.opponentLeft == nil && draft.opponentRight == nil)
                .accessibilityLabel("Поменять стороны")
                .accessibilityHint(number == 1 ? "Ваша пара" : "Соперники")
                .accessibilityIdentifier("editor.swap.\(number)")
            }
            slots(number)
        }
        .accessibilityElement(children: .contain)
    }

    private func slots(_ team: Int) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        return layout {
            tile(EditorSlot.slot(team: team, side: .left))
            tile(EditorSlot.slot(team: team, side: .right))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func tile(_ slot: EditorSlot) -> some View {
        let player = draft.player(at: slot, me: me)
        if draft.isMySlot(slot) {
            EditorSlotTile(slot: slot, player: player, isMe: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText(slot, player: player, isMe: true))
                .accessibilityIdentifier(slot.accessibilityIdentifier)
        } else {
            Button {
                onSelect(slot)
            } label: {
                EditorSlotTile(slot: slot, player: player, isMe: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityText(slot, player: player, isMe: false))
            .accessibilityHint(player == nil ? "Выбрать игрока" : "Заменить игрока")
            .accessibilityIdentifier(slot.accessibilityIdentifier)
        }
    }

    private func accessibilityText(_ slot: EditorSlot, player: PlayerCard?, isMe: Bool) -> String {
        let team = slot.team == 1 ? "Ваша пара" : "Соперники"
        let side = Narratives.sideShort(slot.side).lowercased()
        guard let player else {
            return isMe ? "\(team), \(side): вы" : "\(team), \(side): игрок не выбран"
        }
        var text = "\(team), \(side): "
        if isMe { text += "вы, " }
        text += player.displayName
        if player.deleted {
            text += ", аккаунт удалён"
        } else {
            text += ", уровень \(Format.level(player.level))"
        }
        return text
    }
}

/// One position on court: the player with level, or an empty slot.
private struct EditorSlotTile: View {
    let slot: EditorSlot
    let player: PlayerCard?
    let isMe: Bool

    var body: some View {
        VStack(spacing: 8) {
            avatar
            title
            detail
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { tileBackground }
        .contentShape(.rect(cornerRadius: Theme.smallCornerRadius, style: .continuous))
    }

    private var isEmpty: Bool { player == nil && !isMe }

    private var caption: String {
        let side = Narratives.sideShort(slot.side)
        return isMe ? "Вы · \(side)" : side
    }

    @ViewBuilder
    private var avatar: some View {
        if let player {
            AvatarView(card: player, size: 48)
        } else if isMe {
            Image(systemName: "person.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 48)
                .background(Color(.tertiarySystemFill), in: .circle)
        } else {
            Image(systemName: "plus")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 48, height: 48)
                .background(Theme.accent.opacity(0.12), in: .circle)
        }
    }

    @ViewBuilder
    private var title: some View {
        if let player {
            Text(player.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(player.deleted ? Color.secondary : Color.primary)
                .lineLimit(3)
        } else if isMe {
            Text("Вы")
                .font(.subheadline.weight(.semibold))
        } else {
            Text("Выбрать игрока")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let player {
            if player.deleted {
                Text("Аккаунт удалён")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.negative)
            } else {
                LevelChip(level: player.level, reliability: player.reliability)
            }
        }
    }

    @ViewBuilder
    private var tileBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
        if isEmpty {
            shape.strokeBorder(Theme.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        } else {
            shape.fill(Color(.tertiarySystemGroupedBackground))
        }
    }
}
