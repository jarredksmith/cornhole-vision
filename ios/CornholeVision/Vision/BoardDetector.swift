import Vision
import CoreVideo
import CoreGraphics

/// Finds rectangle candidates in a frame with Vision's rectangle detector.
/// Returns everything it sees; the calibrator decides which one is the board.
final class BoardDetector {
    struct Candidate {
        /// Polygon corners in Vision-normalized coordinates (origin bottom-left),
        /// in order around the polygon (not yet assigned to board corners).
        let polygon: [CGPoint]
        let confidence: Float
        var area: Double { Geometry.polygonArea(polygon) }
    }

    func detect(in pixelBuffer: CVPixelBuffer, maxCount: Int = 12) -> [Candidate] {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.12
        request.maximumAspectRatio = 1.0
        request.quadratureTolerance = 45
        request.minimumSize = 0.12
        request.maximumObservations = maxCount
        request.minimumConfidence = 0.3

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        guard let results = request.results else { return [] }
        return results.map {
            Candidate(polygon: [$0.topLeft, $0.topRight, $0.bottomRight, $0.bottomLeft], confidence: $0.confidence)
        }
    }
}

/// A locked board: where it is in the image and how to map between image and inches.
struct BoardLock {
    let quad: [CGPoint]           // c0..c3 in Vision-normalized image coords (c0,c1 = hole end)
    let imageToBoard: Homography  // vnorm -> inches
    let boardToImage: Homography  // inches -> vnorm
    let hole: BoardWarper.HoleFit // measured hole, in inches on the 24x48 map
    let manual: Bool
}

/// Turns rectangle candidates into a board lock.
///
/// The board is the rectangle that, warped flat, shows a dark round hole near
/// one short end. Every candidate is scored that way and evidence is
/// accumulated per candidate across frames, so a detector that flickers
/// between rectangles still converges on the one with the hole.
final class BoardCalibrator {
    struct Hypothesis {
        var quad: [CGPoint]           // oriented c0..c3 (hole end first), smoothed
        var hole: BoardWarper.HoleFit
        var score: Double             // EMA of per-frame score
        var hits: Int
        var lastSeen: Int
    }

    private(set) var hypotheses: [Hypothesis] = []
    private var frame = 0
    private var flipTried = false

    // Tunables
    var matchDrift = 0.035          // normalized image units; same rectangle if closer than this
    var minHoleContrast = 14.0      // luma levels darker than its surroundings
    var lockHits = 5
    var lockWindow = 14             // frames
    var mlHoleBonusRadius = 0.08    // normalized image units

    func reset() { hypotheses.removeAll(); frame = 0 }

    /// Best current guess (for the overlay), locked or not.
    var leading: Hypothesis? { hypotheses.max { $0.score * Double($0.hits) < $1.score * Double($1.hits) } }

    /// Feed one frame's candidates. `mlHole` is the Core ML hole-box centre (vnorm) if any.
    /// Returns a lock once a hypothesis has enough evidence.
    func update(candidates: [BoardDetector.Candidate], mlHole: CGPoint?, pixelBuffer: CVPixelBuffer, warper: BoardWarper) -> BoardLock? {
        frame += 1
        var seen = Set<Int>()

        // Biggest few rectangles only; the board is never a small one when the phone is set up right.
        let pool = candidates.filter { $0.area > 0.02 }.sorted { $0.area > $1.area }.prefix(6)

        for cand in pool {
            guard var (quad, hole) = bestOrientation(polygon: cand.polygon, pixelBuffer: pixelBuffer, warper: warper) else { continue }
            var s = hole.contrast * sqrt(max(cand.area, 1e-4)) * Double(0.5 + cand.confidence)
            if let ml = mlHole, let h = Homography(from: BoardSpec.cornersIn, to: quad) {
                // Where does the measured hole land in the image? Agreeing with the ML hole is strong evidence.
                var d = Geometry.distance(h.apply(hole.center), ml)
                if d >= mlHoleBonusRadius {
                    // If the hole would agree with the *other* end, the warp is rendering upside down:
                    // flip once and re-measure. (Core Image bitmap row order is the one unknown here.)
                    let mirrored = CGPoint(x: hole.center.x, y: BoardSpec.lengthIn - hole.center.y)
                    if Geometry.distance(h.apply(mirrored), ml) < mlHoleBonusRadius, !flipTried {
                        flipTried = true
                        warper.flipY.toggle()
                        if let again = bestOrientation(polygon: cand.polygon, pixelBuffer: pixelBuffer, warper: warper),
                           let h2 = Homography(from: BoardSpec.cornersIn, to: again.0) {
                            quad = again.0; hole = again.1
                            d = Geometry.distance(h2.apply(hole.center), ml)
                        }
                    }
                }
                s *= d < mlHoleBonusRadius ? 2.5 : 0.6
            }
            if let i = hypotheses.firstIndex(where: { Geometry.quadDrift($0.quad, quad) < matchDrift }) {
                var h = hypotheses[i]
                for k in 0..<4 {
                    h.quad[k] = CGPoint(x: h.quad[k].x * 0.7 + quad[k].x * 0.3, y: h.quad[k].y * 0.7 + quad[k].y * 0.3)
                }
                h.hole = hole
                h.score = h.score * 0.7 + s * 0.3
                h.hits += 1
                h.lastSeen = frame
                hypotheses[i] = h
                seen.insert(i)
            } else {
                hypotheses.append(Hypothesis(quad: quad, hole: hole, score: s, hits: 1, lastSeen: frame))
                seen.insert(hypotheses.count - 1)
            }
        }

        // Forget hypotheses that haven't been seen for a while.
        hypotheses.removeAll { frame - $0.lastSeen > lockWindow }
        hypotheses.sort { $0.score * Double($0.hits) > $1.score * Double($1.hits) }

        guard let best = hypotheses.first, best.hits >= lockHits, best.hole.contrast >= minHoleContrast else { return nil }
        // Require a clear margin over the runner-up so we don't lock onto a coin flip.
        if hypotheses.count > 1 {
            let second = hypotheses[1]
            if second.hits >= lockHits && second.score * Double(second.hits) > best.score * Double(best.hits) * 0.8 { return nil }
        }
        return makeLock(quad: best.quad, hole: best.hole, manual: false)
    }

