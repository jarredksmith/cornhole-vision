import Foundation
import CoreGraphics

enum BagState: String, Codable {
    case moving     // sliding / just landed
    case resting    // on the board, still  -> 1 point
    case inHole     // disappeared into the hole -> 3 points
    case off        // slid off an edge -> 0
    case lost       // noise / occluded and never came back
}

struct BagTrack: Identifiable {
    let id: Int
    var team: Int
    var position: CGPoint        // inches
    var velocity: CGPoint        // inches / frame
    var state: BagState
    var hits = 1                 // frames seen
    var missed = 0               // consecutive frames not seen
    var stillFrames = 0
    var areaIn2: Double
    var bornAtFrame: Int
    var resolvedAtFrame: Int?    // when it became inHole / off / lost
    var teamVotes: [Int: Int] = [:]
    var inHoleHint = false       // the ML detector last saw it as 'bag_in_hole'

    var counts: Bool { state == .resting || state == .inHole }
}

/// Follows bags across frames so we know where each one *ended up*, which is
/// what scoring needs: a bag that vanished at the hole went in; a bag that
/// vanished at an edge slid off; a bag that stopped is a woody.
final class BagTracker {
    private(set) var tracks: [BagTrack] = []
    private(set) var frame = 0
    private var nextId = 1

    // Tunables (inches / frames at ~30 fps)
    var gateMoving = 10.0
    var gateResting = 4.0
    var stillDelta = 0.35
    var framesToRest = 10
    var framesToResolve = 4
    var occludedKeepFrames = 90
    var minHitsToConfirm = 3

    /// Measured at lock time (regulation: (12, 9), r = 3).
    var holeCenter = BoardSpec.holeCenter
    var holeRadius = BoardSpec.holeRadiusIn

    func reset() { tracks.removeAll(); frame = 0 }

    /// Remove resolved/finished tracks between rounds.
    func clearForNewRound() { tracks.removeAll() }

    func update(detections: [BagDetection], teamOf: (BagDetection) -> Int) {
        frame += 1

        // 1. Match detections to live tracks (greedy nearest neighbour).
        var pairs: [(dist: Double, t: Int, d: Int)] = []
        for (ti, t) in tracks.enumerated() where t.state == .moving || t.state == .resting {
            let predicted = CGPoint(x: t.position.x + t.velocity.x * 0.5, y: t.position.y + t.velocity.y * 0.5)
            for (di, d) in detections.enumerated() {
                let dist = Geometry.distance(predicted, d.position)
                let gate = t.state == .resting ? gateResting : gateMoving
                if dist < gate { pairs.append((dist, ti, di)) }
            }
        }
        pairs.sort { $0.dist < $1.dist }
        var trackMatched = [Bool](repeating: false, count: tracks.count)
        var detMatched = [Bool](repeating: false, count: detections.count)
        for p in pairs where !trackMatched[p.t] && !detMatched[p.d] {
            trackMatched[p.t] = true
            detMatched[p.d] = true
            let d = detections[p.d]
            var t = tracks[p.t]
            let delta = Geometry.distance(t.position, d.position)
            t.velocity = CGPoint(x: (d.position.x - t.position.x) * 0.6 + t.velocity.x * 0.4,
                                 y: (d.position.y - t.position.y) * 0.6 + t.velocity.y * 0.4)
            t.position = d.position
            t.areaIn2 = d.areaIn2
            t.inHoleHint = d.inHoleHint
            t.hits += 1
            t.missed = 0
            if delta < stillDelta {
                t.stillFrames += 1
                if t.stillFrames >= framesToRest { t.state = .resting }
            } else {
                t.stillFrames = 0
                t.state = .moving
            }
            // Vote on the team for the first second so one shadowed frame can't mislabel a bag.
            if t.hits <= 30 {
                let v = teamOf(d)
                t.teamVotes[v, default: 0] += 1
                if let best = t.teamVotes.max(by: { $0.value < $1.value }) { t.team = best.key }
            }
            tracks[p.t] = t
        }

        // 2. Unmatched live tracks: count a miss, resolve after a few frames.
        for ti in tracks.indices where !trackMatched[ti] && (tracks[ti].state == .moving || tracks[ti].state == .resting) {
            var t = tracks[ti]
            t.missed += 1
            if t.hits < minHitsToConfirm {
                t.state = .lost
                t.resolvedAtFrame = frame
            } else if t.missed >= framesToResolve && t.resolvedAtFrame == nil {
                let dHole = Double(hypot(t.position.x - holeCenter.x, t.position.y - holeCenter.y))
                let dEdge = BoardSpec.distanceToEdge(t.position)
                // Where was it heading? Extrapolate half a bag length.
                let ahead = CGPoint(x: t.position.x + t.velocity.x * 2, y: t.position.y + t.velocity.y * 2)
                let aheadHole = Double(hypot(ahead.x - holeCenter.x, ahead.y - holeCenter.y))
                if dHole < holeRadius + 2.0 || aheadHole < holeRadius + 0.5
                    || (t.inHoleHint && dHole < holeRadius + 4.0) {
                    t.state = .inHole
                    t.resolvedAtFrame = frame
                } else if dEdge < 2.5 || !BoardSpec.isInsideBoard(ahead) {
                    t.state = .off
                    t.resolvedAtFrame = frame
                } else if t.state == .resting && t.hits >= 20 {
                    // Established bag vanished mid-board: probably a hand/leg in the way. Keep waiting.
                    if t.missed > occludedKeepFrames {
                        t.state = .lost
                        t.resolvedAtFrame = frame
                    }
                } else {
                    t.state = .lost
                    t.resolvedAtFrame = frame
                }
            }
            tracks[ti] = t
        }

        // 3. Unmatched detections: revive a just-resolved track nearby, else spawn.
        for (di, d) in detections.enumerated() where !detMatched[di] {
            if let ri = tracks.firstIndex(where: {
                ($0.state == .inHole || $0.state == .off || $0.state == .lost)
                    && ($0.resolvedAtFrame.map { frame - $0 < 20 } ?? false)
                    && Geometry.distance($0.position, d.position) < 4.0
            }) {
                var t = tracks[ri]
                t.state = .moving
                t.resolvedAtFrame = nil
                t.missed = 0
                t.stillFrames = 0
                t.position = d.position
                t.velocity = .zero
                tracks[ri] = t
                continue
            }
            let team = teamOf(d)
            var t = BagTrack(id: nextId, team: team, position: d.position, velocity: .zero,
                             state: .moving, areaIn2: d.areaIn2, bornAtFrame: frame)
            t.teamVotes[team] = 1
            nextId += 1
            tracks.append(t)
        }

        // 4. Drop noise and old lost tracks; keep inHole/off (they're part of the round).
        tracks.removeAll { t in
            t.state == .lost && (frame - (t.resolvedAtFrame ?? frame) > 30 || t.hits < minHitsToConfirm)
        }
    }

    /// Confirmed tracks only (seen for a few frames).
    var confirmed: [BagTrack] { tracks.filter { $0.hits >= minHitsToConfirm && $0.state != .lost } }

    var anyMoving: Bool { tracks.contains { $0.state == .moving && $0.hits >= minHitsToConfirm } }
}
