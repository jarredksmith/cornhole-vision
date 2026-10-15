import Foundation
import CoreVideo
import CoreGraphics
import QuartzCore

/// Everything that touches pixels lives here and runs on a private serial queue.
/// The view model talks to it through `enqueue` and listens via `onEvent`
/// (delivered on the main queue).
final class VisionPipeline {
    enum Mode { case idle, calibrating, tracking, paused }

    enum Event {
        /// Not locked yet. `polygon` is the leading guess (oriented, hole end first), `hole` is where
        /// the ML model sees a hole in the image (vnorm), `candidates` how many rectangles were seen.
        case searching(polygon: [CGPoint]?, hole: CGPoint?, candidates: Int)
        case locked(BoardLock, modelLoaded: Bool)
        case frame(FrameReport)
        case boardMoved                                        // locked board drifted; re-calibrating
    }

    struct FrameReport {
        let tracks: [BagTrack]
        let teams: [TeamColorModel.TeamColor]
        let anyMoving: Bool
        let boardEmpty: Bool
        let fps: Double
        let detectionCount: Int
    }

    let queue = DispatchQueue(label: "cornhole.vision", qos: .userInteractive)
    var onEvent: ((Event) -> Void)?

    private let detector = BoardDetector()
    private let calibrator = BoardCalibrator()
    private let warper = BoardWarper()
    private let colorDetector = ColorBagDetector()
    private let mlDetector = CoreMLBagDetector()
    private let teamModel = TeamColorModel()
    private let tracker = BagTracker()

    private var mode: Mode = .idle
    private var lock: BoardLock?
    private var pendingManualCorners: [CGPoint]?
    private var lastMLHole: (point: CGPoint, frame: Int)?
    private var frameIndex = 0
    private var emptyFrames = 0
    private var driftFrames = 0
    private var lastFrameTime = CACurrentMediaTime()
    private var fps = 0.0
    private let inFlight = DispatchSemaphore(value: 1)

    /// Use the Core ML model when it is bundled (true) or colour-only (false).
    var useML = true

    // MARK: - Control (callable from any thread)

