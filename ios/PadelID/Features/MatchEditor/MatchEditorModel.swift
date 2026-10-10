import Foundation
import Observation

// MARK: - Lineup slots

/// A position on court. Team 1 is always the current user's pair.
nonisolated enum EditorSlot: String, CaseIterable, Hashable, Identifiable, Sendable {
    case team1Left, team1Right, team2Left, team2Right

    var id: String { rawValue }

    var team: Int {
        switch self {
        case .team1Left, .team1Right: 1
        case .team2Left, .team2Right: 2
        }
    }

    var side: CourtSide {
        switch self {
        case .team1Left, .team2Left: .left
        case .team1Right, .team2Right: .right
        }
    }

    var accessibilityIdentifier: String { "editor.slot.\(team).\(side.rawValue)" }

    static func slot(team: Int, side: CourtSide) -> EditorSlot {
        if team == 1 {
            return side == .left ? .team1Left : .team1Right
        }
        return side == .left ? .team2Left : .team2Right
    }
}

/// A set row opened in the score grid.
nonisolated struct EditorSetTarget: Identifiable, Hashable, Sendable {
    let index: Int
    var id: Int { index }
}

nonisolated enum EditorFocusField: Hashable, Sendable {
    case superTiebreakTeam1, superTiebreakTeam2
}

nonisolated enum EditorSubmitOutcome: Sendable {
    /// Delivered to the server.
    case saved
    /// Stored in the outbox; delivered when the connection returns.
    case queued
    /// Not sent (validation or server error, shown in the form).
    case failed
}

// MARK: - Request bodies (encoded with snake_case keys)

nonisolated struct EditorPlayerBody: Encodable, Hashable, Sendable {
    /// Lowercase UUID string, as the API returns it.
    let playerId: String
    let team: Int
    let courtSide: CourtSide

    init(player: UUID, team: Int, courtSide: CourtSide) {
        playerId = player.uuidString.lowercased()
        self.team = team
        self.courtSide = courtSide
    }
}

nonisolated struct EditorMatchBody: Encodable, Hashable, Sendable {
    let matchType: MatchType
    let format: MatchFormat
    let playedAt: String
    let clubId: Int?
    let players: [EditorPlayerBody]
    let sets: [SetScore]
}

nonisolated struct EditorUpdateBody: Encodable, Sendable {
    let version: Int
    let match: EditorMatchBody
}

nonisolated struct EditorPreviewBody: Encodable, Hashable, Sendable {
    let format: MatchFormat
    let players: [EditorPlayerBody]
    let sets: [SetScore]?
}

/// Identity of a forecast request: the payload plus a retry counter.
nonisolated struct EditorPreviewKey: Hashable, Sendable {
    let body: EditorPreviewBody
    let attempt: Int
}

// MARK: - Score text

nonisolated enum EditorScoreText {
    /// "6 : 4", "7 : 6 (5)" from team 1's perspective.
    static func set(_ set: SetScore) -> String {
        var text = "\(set.t1) : \(set.t2)"
        if let a = set.tb1, let b = set.tb2 {
            text += " (\(min(a, b)))"
        }
        return text
    }

    /// VoiceOver value of a set row.
    static func spoken(_ set: SetScore) -> String {
        var text = "\(set.t1):\(set.t2)"
        if let a = set.tb1, let b = set.tb2 {
            text += ", тай-брейк \(a):\(b)"
        }
        return text
    }
}

// MARK: - Draft