    /// Lock from four user-tapped corners (vnorm). First two taps are the hole end.
    func lockManually(corners: [CGPoint], pixelBuffer: CVPixelBuffer, warper: BoardWarper) -> BoardLock? {
        guard corners.count == 4 else { return nil }
        // Order: back-left, back-right, front-right, front-left.
        // The user gave back pair (0,1) and front pair (2,3); pick the pairing that forms a simple quad.
        let a = corners[0], b = corners[1], c = corners[2], d = corners[3]
        var quad = [a, b, c, d]
        if segmentsCross(a, b, c, d) || segmentsCross(b, c, d, a) { quad = [a, b, d, c] }
        // Make the polygon wind consistently (clockwise in image space with y up => use signed area).
        if signedArea(quad) < 0 { quad = [quad[1], quad[0], quad[3], quad[2]] }
        guard warper.warp(pixelBuffer: pixelBuffer, quad: quad) else { return nil }
        let hole = warper.findHole() ?? BoardWarper.HoleFit(center: BoardSpec.holeCenter, radius: BoardSpec.holeRadiusIn, contrast: 0)
        return makeLock(quad: quad, hole: hole, manual: true)
    }

    private func makeLock(quad: [CGPoint], hole: BoardWarper.HoleFit, manual: Bool) -> BoardLock? {
        guard let h = Homography(from: quad, to: BoardSpec.cornersIn), let hInv = h.inverted() else { return nil }
        return BoardLock(quad: quad, imageToBoard: h, boardToImage: hInv, hole: hole, manual: manual)
    }

    /// Try the cyclic corner assignments; return the one whose warp shows the best hole in
    /// its top half (so c0-c1 is the hole end). Orientations that make the short edges the
    /// board's width are tried first; the others only if those show no hole.
    private func bestOrientation(polygon: [CGPoint], pixelBuffer: CVPixelBuffer, warper: BoardWarper) -> ([CGPoint], BoardWarper.HoleFit)? {
        let e01 = Geometry.distance(polygon[0], polygon[1]) + Geometry.distance(polygon[2], polygon[3])
        let e12 = Geometry.distance(polygon[1], polygon[2]) + Geometry.distance(polygon[3], polygon[0])
        let preferred = e01 <= e12 ? [0, 2] : [1, 3]
        let fallback = e01 <= e12 ? [1, 3] : [0, 2]
        for group in [preferred, fallback] {
            var best: ([CGPoint], BoardWarper.HoleFit)?
            for k in group {
                let quad = (0..<4).map { polygon[(k + $0) % 4] }
                guard warper.warp(pixelBuffer: pixelBuffer, quad: quad), let fit = warper.findHole(),
                      fit.center.y <= BoardSpec.lengthIn / 2 else { continue }
                if best == nil || fit.contrast > best!.1.contrast { best = (quad, fit) }
            }
            if let best, best.1.contrast >= minHoleContrast * 0.5 { return best }
        }
        return nil
    }

    private func segmentsCross(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> Bool {
        func orient(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
            Double((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x))
        }
        let d1 = orient(p3, p4, p1), d2 = orient(p3, p4, p2), d3 = orient(p1, p2, p3), d4 = orient(p1, p2, p4)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    private func signedArea(_ pts: [CGPoint]) -> Double {
        var s = 0.0
        for i in 0..<pts.count {
            let p = pts[i], q = pts[(i + 1) % pts.count]
            s += Double(p.x * q.y - q.x * p.y)
        }
        return s * 0.5
    }
}
