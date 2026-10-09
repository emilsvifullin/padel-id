import Foundation
import Testing
@testable import PadelID

@MainActor
@Suite("Score rules")
struct ScoreRulesTests {
    private func set(_ t1: Int, _ t2: Int, tb: (Int, Int)? = nil) -> SetScore {
        SetScore(t1: t1, t2: t2, superTiebreak: false, tb1: tb?.0, tb2: tb?.1)
    }

    private func superTiebreak(_ t1: Int, _ t2: Int) -> SetScore {
        SetScore(t1: t1, t2: t2, superTiebreak: true)
    }

    @Test("Regular set scores")
    func regularSets() {
        let valid = [(6, 0), (6, 1), (6, 2), (6, 3), (6, 4), (7, 5), (7, 6), (0, 6), (4, 6), (5, 7), (6, 7)]
        for (a, b) in valid {
            #expect(ScoreRules.isValidRegularSet(a, b), "\(a)-\(b) is valid")
        }
        let invalid = [(6, 5), (7, 4), (7, 7), (6, 6), (5, 5), (8, 6), (0, 0), (5, 0), (7, 0)]
        for (a, b) in invalid {
            #expect(!ScoreRules.isValidRegularSet(a, b), "\(a)-\(b) is invalid")
        }
        #expect(ScoreRules.regularSetResults.count == 14)
        #expect(ScoreRules.regularSetResults.allSatisfy { ScoreRules.isValidRegularSet($0.0, $0.1) })
    }

    @Test("Tie-break: to 7, win by 2")
    func tiebreaks() {
        #expect(ScoreRules.isValidTiebreak(winnerPoints: 7, loserPoints: 0))
        #expect(ScoreRules.isValidTiebreak(winnerPoints: 7, loserPoints: 5))
        #expect(ScoreRules.isValidTiebreak(winnerPoints: 8, loserPoints: 6))
        #expect(ScoreRules.isValidTiebreak(winnerPoints: 12, loserPoints: 10))
        #expect(!ScoreRules.isValidTiebreak(winnerPoints: 7, loserPoints: 6))
        #expect(!ScoreRules.isValidTiebreak(winnerPoints: 6, loserPoints: 4))
        #expect(!ScoreRules.isValidTiebreak(winnerPoints: 9, loserPoints: 6))
        #expect(!ScoreRules.isValidTiebreak(winnerPoints: 7, loserPoints: -1))
    }

    @Test("Super tie-break: to 10, win by 2")
    func superTiebreaks() {
        #expect(ScoreRules.isValidSuperTiebreak(10, 0))
        #expect(ScoreRules.isValidSuperTiebreak(10, 8))
        #expect(ScoreRules.isValidSuperTiebreak(8, 10))
        #expect(ScoreRules.isValidSuperTiebreak(11, 9))
        #expect(ScoreRules.isValidSuperTiebreak(14, 16))
        #expect(!ScoreRules.isValidSuperTiebreak(10, 9))
        #expect(!ScoreRules.isValidSuperTiebreak(9, 7))
        #expect(!ScoreRules.isValidSuperTiebreak(11, 8))
        #expect(!ScoreRules.isValidSuperTiebreak(13, 10))
        #expect(!ScoreRules.isValidSuperTiebreak(10, -2))
    }

    @Test("Number of sets to enter")
    func expectedSetCount() {
        #expect(ScoreRules.expectedSetCount(format: .singleSet, sets: []) == 1)
        #expect(ScoreRules.expectedSetCount(format: .singleSet, sets: [set(6, 4), set(4, 6)]) == 1)
        #expect(ScoreRules.expectedSetCount(format: .bestOf3, sets: []) == 2)
        #expect(ScoreRules.expectedSetCount(format: .bestOf3, sets: [set(6, 4)]) == 2)
        #expect(ScoreRules.expectedSetCount(format: .bestOf3, sets: [set(6, 4), set(6, 3)]) == 2)
        #expect(ScoreRules.expectedSetCount(format: .bestOf3, sets: [set(6, 4), set(3, 6)]) == 3)
        #expect(ScoreRules.expectedSetCount(format: .bestOf3SuperTiebreak, sets: [set(4, 6), set(7, 5)]) == 3)
        #expect(ScoreRules.expectedSetCount(format: .bestOf3SuperTiebreak, sets: [set(4, 6), set(5, 7)]) == 2)
    }