    func enqueue(_ work: @escaping (VisionPipeline) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            work(self)
        }
    }

    func startCalibration() {
        enqueue { p in
            p.mode = .calibrating
            p.lock = nil
            p.pendingManualCorners = nil
            p.lastMLHole = nil
            p.calibrator.reset()
            p.colorDetector.resetReference()
            p.tracker.reset()
            p.emptyFrames = 0
            p.driftFrames = 0
        }
    }

    /// Lock from four tapped corners (vnorm), hole-end pair first. Applied on the next frame.
    func lockManually(corners: [CGPoint]) {
        enqueue { p in
            p.pendingManualCorners = corners
            p.mode = .calibrating
        }
    }

    func pause() { enqueue { $0.mode = .paused } }
    func resume() { enqueue { p in if p.lock != nil { p.mode = .tracking } else { p.mode = .calibrating } } }
    func stop() { enqueue { $0.mode = .idle } }

    /// Forget the bags of the last round (keeps the board lock and team colours).
    func newRound() { enqueue { $0.tracker.clearForNewRound() } }

    func resetTeams() { enqueue { $0.teamModel.reset() } }

    /// Second phone: adopt the host's team colours so team 0/1 mean the same thing on both.
    func seedTeams(_ rgb: [(Double, Double, Double)]) { enqueue { $0.teamModel.seed(rgb) } }

    // MARK: - Frames

    /// Called from the camera queue. Drops frames while one is still being processed.
    func submit(_ pixelBuffer: CVPixelBuffer) {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        queue.async { [weak self] in
            defer { self?.inFlight.signal() }
            self?.process(pixelBuffer)
        }
    }

    private func process(_ pb: CVPixelBuffer) {
        frameIndex += 1
        let now = CACurrentMediaTime()
        let dt = now - lastFrameTime
        lastFrameTime = now
        if dt > 0 { fps = fps * 0.9 + (1 / dt) * 0.1 }

        switch mode {
        case .idle, .paused:
            return
        case .calibrating:
            calibrate(pb)
        case .tracking:
            track(pb)
        }
    }

    private func calibrate(_ pb: CVPixelBuffer) {
        // Manual corners win immediately.
        if let corners = pendingManualCorners {
            pendingManualCorners = nil
            if let lock = calibrator.lockManually(corners: corners, pixelBuffer: pb, warper: warper) {
                finishLock(lock, pb)
                return
            }
        }
        // Rectangle detection is the expensive part; every other frame is plenty.
        guard frameIndex % 2 == 0 else { return }

        // The ML model is good at spotting the hole even when it can't see the board.
        if useML, let ml = mlDetector, frameIndex % 4 == 0 {
            let holes = ml.detect(pb).filter { $0.label == "hole" }
            if let h = holes.max(by: { $0.confidence < $1.confidence }) {
                lastMLHole = (CGPoint(x: h.box.midX, y: h.box.midY), frameIndex)
            }
        }
        let mlHole = lastMLHole.flatMap { frameIndex - $0.frame < 30 ? $0.point : nil }

        let candidates = detector.detect(in: pb)
        if let lock = calibrator.update(candidates: candidates, mlHole: mlHole, pixelBuffer: pb, warper: warper) {
            finishLock(lock, pb)
            return
        }
        emit(.searching(polygon: calibrator.leading?.quad, hole: mlHole, candidates: candidates.count))
    }

    private func finishLock(_ lock: BoardLock, _ pb: CVPixelBuffer) {
        self.lock = lock
        warper.warp(pixelBuffer: pb, quad: lock.quad)
        colorDetector.captureReference(warper.pixels)
        tracker.reset()
        tracker.holeCenter = lock.hole.center
        tracker.holeRadius = lock.hole.radius
        emptyFrames = 0
        driftFrames = 0
        mode = .tracking
        emit(.locked(lock, modelLoaded: mlDetector != nil))
    }

    private func track(_ pb: CVPixelBuffer) {
        guard let lock else { mode = .calibrating; return }
        guard warper.warp(pixelBuffer: pb, quad: lock.quad) else { return }

        // Colour detector works on the board map.
        let quiet = !tracker.anyMoving
        var detections = colorDetector.detect(warper.pixels, learnBackground: quiet)

        // Optional Core ML detector on the full frame, mapped into board inches.
        if useML, let ml = mlDetector, frameIndex % 2 == 0 {
            let obs = ml.detect(pb)
            var mlDets: [BagDetection] = []
            for o in obs where o.label == "bag" || o.label == "bag_in_hole" {
                let center = CGPoint(x: o.box.midX, y: o.box.midY)
                let inches = lock.imageToBoard.apply(center)
                guard BoardSpec.isInsideBoard(inches, margin: 1.5) else { continue }
                let c = warper.sampleColor(atInches: inches)
                // Approximate area from the box size projected onto the board.
                let corner = lock.imageToBoard.apply(CGPoint(x: o.box.minX, y: o.box.minY))
                let corner2 = lock.imageToBoard.apply(CGPoint(x: o.box.maxX, y: o.box.maxY))
                let area = min(60, abs(Double(corner2.x - corner.x) * Double(corner2.y - corner.y)))
                mlDets.append(BagDetection(position: inches, areaIn2: area, r: c.r, g: c.g, b: c.b,
                                           inHoleHint: o.label == "bag_in_hole", source: .ml))
            }
            // Merge: ML detections replace colour blobs within 3 in; unmatched colour blobs stay.
            if !mlDets.isEmpty {
                detections = detections.filter { cd in
                    !mlDets.contains { Geometry.distance($0.position, cd.position) < 3.0 }
                } + mlDets
            }
        }

        tracker.update(detections: detections) { [teamModel] d in
            teamModel.assign(r: d.r, g: d.g, b: d.b, learn: true)
        }

        // Refresh the background reference whenever the board has been empty for a second
        // (between rounds) so lighting changes never accumulate.
        if detections.isEmpty && tracker.confirmed.allSatisfy({ $0.state != .resting && $0.state != .moving }) {
            emptyFrames += 1
            if emptyFrames == 30 { colorDetector.captureReference(warper.pixels) }
        } else {
            emptyFrames = 0
        }

        // Every ~2 s check the board hasn't been bumped. Only re-lock when there's
        // nothing on the board, otherwise we'd lose the round.
        if !lock.manual, frameIndex % 60 == 0, tracker.confirmed.isEmpty {
            // The board moved if our locked quad no longer shows the hole (the warper currently
            // holds this frame's warp of the locked quad) AND a big rectangle sits somewhere else.
            let holeGone = (warper.findHole()?.contrast ?? 0) < 8
            let moved = holeGone && detector.detect(in: pb).contains { cand in
                cand.area > Geometry.polygonArea(lock.quad) * 0.6 && minDrift(cand.polygon, to: lock.quad) > 0.03
            }
            driftFrames = moved ? driftFrames + 1 : 0
            if driftFrames >= 2 {
                emit(.boardMoved)
                startCalibration()
                return
            }
        }

        let report = FrameReport(tracks: tracker.confirmed, teams: teamModel.teams, anyMoving: tracker.anyMoving,
                                 boardEmpty: emptyFrames >= 30, fps: fps, detectionCount: detections.count)
        emit(.frame(report))
    }

    /// Smallest corner drift over the four cyclic orderings (we don't care which corner is which here).
    private func minDrift(_ a: [CGPoint], to b: [CGPoint]) -> Double {
        var best = Double.infinity
        for k in 0..<4 {
            let rotated = (0..<4).map { a[(k + $0) % 4] }
            best = min(best, Geometry.quadDrift(rotated, b))
        }
        return best
    }

    private func emit(_ e: Event) {
        guard let onEvent else { return }
        DispatchQueue.main.async { onEvent(e) }
    }
}
