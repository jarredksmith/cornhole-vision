import Foundation

/// Cancellation scoring, game to `target` (ACL rules: first to 21 at the end of
/// a round wins, no bust).
final class ScoringEngine {
    private(set) var scores = [0, 0]
    private(set) var rounds: [RoundResult] = []
    var target: Int

    init(target: Int = AppConfig.targetScore) { self.target = target }

    var roundNumber: Int { rounds.count + 1 }

    var winner: Int? {
        if scores[0] >= target && scores[0] > scores[1] { return 0 }
        if scores[1] >= target && scores[1] > scores[0] { return 1 }
        return nil
    }

    func reset() {
        scores = [0, 0]
        rounds.removeAll()
    }

    @discardableResult
    func commit(a: RoundCounts, b: RoundCounts, board: Int) -> RoundResult {
        let diff = a.points - b.points
        let result = RoundResult(number: roundNumber, board: board, a: a, b: b,
                                 pointsA: max(0, diff), pointsB: max(0, -diff))
        rounds.append(result)
        scores[0] += result.pointsA
        scores[1] += result.pointsB
        return result
    }

    @discardableResult
    func undo() -> RoundResult? {
        guard let last = rounds.popLast() else { return nil }
        scores[0] -= last.pointsA
        scores[1] -= last.pointsB
        return last
    }

    /// Replace local history with the server's (two-phone games).
    func apply(rounds remote: [RoundResult]) {
        rounds = remote
        scores = [remote.reduce(0) { $0 + $1.pointsA }, remote.reduce(0) { $0 + $1.pointsB }]
    }
}