/// Everything the user can change in the editor. The current user is not
/// stored: they always play in team 1 on `mySide`.
nonisolated struct EditorDraft: Equatable, Sendable {
    var matchType: MatchType = .ranked
    var format: MatchFormat = .bestOf3
    var mySide: CourtSide = .right
    var partner: PlayerCard?
    var opponentRight: PlayerCard?
    var opponentLeft: PlayerCard?
    /// Regular sets by position (always three entries). The deciding super
    /// tie-break is entered as text in the two fields below.
    var sets: [SetScore?] = [nil, nil, nil]
    var superTiebreakTeam1 = ""
    var superTiebreakTeam2 = ""
    var playedAt: Date
    var club: NamedRef?

    // MARK: Construction

    static func create(partner: PlayerCard?, opponents: [PlayerCard], now: Date) -> EditorDraft {
        let minute = Calendar.current.dateInterval(of: .minute, for: now)?.start ?? now
        var draft = EditorDraft(playedAt: minute)
        var used = Set<UUID>()
        if let partner, !partner.deleted {
            draft.partner = partner
            used.insert(partner.id)
        }
        var unique: [PlayerCard] = []
        for card in opponents where !card.deleted && !used.contains(card.id) {
            unique.append(card)
            used.insert(card.id)
        }
        draft.opponentRight = unique.first
        draft.opponentLeft = unique.count > 1 ? unique[1] : nil
        return draft
    }

    /// Loads an existing match. The creator (the current user) is placed in
    /// team 1; if they played in team 2, teams and scores are mirrored.
    static func edit(_ detail: MatchDetail) -> EditorDraft {
        var draft = EditorDraft(playedAt: detail.playedAt)
        draft.matchType = detail.matchType
        draft.format = detail.format

        let mine = detail.players.first(where: { $0.player.id == detail.createdBy })
        let myTeam = mine?.team ?? 1
        draft.mySide = mine?.courtSide == .left ? .left : .right
        draft.partner = detail.players.first(where: { $0.team == myTeam && $0.player.id != detail.createdBy })?.player
        let opponents = detail.players.filter { $0.team != myTeam }
        let right = opponents.first(where: { $0.courtSide == .right }) ?? opponents.first
        let left = opponents.first(where: { $0.player.id != right?.player.id })
        draft.opponentRight = right?.player
        draft.opponentLeft = left?.player

        let mirrored = myTeam == 2
        for (index, raw) in detail.sets.prefix(3).enumerated() {
            let set = mirrored ? flipped(raw) : raw
            if set.superTiebreak {
                draft.superTiebreakTeam1 = String(set.t1)
                draft.superTiebreakTeam2 = String(set.t2)
            } else {
                draft.sets[index] = set
            }
        }
        if let club = detail.club {
            draft.club = NamedRef(id: club.id, name: club.name)
        }
        draft.normalizeSets()
        return draft
    }

    static func flipped(_ set: SetScore) -> SetScore {
        SetScore(t1: set.t2, t2: set.t1, superTiebreak: set.superTiebreak, tb1: set.tb2, tb2: set.tb1)
    }

    /// Digits only, at most two (super tie-break points).
    static func sanitizedPoints(_ value: String) -> String {
        String(value.filter { $0.isASCII && $0.isNumber }.prefix(2))
    }

    // MARK: Lineup

    func isMySlot(_ slot: EditorSlot) -> Bool {
        slot.team == 1 && (slot.side == .left) == (mySide == .left)
    }

    func player(at slot: EditorSlot, me: PlayerCard?) -> PlayerCard? {
        switch slot {
        case .team1Left: mySide == .left ? me : partner
        case .team1Right: mySide == .left ? partner : me
        case .team2Left: opponentLeft
        case .team2Right: opponentRight
        }
    }

    mutating func setPlayer(_ card: PlayerCard?, at slot: EditorSlot) {
        switch slot {
        case .team1Left, .team1Right:
            guard !isMySlot(slot) else { return }
            partner = card
        case .team2Left:
            opponentLeft = card
        case .team2Right:
            opponentRight = card
        }
    }

    mutating func swapSides(team: Int) {
        if team == 1 {
            mySide = mySide == .left ? .right : .left
        } else {
            (opponentLeft, opponentRight) = (opponentRight, opponentLeft)
        }
    }

    mutating func removePlayer(id: UUID) {
        if partner?.id == id { partner = nil }
        if opponentRight?.id == id { opponentRight = nil }
        if opponentLeft?.id == id { opponentLeft = nil }
    }

    /// The other three players (the current user is excluded).
    var lineupIds: [UUID] {
        [partner?.id, opponentRight?.id, opponentLeft?.id].compactMap { $0 }
    }

    var lineupSignature: [String] {
        [mySide.rawValue,
         partner?.id.uuidString ?? "",
         opponentRight?.id.uuidString ?? "",
         opponentLeft?.id.uuidString ?? ""]
    }

    var isLineupComplete: Bool {
        partner != nil && opponentRight != nil && opponentLeft != nil
    }

    var hasDeletedPlayer: Bool {
        [partner, opponentRight, opponentLeft].contains { $0?.deleted == true }
    }

    func playersBody(meId: UUID) -> [EditorPlayerBody]? {
        guard let partner, let opponentRight, let opponentLeft else { return nil }
        let mine: CourtSide = mySide == .left ? .left : .right
        let partnerSide: CourtSide = mine == .left ? .right : .left
        return [
            EditorPlayerBody(player: meId, team: 1, courtSide: mine),
            EditorPlayerBody(player: partner.id, team: 1, courtSide: partnerSide),
            EditorPlayerBody(player: opponentRight.id, team: 2, courtSide: .right),
            EditorPlayerBody(player: opponentLeft.id, team: 2, courtSide: .left),
        ]
    }

    // MARK: Score

    /// The first two sets while they are entered without gaps (they decide
    /// whether a third set is needed).
    private var leadingSets: [SetScore] {
        var result: [SetScore] = []
        for index in 0..<min(2, sets.count) {
            guard let entry = sets[index] else { break }
            result.append(entry)
        }
        return result
    }

    var expectedSetCount: Int {
        ScoreRules.expectedSetCount(format: format, sets: leadingSets)
    }

    func isSuperTiebreakRow(_ index: Int) -> Bool {
        format == .bestOf3SuperTiebreak && index == 2
    }

    var superTiebreakScore: SetScore? {
        guard let a = Int(superTiebreakTeam1), let b = Int(superTiebreakTeam2) else { return nil }
        return SetScore(t1: a, t2: b, superTiebreak: true)
    }

    func regularSet(at index: Int) -> SetScore? {
        guard index >= 0, index < sets.count else { return nil }
        return sets[index]
    }

    func score(at index: Int) -> SetScore? {
        isSuperTiebreakRow(index) ? superTiebreakScore : regularSet(at: index)
    }

    /// All expected sets, or nil while any of them is missing.
    var completeSets: [SetScore]? {
        var result: [SetScore] = []
        for index in 0..<expectedSetCount {
            guard let set = score(at: index) else { return nil }
            result.append(set)
        }
        return result
    }

    /// The winning team of a fully entered, valid score.
    var scoreWinner: Int? {
        guard let entered = completeSets,
              case .success(let winner) = ScoreRules.validate(format: format, sets: entered) else { return nil }
        return winner
    }

    /// The rule a fully entered score breaks (nil while incomplete or valid).
    var scoreIssue: ScoreRules.Issue? {
        guard let entered = completeSets,
              case .failure(let issue) = ScoreRules.validate(format: format, sets: entered) else { return nil }
        return issue
    }

    var validSets: [SetScore]? {
        guard let entered = completeSets,
              case .success = ScoreRules.validate(format: format, sets: entered) else { return nil }
        return entered
    }

    /// Drops sets that are no longer part of the match after an earlier set
    /// or the format changed.
    mutating func normalizeSets() {
        while sets.count < 3 { sets.append(nil) }
        if sets.count > 3 { sets = Array(sets.prefix(3)) }
        let count = expectedSetCount
        for index in 0..<3 where index >= count {
            sets[index] = nil
        }
        if format == .bestOf3SuperTiebreak {
            sets[2] = nil
        }
        if !(format == .bestOf3SuperTiebreak && count == 3) {
            superTiebreakTeam1 = ""
            superTiebreakTeam2 = ""
        }
    }

    // MARK: Date

    /// Ranked matches are accepted within 14 days, friendly within 90.
    var allowedDays: Int { matchType == .ranked ? 14 : 90 }

    func isPlayedAtValid(now: Date) -> Bool {
        playedAt >= now.addingTimeInterval(-Double(allowedDays) * 86_400)
            && playedAt <= now.addingTimeInterval(3_600)
    }

    /// The earliest date offered by the picker (a small margin keeps the
    /// value valid until the match is sent).
    func earliestSelectableDate(now: Date) -> Date {
        now.addingTimeInterval(-Double(allowedDays) * 86_400 + 600)
    }

    mutating func clampPlayedAt(now: Date) {
        let lower = earliestSelectableDate(now: now)
        if playedAt < lower { playedAt = lower }
        if playedAt > now { playedAt = now }
    }
}

