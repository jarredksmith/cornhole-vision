import Vision
import CoreVideo
import CoreGraphics

/// Finds the board quadrilateral in a frame with Vision's rectangle detector.
final class BoardDetector {
    struct Candidate {
        /// Polygon corners in Vision-normalized coordinates (origin bottom-left),
        /// in order around the polygon (not yet assigned to board corners).
        let polygon: [CGPoint]
        let confidence: Float
        var area: Double { Geometry.polygonArea(polygon) }
    }

    func detect(in pixelBuffer: CVPixelBuffer) -> Candidate? {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.12
        request.maximumAspectRatio = 1.0
        request.quadratureTolerance = 45
        request.minimumSize = 0.10
        request.maximumObservations = 8
        request.minimumConfidence = 0.5

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let results = request.results, !results.isEmpty else { return nil }

        var best: Candidate?
        var bestScore = 0.0
        for obs in results {
            let poly = [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft]
            let c = Candidate(polygon: poly, confidence: obs.confidence)
            // Prefer big, confident rectangles with a 2:1-ish shape.
            let score = c.area * Double(obs.confidence) * shapePrior(poly)
            if score > bestScore { bestScore = score; best = c }
        }
        return best
    }

    /// 1.0 for a quad whose opposite-edge lengths suggest a 2:1 board, lower otherwise.
    private func shapePrior(_ p: [CGPoint]) -> Double {
        let e0 = Geometry.distance(p[0], p[1]) + Geometry.distance(p[2], p[3])
        let e1 = Geometry.distance(p[1], p[2]) + Geometry.distance(p[3], p[0])
        let ratio = min(e0, e1) / max(e0, e1, 1e-6)
        // Foreshortening can make the ratio anything from ~0.2 to ~0.9; squares are suspicious.
        return ratio > 0.92 ? 0.5 : 1.0
    }
}

/// Accumulates detections until the board is still, then decides which
/// polygon corner is which board corner by looking for the hole.
final class BoardCalibrator {
    struct Lock {
        let quad: [CGPoint]           // c0..c3 in Vision-normalized image coords
        let imageToBoard: Homography  // vnorm -> inches
        let boardToImage: Homography  // inches -> vnorm
        let holeContrast: Double
    }

    private var history: [[CGPoint]] = []
    private let requiredFrames = 8
    private let maxDrift = 0.006  // normalized image units (~8 px at 1280 wide)

    func reset() { history.removeAll() }

    /// Feed a candidate polygon; returns the averaged polygon once stable.
    func push(_ polygon: [CGPoint]) -> [CGPoint]? {
        if let last = history.last, Geometry.quadDrift(last, polygon) > maxDrift {
            history.removeAll()
        }
        history.append(polygon)
        if history.count > requiredFrames { history.removeFirst() }
        guard history.count == requiredFrames else { return nil }
        return Geometry.average(history)
    }

    /// Try the four cyclic corner assignments and pick the one where a dark
    /// 6 in disc sits 9 in from the back edge. Returns nil if none is plausible.
    func resolveOrientation(polygon: [CGPoint], pixelBuffer: CVPixelBuffer, warper: BoardWarper) -> Lock? {
        if let lock = resolve(polygon: polygon, pixelBuffer: pixelBuffer, warper: warper) { return lock }
        // Defensive: if the render path ever comes out bottom-up, the hole shows at the
        // mirrored end for every assignment. Flip once and retry.
        warper.flipY.toggle()
        if let lock = resolve(polygon: polygon, pixelBuffer: pixelBuffer, warper: warper) { return lock }
        warper.flipY.toggle()
        return nil
    }

    private func resolve(polygon: [CGPoint], pixelBuffer: CVPixelBuffer, warper: BoardWarper) -> Lock? {
        var best: Lock?
        var bestScore = -Double.infinity
        for k in 0..<4 {
            let quad = (0..<4).map { polygon[(k + $0) % 4] }
            // width edges: c0c1 & c2c3, length edges: c1c2 & c3c0 — the board is 2x longer than wide,
            // so the width edges should be the shorter pair unless foreshortening is extreme.
            let widthLen = Geometry.distance(quad[0], quad[1]) + Geometry.distance(quad[2], quad[3])
            let lengthLen = Geometry.distance(quad[1], quad[2]) + Geometry.distance(quad[3], quad[0])
            let shapePenalty = widthLen > lengthLen * 1.15 ? 0.4 : 1.0

            guard warper.warp(pixelBuffer: pixelBuffer, quad: quad) else { continue }
            let inside = warper.meanLuma(centerIn: BoardSpec.holeCenter, innerIn: 0, outerIn: 2.4)
            let ring = warper.meanLuma(centerIn: BoardSpec.holeCenter, innerIn: 3.6, outerIn: 5.6)
            // Also check the mirror position (front end) is NOT dark — breaks symmetry further.
            let mirror = CGPoint(x: BoardSpec.holeCenter.x, y: BoardSpec.lengthIn - BoardSpec.holeCenter.y)
            let mirrorInside = warper.meanLuma(centerIn: mirror, innerIn: 0, outerIn: 2.4)
            let mirrorRing = warper.meanLuma(centerIn: mirror, innerIn: 3.6, outerIn: 5.6)
            let contrast = (ring - inside) - 0.5 * (mirrorRing - mirrorInside)
            let score = contrast * shapePenalty
            if score > bestScore,
               let h = Homography(from: quad, to: BoardSpec.cornersIn),
               let hInv = h.inverted() {
                bestScore = score
                best = Lock(quad: quad, imageToBoard: h, boardToImage: hInv, holeContrast: contrast)
            }
        }
        // Require a visible hole: at least ~12 luma levels darker than its surroundings.
        guard let lock = best, lock.holeContrast > 12 else { return nil }
        return lock
    }
}
