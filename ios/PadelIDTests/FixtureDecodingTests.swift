import Foundation
import Testing
@testable import PadelID

/// Decodes every API fixture (real database output) into its model and checks
/// that the content is what the screens rely on.
@MainActor
@Suite("API fixtures")
struct FixtureDecodingTests {
    private let allDimensions = Set(DNADimension.allCases)

    @Test("Every fixture is bundled, non-empty JSON", arguments: FixtureLoader.allNames)
    func fixtureIsJSON(name: String) throws {
        let data = try FixtureLoader.data(name)
        #expect(!data.isEmpty)
        _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // MARK: Identity

    @Test("me.json: onboarded player")
    func me() throws {
        let me = try FixtureLoader.decode(Me.self, "me")
        #expect(!me.needsOnboarding)
        #expect(!me.isAdmin)
        #expect(me.email == "m.orlov@padelid.app")
        #expect(me.coachStatus == nil)
        #expect(me.recoveryKeyCreatedAt != nil)

        let profile = try #require(me.profile)
        #expect(profile.id == me.userId)
        #expect(profile.username == "m_orlov")
        #expect(profile.displayName == "Михаил Орлов")
        #expect(profile.city?.name == "Москва")
        #expect(profile.club != nil)
        #expect(profile.preferredSide == .right)
        #expect(profile.dominantHand == .right)
        #expect(profile.memberSince != nil)
        #expect(!profile.deleted)

        let rating = try #require(me.rating)
        #expect(rating.rankedMatches > 0)
        #expect(rating.rankedWins <= rating.rankedMatches)
        #expect(rating.mu > 0 && rating.mu <= 7)
        #expect((0...100).contains(rating.reliability))
        #expect(rating.peakMu >= rating.mu)
        #expect(rating.lastRankedAt != nil)
        #expect(profile.level == rating.mu)

        let dnaSelf = try #require(me.dnaSelf)
        #expect(Set(dnaSelf.keys.compactMap { DNADimension(apiKey: $0) }) == allDimensions)
        #expect(dnaSelf.values.allSatisfy { (-2...2).contains($0) })
    }

    @Test("me_new.json: account without a profile")
    func meNew() throws {
        let me = try FixtureLoader.decode(Me.self, "me_new")
        #expect(me.needsOnboarding)
        #expect(me.profile == nil)
        #expect(me.rating == nil)
        #expect(me.dnaSelf == nil)
        #expect(me.email == "new.player@padelid.app")
    }

    @Test("Session fixtures belong to the fixture users")
    func sessions() throws {
        let me = try FixtureLoader.decode(Me.self, "me")
        let session = try FixtureLoader.decode(Session.self, "session")
        #expect(session.user.id == me.userId)
        #expect(session.user.email == "m.orlov@padelid.app")
        #expect(session.accessToken.count >= 40)
        #expect(!session.refreshToken.isEmpty)
        #expect(session.expiresIn == 3600)
        #expect(session.expiresAt == 4_102_444_800)
        #expect(session.expiryDate > Date())

        let signup = try FixtureLoader.decode(SignupResponse.self, "signup")
        #expect(signup.recoveryKey == "7K2QD-M4XPR-9HV3A-TC8WN")
        #expect(signup.session == session)

        let newcomer = try FixtureLoader.decode(Me.self, "me_new")
        let newSession = try FixtureLoader.decode(Session.self, "new_user_session")
        #expect(newSession.user.id == newcomer.userId)
        #expect(newSession.user.email == newcomer.email)
        #expect(newSession.accessToken != session.accessToken)
    }

    @Test("username_check.json and coach_application.json")
    func usernameAndCoachApplication() throws {
        let check = try FixtureLoader.decode(UsernameCheck.self, "username_check")
        #expect(check.username == "ilya_gromov")
        #expect(check.valid)
        #expect(check.available)
        #expect(check.reason == nil)

        let application = try FixtureLoader.decode(CoachApplication?.self, "coach_application")
        #expect(application == nil)
    }

    // MARK: Home

    @Test("home.json: dashboard of an active player")
    func home() throws {
        let home = try FixtureLoader.decode(HomeResponse.self, "home")
        let me = try FixtureLoader.decode(Me.self, "me")
        #expect(!home.deleted)
        #expect(home.profile.id == me.userId)
        #expect(home.rating == me.rating)

        #expect(!home.insights.isEmpty)
        for insight in home.insights {
            let text = Narratives.insight(insight)
            #expect(text != nil, "insight \(insight.kind) has no text")
            #expect(text?.title.isEmpty == false)
            #expect(text?.body.isEmpty == false)
        }
        let kinds = Set(home.insights.map(\.kind))
        let expectedKinds: Set<String> = ["trend", "best_partner", "focus_area"]
        #expect(kinds.isSuperset(of: expectedKinds))

        #expect(home.openMatchesCount == 3)
        #expect(home.actionItems.count == 1)
        #expect(home.actionItems.allSatisfy { $0.needsAction && $0.myResponse == .pending })

        let dna = try #require(home.dna)
        #expect(dna.dimensions.count == 6)
        #expect(Set(dna.dimensions.compactMap(\.dimension)) == allDimensions)

        let stats = try #require(home.stats)
        #expect(stats.matches > 0)
        #expect(stats.matches == stats.wins + stats.losses)
        #expect(stats.ranked.matches + stats.friendly.matches == stats.matches)
        #expect(stats.sides.left.matches + stats.sides.right.matches == stats.matches)
        #expect(stats.form.allSatisfy { $0 == "W" || $0 == "L" })
        #expect(!stats.partners.isEmpty)
        #expect(stats.streak != nil)

        let recent = try #require(home.recentMatches)
        #expect(!recent.isEmpty && recent.count <= 5)
        #expect(recent.allSatisfy { $0.status == .confirmed && $0.players.count == 4 && $0.subjectTeam != nil })

        let assessments = try #require(home.coachAssessments)
        #expect(!assessments.isEmpty)
        for assessment in assessments {
            #expect(assessment.coach.isCoach)
            #expect(Set(assessment.scores.keys.compactMap { DNADimension(apiKey: $0) }) == allDimensions)
            #expect(assessment.scores.values.allSatisfy { (0.0...7.0).contains($0) })
        }
    }

    @Test("home.json: insight texts carry the server's numbers")
    func homeInsightValues() throws {
        let home = try FixtureLoader.decode(HomeResponse.self, "home")
        for insight in home.insights {
            let text = try #require(Narratives.insight(insight))
            switch insight.kind {
            case "reliability_path":
                let needed = try #require(value(insight, "matches_needed")?.int)
                #expect(text.body.contains(Format.count(needed, "рейтинговый матч", "рейтинговых матча", "рейтинговых матчей")))
            case "trend":
                let delta = try #require(value(insight, "delta")?.double)
                if insight.sentiment != .neutral {
                    #expect(text.title.contains(Format.delta(delta)))
                }
            case "side_split":
                let left = try #require(value(insight, "left_win_rate")?.double)
                let right = try #require(value(insight, "right_win_rate")?.double)
                #expect(text.body.contains(Format.percent(left)))
                #expect(text.body.contains(Format.percent(right)))
                let better = value(insight, "better_side")?.string == "left" ? "левой" : "правой"
                #expect(text.title.contains(better))
            case "close_sets":
                let won = try #require(value(insight, "won")?.int)
                let total = try #require(value(insight, "total")?.int)
                #expect(text.body.contains("\(won) из \(total)"))
            case "best_partner":
                let partner = try #require(value(insight, "player")?.decode(PlayerCard.self))
                #expect(text.title.contains(partner.displayName))
            case "focus_area":
                let key = try #require(value(insight, "dimension")?.string)
                let dimension = try #require(DNADimension(apiKey: key))
                #expect(text.symbol == dimension.symbol)
            default:
                break
            }
        }
    }

    /// Reads an insight value by its API key whatever key form the decoder produced.
    private func value(_ insight: Insight, _ snakeKey: String) -> JSONValue? {
        if let raw = insight.values[snakeKey] { return raw }
        let parts = snakeKey.split(separator: "_").map(String.init)
        let camel = parts.enumerated().map { $0.offset == 0 ? $0.element : $0.element.capitalized }.joined()
        return insight.values[camel]
    }

    @Test("home_new.json: just onboarded, no matches")
    func homeNew() throws {
        let home = try FixtureLoader.decode(HomeResponse.self, "home_new")
        let newcomer = try FixtureLoader.decode(Me.self, "me_new")
        #expect(home.profile.id == newcomer.userId)
        #expect(home.profile.displayName == "Илья Громов")
        #expect(home.actionItems.isEmpty)
        #expect(home.openMatchesCount == 0)
        #expect((home.recentMatches ?? []).isEmpty)
        #expect(home.stats?.matches == 0)
        #expect(home.stats?.form.isEmpty == true)
        #expect(home.stats?.streak == nil)
        #expect(home.stats?.lastPlayedAt == nil)
        #expect(home.rating?.rankedMatches == 0)
        #expect(home.rating?.provisional == true)
        #expect(home.dna?.archetype == DNAArchetype.forming.rawValue)
        #expect(home.insights.contains { $0.kind == "reliability_path" })
        for insight in home.insights {
            #expect(Narratives.insight(insight) != nil, "insight \(insight.kind) has no text")
        }
    }

    // MARK: Matches

    @Test("matches_open.json: three open matches, one needs action")
    func openMatches() throws {
        let page = try FixtureLoader.decode(MatchPage.self, "matches_open")
        let action = try FixtureLoader.decode(MatchDetail.self, "match_action")
        let home = try FixtureLoader.decode(HomeResponse.self, "home")
        #expect(page.items.count == 3)
        #expect(page.nextBefore == nil)
        #expect(page.items.allSatisfy { $0.status == .pending || $0.status == .disputed })
        #expect(page.items.allSatisfy { $0.players.count == 4 && $0.expiresAt != nil })
        #expect(page.items.filter(\.needsAction).count == 1)
        #expect(page.items.first?.needsAction == true)
        #expect(page.items.first?.id == action.id)
        #expect(home.actionItems.first?.id == action.id)
        #expect(page.items.contains { $0.isCreator && $0.myResponse == .confirmed && $0.pendingCount == 2 })
        #expect(page.items.contains { $0.status == .disputed && $0.myResponse == .disputed && $0.matchType == .friendly })
    }

    @Test("matches_history.json: confirmed matches, newest first")
    func history() throws {
        let page = try FixtureLoader.decode(MatchPage.self, "matches_history")
        #expect(page.items.count >= 15)
        #expect(page.nextBefore == nil)
        #expect(page.items.allSatisfy { $0.status == .confirmed && $0.players.count == 4 && $0.myTeam != nil })
        let dates = page.items.map(\.playedAt)
        #expect(dates == dates.sorted(by: >))
        for item in page.items {
            if item.matchType == .ranked {
                #expect(item.ratingDelta != nil)
            } else {
                #expect(item.ratingDelta == nil)
            }
            #expect(ScoreRules.validate(format: item.format, sets: item.sets) == .success(item.winnerTeam))
        }
        #expect(Set(page.items.map(\.format)) == Set(MatchFormat.allCases))
        #expect(page.items.contains { $0.matchType == .friendly })
        #expect(page.items.contains { $0.sets.contains { $0.tb1 != nil && $0.tb2 != nil } })
        #expect(page.items.contains { $0.sets.contains(where: \.superTiebreak) })
        if let newest = dates.first, let oldest = dates.last {
            #expect(newest.timeIntervalSince(oldest) > 60 * 86_400)
        }
    }

    @Test("match_action.json: ranked match waiting for my confirmation")
    func actionMatch() throws {
        let detail = try FixtureLoader.decode(MatchDetail.self, "match_action")
        let me = try FixtureLoader.decode(Me.self, "me")
        #expect(detail.status == .pending)
        #expect(detail.matchType == .ranked)
        #expect(detail.players.count == 4)
        #expect(detail.team(1).count == 2)
        #expect(detail.team(2).count == 2)
        #expect(detail.team(1).first?.courtSide == .right)
        #expect(detail.createdBy != me.userId)
        #expect(detail.viewer.isParticipant)
        #expect(detail.viewer.canConfirm)
        #expect(detail.viewer.canDispute)
        #expect(!detail.viewer.canEdit)
        #expect(!detail.viewer.isCreator)
        #expect(detail.viewer.response == .pending)
        #expect(detail.expiresAt != nil)
        #expect(!detail.ratingApplied)
        #expect(detail.players.allSatisfy { $0.ratingChange == nil })
        #expect(detail.analysis.projectedChange != nil)
        #expect((0.0...1.0).contains(detail.analysis.expectedWinTeam1))

        let mine = try #require(detail.players.first(where: { $0.player.id == me.userId }))
        #expect(mine.response == .pending)
        #expect(mine.team == detail.viewer.team)
    }

    @Test("match_action_confirmed.json: my confirmation completes the match")
    func actionConfirmed() throws {
        let detail = try FixtureLoader.decode(MatchDetail.self, "match_action_confirmed")
        let action = try FixtureLoader.decode(MatchDetail.self, "match_action")
        #expect(detail.id == action.id)
        #expect(detail.status == .confirmed)
        #expect(detail.ratingApplied)
        #expect(detail.confirmedAt != nil)
        #expect(detail.expiresAt == nil)
        #expect(!detail.viewer.canConfirm)
        #expect(detail.viewer.canGiveFeedback)
        for player in detail.players {
            #expect(player.response == .confirmed)
            let change = try #require(player.ratingChange)
            #expect((change.delta > 0) == (player.team == detail.winnerTeam))
            #expect(abs(change.muAfter - change.muBefore - change.delta) < 0.002)
            #expect(change.sigmaAfter <= change.sigmaBefore)
            #expect(!Narratives.ratingExplanation(change).isEmpty)
        }
    }

    @Test("match_confirmed.json: recent ranked match")
    func confirmedMatch() throws {
        let detail = try FixtureLoader.decode(MatchDetail.self, "match_confirmed")
        #expect(detail.status == .confirmed)
        #expect(detail.matchType == .ranked)
        #expect(detail.ratingApplied)
        #expect(detail.players.count == 4)
        #expect(detail.players.allSatisfy { $0.ratingChange != nil && $0.response == .confirmed })
        #expect(detail.viewer.isParticipant)
        #expect(detail.viewer.canGiveFeedback)
        #expect(detail.viewer.feedback != nil)
        #expect(detail.club?.city == "Москва")
        #expect(detail.team1Sets + detail.team2Sets == detail.sets.count)
        #expect(ScoreRules.validate(format: detail.format, sets: detail.sets) == .success(detail.winnerTeam))
        let games = ScoreRules.games(detail.sets)
        #expect(games.0 == detail.team1Games)
        #expect(games.1 == detail.team2Games)
    }

    @Test("match_created.json: new ranked match entered by me")
    func createdMatch() throws {
        let detail = try FixtureLoader.decode(MatchDetail.self, "match_created")
        let me = try FixtureLoader.decode(Me.self, "me")
        #expect(detail.status == .pending)
        #expect(detail.version == 1)
        #expect(detail.createdBy == me.userId)
        #expect(detail.viewer.isCreator)
        #expect(detail.viewer.canEdit)
        #expect(detail.viewer.canCancel)
        #expect(!detail.viewer.canConfirm)
        #expect(!detail.viewer.canDispute)
        let confirmed = detail.players.filter { $0.response == .confirmed }.map(\.player.id)
        #expect(confirmed == [me.userId])
        #expect(detail.players.filter { $0.response == .pending }.count == 3)
        #expect(detail.analysis.projectedChange != nil)
    }

    // MARK: Players

    @Test("player_profile.json: most frequent partner with compatibility")
    func playerProfile() throws {
        let response = try FixtureLoader.decode(PlayerProfileResponse.self, "player_profile")
        let me = try FixtureLoader.decode(Me.self, "me")
        #expect(!response.deleted)
        #expect(response.profile.id != me.userId)
        #expect(response.viewer?.isMe == false)
        #expect(response.rating != nil)
        #expect(response.dna?.dimensions.count == 6)

        let compatibility = try #require(response.compatibility)
        #expect((0...100).contains(compatibility.score))
        #expect(compatibility.components.count == 5)
        let reasons = Narratives.compatibilityReasons(compatibility, otherName: response.profile.displayName)
        #expect(!reasons.isEmpty)
        #expect(reasons.count == compatibility.reasons.count)

        let stats = try #require(response.stats)
        #expect(stats.partners.first?.player.id == me.userId)
        let recent = try #require(response.recentMatches)
        #expect(!recent.isEmpty)
        #expect(recent.allSatisfy { $0.subjectTeam != nil })
    }

    @Test("player_matches.json: history of another player")
    func playerMatches() throws {
        let page = try FixtureLoader.decode(MatchPage.self, "player_matches")
        let profile = try FixtureLoader.decode(PlayerProfileResponse.self, "player_profile")
        let subject = profile.profile.id
        #expect(!page.items.isEmpty)
        #expect(page.items.count == profile.stats?.matches)
        for item in page.items {
            #expect(item.status == .confirmed)
            let team = try #require(item.subjectTeam)
            #expect(item.players.contains { $0.player.id == subject && $0.team == team })
            if item.matchType == .ranked {
                #expect(item.subjectRatingDelta != nil)
            }
        }
    }

    @Test("rating_history.json: calibration then every ranked match")
    func ratingHistory() throws {
        let history = try FixtureLoader.decode(RatingHistory.self, "rating_history")
        let me = try FixtureLoader.decode(Me.self, "me")
        let rating = try #require(me.rating)
        let first = try #require(history.points.first)
        #expect(first.kind == "calibration")
        #expect(first.delta == nil)
        #expect(first.matchId == nil)
        #expect(abs(first.mu - rating.initialMu) < 0.01)

        let matches = history.points.filter { $0.kind == "match" }
        #expect(matches.count == rating.rankedMatches)
        #expect(matches.allSatisfy { $0.delta != nil && $0.matchId != nil && $0.won != nil && $0.expectedWin != nil })
        let times = history.points.map(\.at)
        #expect(times == times.sorted())
        #expect(history.peakMu == rating.peakMu)
        if let last = history.points.last {
            #expect(abs(last.mu - rating.mu) < 0.01)
        }
    }

    @Test("dna.json: six dimensions with history")
    func dna() throws {
        let dna = try FixtureLoader.decode(PadelDNA.self, "dna")
        #expect(DNAArchetype(rawValue: dna.archetype) != nil)
        #expect(dna.dimensions.compactMap(\.dimension) == DNADimension.allCases)
        #expect(dna.dimensions.allSatisfy { (0.0...1.0).contains($0.confidence) && (0.0...7.0).contains($0.level) })
        #expect(dna.dimensions.contains { $0.coachVerifiedAt != nil })
        #expect(dna.dimensions.contains { $0.peerSignals > 0 })

        let rating = try #require(dna.rating)
        let mean = dna.dimensions.map(\.level).reduce(0, +) / Double(dna.dimensions.count)
        #expect(abs(mean - rating.mu) < 0.05)

        let history = try #require(dna.history)
        #expect(!history.isEmpty)
        #expect(history.allSatisfy { DNADimension(apiKey: $0.dimension) != nil && (0.0...7.0).contains($0.level) })
        #expect(Set(history.map(\.day)).count > 1)
    }

    @Test("search.json: default search sorted by compatibility")
    func search() throws {
        let result = try FixtureLoader.decode(SearchResult.self, "search")
        let me = try FixtureLoader.decode(Me.self, "me")
        #expect(!result.items.isEmpty)
        #expect(result.items.count == result.total)
        #expect(result.nextOffset == nil)
        #expect(!result.items.contains { $0.id == me.userId })
        let scores = result.items.compactMap(\.compatibility)
        #expect(scores.count == result.items.count)
        #expect(scores == scores.sorted(by: >))
        #expect(result.items.contains { $0.isCoach })
        #expect(result.items.allSatisfy { $0.level != nil && $0.reliability != nil && $0.username != nil })
    }

    @Test("recent_players.json: players I played with")
    func recentPlayers() throws {
        let players = try FixtureLoader.decode([PlayerCard].self, "recent_players")
        let me = try FixtureLoader.decode(Me.self, "me")
        #expect(!players.isEmpty)
        #expect(!players.contains { $0.id == me.userId })
        #expect(players.allSatisfy { ($0.matchesTogether ?? 0) > 0 && !$0.deleted })
    }

    // MARK: Reference data and preview

    @Test("cities.json and clubs.json")
    func referenceData() throws {
        let cities = try FixtureLoader.decode([City].self, "cities")
        let moscow = try #require(cities.first)
        #expect(moscow.name == "Москва")
        #expect(moscow.countryCode == "RU")
        #expect(cities.contains { $0.name == "Санкт-Петербург" })
        #expect(Set(cities.map(\.id)).count == cities.count)

        let clubs = try FixtureLoader.decode([Club].self, "clubs")
        let clubNames: Set<String> = ["Падел Арена Лужники", "Corner Padel Club"]
        #expect(Set(clubs.map(\.name)) == clubNames)
        #expect(clubs.allSatisfy { $0.cityId == moscow.id && $0.playersCount > 0 })
    }

    @Test("preview.json: expected rating change for both outcomes")
    func preview() throws {
        let preview = try FixtureLoader.decode(MatchPreview.self, "preview")
        let me = try FixtureLoader.decode(Me.self, "me")
        #expect(preview.players.count == 4)
        #expect((0.0...1.0).contains(preview.expectedWinTeam1))
        #expect(preview.weight > 0 && preview.weight <= 1)
        #expect(preview.players.contains { $0.playerId == me.userId && $0.team == 1 })
        for player in preview.players {
            if player.team == 1 {
                #expect(player.ifTeam1Wins > 0)
                #expect(player.ifTeam2Wins < 0)
            } else {
                #expect(player.ifTeam1Wins < 0)
                #expect(player.ifTeam2Wins > 0)
            }
            #expect(player.withEnteredScore != nil)
        }
    }
}