// MARK: - Model

/// State of the match editor: the draft, validation, the rating forecast and
/// submission (online, through the outbox, or as an edit).
@Observable
final class MatchEditorModel {
    let isEditing: Bool
    let upcomingMatch: UpcomingMatch?
    let scheduledStartsAt: Date?
    let matchId: UUID?
    /// The creator of an edited match (the current user).
    let editorId: UUID?
    let editorCard: PlayerCard?
    /// One key per editor instance: retries and the outbox reuse it.
    let idempotencyKey = UUID()

    var draft: EditorDraft
    private(set) var initial: EditorDraft
    private(set) var version: Int

    private(set) var isSubmitting = false
    private(set) var isFinished = false
    /// The edited match can no longer be changed (confirmed, cancelled, expired).
    private(set) var isLocked = false
    private(set) var submitError: APIError?
    private(set) var errorDraft: EditorDraft?
    /// Incremented on every failed submission (drives the error haptic).
    private(set) var failureCount = 0

    private(set) var preview: MatchPreview?
    private(set) var previewSource: EditorPreviewBody?
    private(set) var previewFailed = false
    private(set) var previewAttempt = 0

    @ObservationIgnored private var prepared = false

    init(request: MatchEditorRequest) {
        let start: EditorDraft
        switch request.mode {
        case .create(partner: let partner, opponents: let opponents):
            isEditing = false
            upcomingMatch = nil
            scheduledStartsAt = nil
            matchId = nil
            editorId = nil
            editorCard = nil
            version = 0
            start = EditorDraft.create(partner: partner, opponents: opponents, now: .now)
        case .edit(let detail):
            isEditing = true
            upcomingMatch = nil
            scheduledStartsAt = detail.scheduledStartsAt
            matchId = detail.id
            editorId = detail.createdBy
            editorCard = detail.players.first(where: { $0.player.id == detail.createdBy })?.player
            version = detail.version
            start = EditorDraft.edit(detail)
        case .upcoming(let game, playerId: let playerId):
            isEditing = false
            upcomingMatch = game
            scheduledStartsAt = game.startsAt
            matchId = nil
            editorId = playerId
            editorCard = game.participants.first { $0.id == playerId }?.player
            version = 0
            let others = game.participants.map(\.player).filter { $0.id != playerId }
            var resultDraft = EditorDraft.create(partner: others.first, opponents: Array(others.dropFirst()), now: .now)
            resultDraft.matchType = game.matchType
            resultDraft.playedAt = game.startsAt
            resultDraft.club = game.club
            start = resultDraft
        }
        draft = start
        initial = start
    }

