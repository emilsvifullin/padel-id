import Foundation

/// Padel scoring rules used to guide score entry. They mirror the server-side
/// validation (`private.validate_score`), which remains authoritative.
nonisolated enum ScoreRules {
    /// All valid results of a regular 6-game set from team 1's perspective.
    static let regularSetResults: [(Int, Int)] = {
        var results: [(Int, Int)] = []
        for lo in 0...4 { results.append((6, lo)) }
        results.append((7, 5))
        results.append((7, 6))
        for lo in 0...4 { results.append((lo, 6)) }
        results.append((5, 7))
        results.append((6, 7))
        return results
    }()

    static func isValidRegularSet(_ a: Int, _ b: Int) -> Bool {
        let hi = max(a, b), lo = min(a, b)
        return (hi == 6 && lo <= 4) || (hi == 7 && (lo == 5 || lo == 6))
    }

    static func isValidTiebreak(winnerPoints w: Int, loserPoints l: Int) -> Bool {
        guard w >= 0, l >= 0 else { return false }
        return (w == 7 && l <= 5) || (w > 7 && w - l == 2)
    }

    static func isValidSuperTiebreak(_ a: Int, _ b: Int) -> Bool {
        let hi = max(a, b), lo = min(a, b)
        guard lo >= 0 else { return false }
        return (hi == 10 && lo <= 8) || (hi > 10 && hi - lo == 2)
    }

    enum Issue: Error, Equatable, Sendable {
        case incomplete
        case invalidSet(Int)
        case invalidTiebreak(Int)
        case extraSet
        case superTiebreakPlacement

        var message: String {
            switch self {
            case .incomplete: "Матч не завершён: введите все сеты до победы одной из пар."
            case .invalidSet(let n): "Сет \(n): такой счёт невозможен по правилам."
            case .invalidTiebreak(let n): "Сет \(n): проверьте счёт тай-брейка."
            case .extraSet: "Лишний сет: матч уже решён."
            case .superTiebreakPlacement: "Супертай-брейк возможен только в решающем сете."
            }
        }
    }

    /// Number of sets that should be shown for entry given the current sets.
    static func expectedSetCount(format: MatchFormat, sets: [SetScore]) -> Int {
        switch format {
        case .singleSet: return 1
        case .bestOf3, .bestOf3SuperTiebreak:
            guard sets.count >= 2 else { return 2 }
            let w1 = sets[0].winner, w2 = sets[1].winner
            return w1 == w2 ? 2 : 3
        }
    }

    /// Validates a full score; returns the winning team or the first issue.
    static func validate(format: MatchFormat, sets: [SetScore]) -> Result<Int, Issue> {
        var won1 = 0, won2 = 0
        for (index, set) in sets.enumerated() {
            let n = index + 1
            if won1 == 2 || won2 == 2 { return .failure(.extraSet) }
            if set.superTiebreak {
                guard format == .bestOf3SuperTiebreak, index == 2 else { return .failure(.superTiebreakPlacement) }
                guard isValidSuperTiebreak(set.t1, set.t2) else { return .failure(.invalidSet(n)) }
            } else {
                if format == .bestOf3SuperTiebreak && index == 2 { return .failure(.superTiebreakPlacement) }
                guard isValidRegularSet(set.t1, set.t2) else { return .failure(.invalidSet(n)) }
                if let a = set.tb1, let b = set.tb2 {
                    guard max(set.t1, set.t2) == 7 && min(set.t1, set.t2) == 6 else { return .failure(.invalidTiebreak(n)) }
                    let ok = set.t1 > set.t2 ? isValidTiebreak(winnerPoints: a, loserPoints: b) : isValidTiebreak(winnerPoints: b, loserPoints: a)
                    guard ok else { return .failure(.invalidTiebreak(n)) }
                } else if (set.tb1 == nil) != (set.tb2 == nil) {
                    return .failure(.invalidTiebreak(n))
                }
            }
            if set.t1 > set.t2 { won1 += 1 } else { won2 += 1 }
        }
        switch format {
        case .singleSet:
            return sets.count == 1 ? .success(won1 > won2 ? 1 : 2) : .failure(.incomplete)
        case .bestOf3, .bestOf3SuperTiebreak:
            return max(won1, won2) == 2 ? .success(won1 > won2 ? 1 : 2) : .failure(.incomplete)
        }
    }

    /// Games won by each team (a super tie-break counts as one game).
    static func games(_ sets: [SetScore]) -> (Int, Int) {
        sets.reduce((0, 0)) { acc, set in
            if set.superTiebreak {
                return set.t1 > set.t2 ? (acc.0 + 1, acc.1) : (acc.0, acc.1 + 1)
            }
            return (acc.0 + set.t1, acc.1 + set.t2)
        }
    }
}