    @Test("Best of three")
    func bestOfThree() {
        #expect(ScoreRules.validate(format: .bestOf3, sets: [set(6, 4), set(6, 3)]) == .success(1))
        #expect(ScoreRules.validate(format: .bestOf3, sets: [set(4, 6), set(6, 3), set(5, 7)]) == .success(2))
        #expect(ScoreRules.validate(format: .bestOf3, sets: [set(6, 4)]) == .failure(.incomplete))
        #expect(ScoreRules.validate(format: .bestOf3, sets: [set(6, 4), set(3, 6)]) == .failure(.incomplete))
        #expect(ScoreRules.validate(format: .bestOf3, sets: []) == .failure(.incomplete))
        #expect(ScoreRules.validate(format: .bestOf3, sets: [set(6, 4), set(6, 3), set(6, 2)]) == .failure(.extraSet))
        #expect(ScoreRules.validate(format: .bestOf3, sets: [set(6, 5), set(6, 3)]) == .failure(.invalidSet(1)))
        #expect(ScoreRules.validate(format: .bestOf3, sets: [set(6, 4), set(8, 6)]) == .failure(.invalidSet(2)))
        #expect(ScoreRules.validate(format: .bestOf3, sets: [set(6, 4), set(3, 6), superTiebreak(10, 8)])
                == .failure(.superTiebreakPlacement))
    }

    @Test("Tie-break points in a 7:6 set")
    func tiebreakPoints() {
        #expect(ScoreRules.validate(format: .bestOf3, sets: [set(7, 6, tb: (7, 4)), set(6, 4)]) == .success(1))
        #expect(ScoreRules.validate(format: .bestOf3, sets: [set(6, 7, tb: (4, 7)), set(4, 6)]) == .success(2))
        #expect(ScoreRules.validate(format: .bestOf3, sets: [set(7, 6, tb: (10, 8)), set(6, 2)]) == .success(1))
        // Tie-break points are optional.
        #expect(ScoreRules.validate(format: .bestOf3, sets: [set(7, 6), set(6, 2)]) == .success(1))
        // The set winner must win the tie-break.
        #expect(ScoreRules.validate(format: .bestOf3, sets: [set(7, 6, tb: (5, 7)), set(6, 4)]) == .failure(.invalidTiebreak(1)))
        #expect(ScoreRules.validate(format: .bestOf3, sets: [set(6, 4), set(7, 6, tb: (7, 6))]) == .failure(.invalidTiebreak(2)))
        // Tie-break points only belong to 7:6.
        #expect(ScoreRules.validate(format: .bestOf3, sets: [set(7, 5, tb: (7, 3)), set(6, 4)]) == .failure(.invalidTiebreak(1)))
        // Both values or none.
        let half = SetScore(t1: 7, t2: 6, superTiebreak: false, tb1: 7, tb2: nil)
        #expect(ScoreRules.validate(format: .bestOf3, sets: [half, set(6, 4)]) == .failure(.invalidTiebreak(1)))
    }

    @Test("Super tie-break only as the deciding set")
    func superTiebreakFormat() {
        let format = MatchFormat.bestOf3SuperTiebreak
        #expect(ScoreRules.validate(format: format, sets: [set(6, 4), set(4, 6), superTiebreak(10, 8)]) == .success(1))
        #expect(ScoreRules.validate(format: format, sets: [set(6, 4), set(4, 6), superTiebreak(9, 11)]) == .success(2))
        #expect(ScoreRules.validate(format: format, sets: [set(6, 4), set(6, 2)]) == .success(1))
        #expect(ScoreRules.validate(format: format, sets: [set(6, 4), set(4, 6), set(6, 3)]) == .failure(.superTiebreakPlacement))
        #expect(ScoreRules.validate(format: format, sets: [superTiebreak(10, 6), set(6, 4)]) == .failure(.superTiebreakPlacement))
        #expect(ScoreRules.validate(format: format, sets: [set(6, 4), set(4, 6), superTiebreak(10, 9)]) == .failure(.invalidSet(3)))
        #expect(ScoreRules.validate(format: format, sets: [set(6, 4), set(4, 6), superTiebreak(12, 9)]) == .failure(.invalidSet(3)))
        #expect(ScoreRules.validate(format: format, sets: [set(6, 4), set(4, 6)]) == .failure(.incomplete))
        #expect(ScoreRules.validate(format: format, sets: [set(6, 4), set(6, 2), superTiebreak(10, 3)]) == .failure(.extraSet))
    }

    @Test("Single set")
    func singleSet() {
        #expect(ScoreRules.validate(format: .singleSet, sets: [set(6, 3)]) == .success(1))
        #expect(ScoreRules.validate(format: .singleSet, sets: [set(5, 7)]) == .success(2))
        #expect(ScoreRules.validate(format: .singleSet, sets: [set(7, 6, tb: (7, 5))]) == .success(1))
        #expect(ScoreRules.validate(format: .singleSet, sets: []) == .failure(.incomplete))
        #expect(ScoreRules.validate(format: .singleSet, sets: [set(6, 5)]) == .failure(.invalidSet(1)))
        #expect(ScoreRules.validate(format: .singleSet, sets: [superTiebreak(10, 8)]) == .failure(.superTiebreakPlacement))
    }

    @Test("Games count a super tie-break as one game")
    func games() {
        let games = ScoreRules.games([set(6, 4), set(3, 6), superTiebreak(10, 8)])
        #expect(games.0 == 10)
        #expect(games.1 == 10)
        let straight = ScoreRules.games([set(7, 6, tb: (7, 2)), set(6, 0)])
        #expect(straight.0 == 13)
        #expect(straight.1 == 6)
    }

    @Test("Every issue has a message")
    func issueMessages() {
        let issues: [ScoreRules.Issue] = [.incomplete, .invalidSet(2), .invalidTiebreak(1), .extraSet, .superTiebreakPlacement]
        for issue in issues {
            #expect(!issue.message.isEmpty)
        }
        #expect(ScoreRules.Issue.invalidSet(2).message.contains("Сет 2"))
    }
}