    var isDirty: Bool { draft != initial }
    var isScheduledResult: Bool { scheduledStartsAt != nil }
    var allowedPlayers: [PlayerCard]? {
        guard isScheduledResult else { return nil }
        return upcomingMatch?.participants.map(\.player) ?? [initial.partner, initial.opponentLeft, initial.opponentRight].compactMap { $0 }
    }
    var createPath: String {
        if let upcomingMatch { return "v1/upcoming-matches/" + upcomingMatch.id.uuidString.lowercased() + "/result" }
        return "v1/matches"
    }

    /// The error of the last submission while the form still shows the
    /// submitted values.
    var visibleError: APIError? {
        guard let submitError else { return nil }
        if isLocked { return submitError }
        return errorDraft == draft ? submitError : nil
    }

    /// Removes the current user from the other positions (pre-filled requests).
    func prepare(meId: UUID?) {
        guard !prepared, let meId else { return }
        prepared = true
        draft.removePlayer(id: meId)
        initial.removePlayer(id: meId)
    }

    // MARK: Editing

    func setPlayer(_ card: PlayerCard?, at slot: EditorSlot) {
        if isScheduledResult, let card, !draft.isMySlot(slot),
           let previousSlot = EditorSlot.allCases.first(where: {
               $0 != slot && !draft.isMySlot($0) && draft.player(at: $0, me: nil)?.id == card.id
           }) {
            let previousPlayer = draft.player(at: slot, me: nil)
            draft.setPlayer(previousPlayer, at: previousSlot)
        }
        draft.setPlayer(card, at: slot)
    }

    func swapSides(team: Int) {
        draft.swapSides(team: team)
    }

    func setMatchType(_ type: MatchType) {
        draft.matchType = type
        draft.clampPlayedAt(now: .now)
    }

    func setFormat(_ format: MatchFormat) {
        draft.format = format
        draft.normalizeSets()
    }

    func setScore(_ set: SetScore?, at index: Int) {
        guard index >= 0, index < draft.sets.count else { return }
        draft.sets[index] = set
        draft.normalizeSets()
    }

    // MARK: Validation

    func makeBody(meId: UUID, now: Date) -> EditorMatchBody? {
        guard !draft.hasDeletedPlayer,
              draft.isPlayedAtValid(now: now),
              let players = draft.playersBody(meId: meId),
              Set(players.map(\.playerId)).count == 4,
              let sets = draft.validSets else { return nil }
        if let scheduledStartsAt {
            let admitted = upcomingMatch?.participants.map(\.id) ?? ([editorId].compactMap { $0 } + initial.lineupIds)
            guard meId == editorId, draft.matchType == initial.matchType, draft.playedAt >= scheduledStartsAt,
                  draft.club?.id == initial.club?.id,
                  Set(players.map(\.playerId)) == Set(admitted.map { $0.uuidString.lowercased() }) else { return nil }
        }
        return EditorMatchBody(
            matchType: draft.matchType,
            format: draft.format,
            playedAt: JSONCoding.formatDate(draft.playedAt),
            clubId: draft.club?.id,
            players: players,
            sets: sets)
    }

    func canSubmit(meId: UUID?, isOnline: Bool, now: Date) -> Bool {
        guard let meId, !isSubmitting, !isFinished, !isLocked else { return false }
        if isEditing && (!isOnline || !isDirty) { return false }
        return makeBody(meId: meId, now: now) != nil
    }

    // MARK: Submission

    func submit(app: AppModel, meId: UUID) async -> EditorSubmitOutcome {
        guard !isSubmitting, !isFinished, let body = makeBody(meId: meId, now: .now) else { return .failed }
        if isEditing {
            return await saveEdit(body, app: app)
        }
        isSubmitting = true
        defer { isSubmitting = false }
        guard app.isOnline else {
            enqueue(body, app: app)
            return .queued
        }
        do {
            _ = try await app.api.data(.json(.post, createPath, body, idempotencyKey: idempotencyKey))
            isFinished = true
            app.dataDidChange()
            return .saved
        } catch let error as APIError where error.isNetwork {
            enqueue(body, app: app)
            return .queued
        } catch let error as APIError {
            fail(error)
            return .failed
        } catch {
            return .failed
        }
    }

    private func saveEdit(_ body: EditorMatchBody, app: AppModel) async -> EditorSubmitOutcome {
        guard let matchId else { return .failed }
        guard app.isOnline else {
            fail(.offline)
            return .failed
        }
        isSubmitting = true
        defer { isSubmitting = false }
        let path = "v1/matches/\(matchId.uuidString.lowercased())"
        do {
            let update = EditorUpdateBody(version: version, match: body)
            _ = try await app.api.data(.json(.put, path, update, idempotencyKey: idempotencyKey))
            isFinished = true
            app.dataDidChange()
            return .saved
        } catch let error as APIError {
            switch error.code {
            case "version_conflict":
                await reload(path: path, app: app)
            case "match_locked", "match_closed", "match_not_found", "forbidden":
                isLocked = true
                app.dataDidChange()
            default:
                break
            }
            fail(error)
            return .failed
        } catch {
            return .failed
        }
    }

    /// After a version conflict the form shows the current state of the match.
    private func reload(path: String, app: AppModel) async {
        guard let detail = try? await app.api.send(.get(path), as: MatchDetail.self) else { return }
        app.dataDidChange()
        guard detail.viewer.canEdit else {
            isLocked = true
            return
        }
        version = detail.version
        let fresh = EditorDraft.edit(detail)
        draft = fresh
        initial = fresh
    }

    private func enqueue(_ body: EditorMatchBody, app: AppModel) {
        let names = [draft.opponentRight, draft.opponentLeft].compactMap { $0?.displayName }
        let data = try? JSONCoding.encoder.encode(body)
        let operation = PendingOperation(
            id: UUID(),
            kind: .createMatch,
            method: "POST",
            path: createPath,
            body: data,
            idempotencyKey: idempotencyKey,
            matchId: nil,
            // «против» would need the genitive case, which names cannot take.
            title: names.isEmpty ? "Новый матч" : "Новый матч: соперники — " + names.joined(separator: " и "),
            subtitle: Format.score(body.sets),
            createdAt: .now)
        app.outbox.enqueue(operation)
        isFinished = true
        Task { await app.flushOutbox() }
    }

    private func fail(_ error: APIError) {
        submitError = error
        errorDraft = draft
        failureCount += 1
    }

    // MARK: Forecast

    /// The forecast request for a ranked match with a complete line-up.
    func previewKey(meId: UUID?) -> EditorPreviewKey? {
        guard draft.matchType == .ranked, let meId, !draft.hasDeletedPlayer,
              let players = draft.playersBody(meId: meId) else { return nil }
        let body = EditorPreviewBody(format: draft.format, players: players, sets: draft.validSets)
        return EditorPreviewKey(body: body, attempt: previewAttempt)
    }

    /// Debounced forecast; a newer key cancels the running request.
    func loadPreview(_ key: EditorPreviewKey?, app: AppModel) async {
        guard let key else {
            preview = nil
            previewSource = nil
            previewFailed = false
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(500))
        } catch {
            return
        }
        previewFailed = false
        do {
            let result = try await app.api.send(
                .json(.post, "v1/matches/preview", key.body, retryable: true), as: MatchPreview.self)
            guard !Task.isCancelled else { return }
            preview = result
            previewSource = key.body
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            preview = nil
            previewSource = nil
            previewFailed = true
        }
    }

    func retryPreview() {
        previewFailed = false
        previewAttempt += 1
    }

    func myPreview(meId: UUID?) -> PreviewPlayer? {
        guard let meId else { return nil }
        return preview?.players.first(where: { $0.playerId == meId })
    }
}
