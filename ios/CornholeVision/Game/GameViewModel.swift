import Foundation
import SwiftUI
import AVFoundation
import CoreMotion
import Combine

enum GamePhase: Equatable {
    case lobby
    case cameraDenied
    case findingBoard          // looking for / locking onto the board
    case ready                 // locked; throw bags, round scores itself
    case roundOver(RoundResult)
    case moveToOtherBoard      // solo mode: carry the phone to the other board
    case waitingOtherBoard     // two-phone mode: the other board is live
    case finished(winner: Int)
}

@MainActor
final class GameViewModel: ObservableObject {
    // MARK: Published UI state
    @Published var phase: GamePhase = .lobby
    @Published var gameCode = ""
    @Published var isTwoPhone = false
    @Published var myBoard = 1
    @Published var teams: [TeamInfo] = [TeamInfo(name: "Team 1", color: "#9E9E9E"), TeamInfo(name: "Team 2", color: "#616161")]
    @Published var scores = [0, 0]
    @Published var rounds: [RoundResult] = []
    @Published var roundNumber = 1
    @Published var roundA = RoundCounts()
    @Published var roundB = RoundCounts()
    @Published var liveTracks: [BagTrack] = []
    @Published var overrides: [Int: BagState] = [:]
    @Published var boardQuad: [CGPoint]? = nil
    @Published var candidatePolygon: [CGPoint]? = nil
    @Published var candidateHole: CGPoint? = nil          // vnorm, from the ML model while searching
    @Published var boardToImage: Homography? = nil
    @Published var holeCenter: CGPoint = BoardSpec.holeCenter
    @Published var holeRadius: Double = BoardSpec.holeRadiusIn
    @Published var searchMessage = "Looking for the board"
    @Published var manualCorners: [CGPoint] = []           // vnorm taps collected in manual mode
    @Published var manualMode = false
    @Published var searchSeconds = 0.0
    @Published var quietSeconds = 0.0
    @Published var syncStatus: SyncClient.Status = .off
    @Published var fps = 0.0
    @Published var modelLoaded = false
    @Published var detectionCount = 0
    @Published var lastMessage = ""
    @Published var showDebug = false { didSet { pipeline.debugImages = showDebug; if !showDebug { debugMap = nil } } }
    @Published var debugMap: CGImage? = nil
    @Published var foregroundFraction = 0.0

    // MARK: Services
    let camera = CameraManager()
    let pipeline = VisionPipeline()
    let sync = SyncClient()
    private let engine = ScoringEngine()
    private let motion = CMMotionManager()
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    // MARK: Round bookkeeping
    private var roundActive = false
    private var lastActivity = Date()
    private var lastTrackCount = 0
    private var lastLiveSent: LiveState?
    private var teamNamesCustomized = [false, false]
    private var roundOverTask: Task<Void, Never>?
    private var remoteActiveBoard = 1
    private var sentSetup = false
    private var searchStarted = Date()
    private var lastSearchMessageChange = Date.distantPast

    init() {
        pipeline.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        let visionPipeline = pipeline
        camera.onFrame = { pb in visionPipeline.submit(pb) }
        sync.onStatus = { [weak self] s in
            Task { @MainActor in
                guard let self else { return }
                self.syncStatus = s
                // After a (re)connect, make sure the room knows the teams and target.
                if s == .connected, self.sentSetup, self.myBoard == 1 {
                    self.sync.sendSetup(teams: self.teams, target: AppConfig.targetScore)
                }
            }
        }
        sync.onState = { [weak self] st in
            Task { @MainActor in self?.applyRemote(st) }
        }
    }

    // MARK: - Lobby actions

    func startSolo() { start(code: GameCode.random(), twoPhone: false, board: 1) }
    func hostTwoPhone() { start(code: GameCode.random(), twoPhone: true, board: 1) }
    func join(code: String) { start(code: code.uppercased(), twoPhone: true, board: 2) }

    private func start(code: String, twoPhone: Bool, board: Int) {
        gameCode = code
        isTwoPhone = twoPhone
        myBoard = board
        engine.reset()
        scores = [0, 0]; rounds = []; roundNumber = 1
        overrides.removeAll()
        roundActive = false
        sentSetup = false
        teamNamesCustomized = [false, false]
        manualMode = false
        manualCorners = []
        searchStarted = Date()
        searchSeconds = 0
        searchMessage = "Looking for the board"
        phase = .findingBoard
        Task {
            do {
                try await camera.configure()
                camera.start()
                pipeline.startCalibration()
            } catch {
                phase = .cameraDenied
            }
        }
        sync.connect(code: code, role: "scorer", board: board)
    }

    func newGame() {
        roundOverTask?.cancel()
        pipeline.stop()
        pipeline.resetTeams()
        camera.stop()
        stopMotion()
        sync.sendReset()
        sync.disconnect()
        boardQuad = nil
        candidatePolygon = nil
        liveTracks = []
        phase = .lobby
    }

    // MARK: - In-game actions

    func endRoundNow() {
        guard phase == .ready else { return }
        finishRound()
    }

    func undo() {
        if case .roundOver = phase { roundOverTask?.cancel() }
        guard let last = engine.undo() else { return }
        scores = engine.scores
        rounds = engine.rounds
        roundNumber = engine.roundNumber
        sync.sendUndo()
        lastMessage = "Undid round \(last.number)"
        if case .roundOver = phase {
            // Bags are still on the board: let the round continue.
            phase = .ready
            roundActive = true
            lastActivity = Date()
        }
    }

    func relockBoard() {
        roundOverTask?.cancel()
        boardQuad = nil
        candidatePolygon = nil
        candidateHole = nil
        liveTracks = []
        overrides.removeAll()
        roundActive = false
        manualCorners = []
        manualMode = false
        searchStarted = Date()
        searchSeconds = 0
        searchMessage = "Looking for the board"
        camera.unlockFocus()
        phase = .findingBoard
        pipeline.startCalibration()
    }

    /// Switch to tap-the-corners setup (auto-detect keeps running underneath).
    func startManualCorners() {
        guard phase == .findingBoard || boardQuad != nil else { return }
        if boardQuad != nil { relockBoard() }
        manualMode = true
        manualCorners = []
        searchMessage = "Tap the 2 corners at the HOLE end, then the 2 at the front"
    }

    func cancelManualCorners() {
        manualMode = false
        manualCorners = []
        searchMessage = "Looking for the board"
    }

    /// A tap in manual mode; `vnorm` is Vision-normalized (origin bottom-left).
    func addManualCorner(_ vnorm: CGPoint) {
        guard manualMode, manualCorners.count < 4 else { return }
        manualCorners.append(vnorm)
        switch manualCorners.count {
        case 1: searchMessage = "Now the other corner at the hole end"
        case 2: searchMessage = "Now the 2 corners at the front edge"
        case 3: searchMessage = "Last one"
        default:
            searchMessage = "Locking…"
            pipeline.lockManually(corners: manualCorners)
        }
    }

    func undoManualCorner() {
        guard manualMode, !manualCorners.isEmpty else { return }
        manualCorners.removeLast()
        searchMessage = manualCorners.isEmpty ? "Tap the 2 corners at the HOLE end, then the 2 at the front" : "Tap the next corner"
    }

    /// Solo mode: the user tapped "Phone is in place" (or motion detected it).
    func phoneMoved() {
        guard phase == .moveToOtherBoard else { return }
        stopMotion()
        myBoard = myBoard == 1 ? 2 : 1
        relockBoard()
    }

    /// Tap a bag marker: on board -> off -> in hole -> on board.
    func cycleOverride(trackId: Int) {
        guard let t = liveTracks.first(where: { $0.id == trackId }) else { return }
        let current = overrides[trackId] ?? t.state
        let next: BagState
        switch current {
        case .resting, .moving: next = .off
        case .off: next = .inHole
        case .inHole, .lost: next = .resting
        }
        overrides[trackId] = next
        recomputeCounts()
        lastActivity = Date()
    }

    func renameTeam(_ i: Int, to name: String) {
        guard teams.indices.contains(i) else { return }
        teams[i].name = name
        teamNamesCustomized[i] = true
        sync.sendTeams(teams)
    }

    var shareURL: URL? {
        guard !AppConfig.followBaseURL.isEmpty, !gameCode.isEmpty else { return nil }
        return URL(string: "\(AppConfig.followBaseURL)/?game=\(gameCode)")
    }

    var winnerName: String? {
        if case .finished(let w) = phase { return teams[w].name }
        return nil
    }

    // MARK: - Pipeline events

    private func handle(_ event: VisionPipeline.Event) {
        switch event {
        case .searching(let polygon, let hole, let count):
            candidatePolygon = polygon
            candidateHole = hole
            detectionCount = count
            searchSeconds = Date().timeIntervalSince(searchStarted)
            if !manualMode, Date().timeIntervalSince(lastSearchMessageChange) > 1.5 {
                let msg: String
                if polygon != nil { msg = "Found a board — hold still" }
                else if hole != nil { msg = "I see the hole — looking for the board's edges" }
                else if searchSeconds > 8 { msg = "Can't find the board — tap ⋯ → Tap corners" }
                else { msg = "Looking for the board — keep the whole board in view" }
                if msg != searchMessage { searchMessage = msg; lastSearchMessageChange = Date() }
            }
        case .locked(let lock, let model):
            boardQuad = lock.quad
            boardToImage = lock.boardToImage
            holeCenter = lock.hole.center
            holeRadius = lock.hole.radius
            candidatePolygon = nil
            candidateHole = nil
            manualMode = false
            manualCorners = []
            modelLoaded = model
            camera.lockFocus()
            roundActive = false
            overrides.removeAll()
            lastActivity = Date()
            if isTwoPhone && remoteActiveBoard != myBoard {
                phase = .waitingOtherBoard
            } else {
                phase = .ready
            }
            lastMessage = lock.manual ? "Board set from corners" : String(format: "Board locked (hole at %.0f\", %.0f\")", lock.hole.center.x, lock.hole.center.y)
        case .boardMoved:
            boardQuad = nil
            searchStarted = Date()
            searchMessage = "Board moved — looking again"
            if phase == .ready && !roundActive { phase = .findingBoard }
        case .frame(let report):
            handleFrame(report)
        case .debugMap(let img):
            debugMap = img
        }
    }

    private func handleFrame(_ report: VisionPipeline.FrameReport) {
        fps = report.fps
        detectionCount = report.detectionCount
        liveTracks = report.tracks
        updateTeams(from: report.teams)
        recomputeCounts()

        guard phase == .ready else {
            if case .roundOver = phase { pushLive() }
            return
        }

        let now = Date()
        if report.anyMoving || report.tracks.count != lastTrackCount {
            lastActivity = now
        }
        lastTrackCount = report.tracks.count

        if !report.tracks.isEmpty { roundActive = true }
        guard roundActive else { quietSeconds = 0; return }

        let quiet = now.timeIntervalSince(lastActivity)
        quietSeconds = quiet
        let settled = report.tracks.filter { $0.state == .resting || $0.state == .inHole || $0.state == .off }.count
        if settled >= 8 && quiet >= AppConfig.fullRoundQuietSeconds {
            finishRound()
        } else if quiet >= AppConfig.autoEndQuietSeconds {
            finishRound()
        }
        pushLive()
    }

    private var lastTeamsSent = Date.distantPast

    private func updateTeams(from learned: [TeamColorModel.TeamColor]) {
        guard !learned.isEmpty else { return }
        var changed = false
        for (i, t) in learned.enumerated() where i < 2 {
            // The learned colour drifts a little every frame; only re-publish a real change.
            if let cur = hexToRGB(teams[i].color) {
                let d = abs(cur.0 - t.r) + abs(cur.1 - t.g) + abs(cur.2 - t.b)
                if d > 18 { teams[i].color = t.hex; changed = true }
            } else {
                teams[i].color = t.hex; changed = true
            }
            if !teamNamesCustomized[i] {
                let name = t.name
                if teams[i].name != name { teams[i].name = name; changed = true }
            }
        }
        if !sentSetup && learned.count == 2 {
            sentSetup = true
            lastTeamsSent = Date()
            sync.sendSetup(teams: teams, target: engine.target)
        } else if changed && sentSetup && Date().timeIntervalSince(lastTeamsSent) > 2 {
            lastTeamsSent = Date()
            sync.sendTeams(teams)
        }
    }

    private func effectiveState(_ t: BagTrack) -> BagState {
        overrides[t.id] ?? t.state
    }

    private func recomputeCounts() {
        var a = RoundCounts(), b = RoundCounts()
        for t in liveTracks {
            let s = effectiveState(t)
            switch s {
            case .resting: if t.team == 0 { a.on += 1 } else { b.on += 1 }
            case .inHole: if t.team == 0 { a.inHole += 1 } else { b.inHole += 1 }
            default: break
            }
        }
        if a != roundA { roundA = a }
        if b != roundB { roundB = b }
    }

    private func finishRound() {
        guard phase == .ready else { return }
        let result = engine.commit(a: roundA, b: roundB, board: myBoard)
        scores = engine.scores
        rounds = engine.rounds
        roundNumber = engine.roundNumber
        sync.sendRound(result)
        phase = .roundOver(result)
        roundActive = false
        quietSeconds = 0
        pushLive(force: true)

        roundOverTask?.cancel()
        roundOverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.afterRoundOver()
        }
    }

    private func afterRoundOver() {
        guard case .roundOver = phase else { return }
        overrides.removeAll()
        if let w = engine.winner {
            phase = .finished(winner: w)
            pipeline.pause()
            return
        }
        if isTwoPhone {
            pipeline.newRound()
            phase = .waitingOtherBoard
            remoteActiveBoard = myBoard == 1 ? 2 : 1
        } else {
            pipeline.pause()
            liveTracks = []
            phase = .moveToOtherBoard
            startMotionWatch()
        }
    }

    // MARK: - Live sync

    private func pushLive(force: Bool = false) {
        guard sync.isEnabled else { return }
        let bags = liveTracks.map { t in
            LiveBag(id: t.id, team: t.team, x: (Double(t.position.x) * 10).rounded() / 10,
                    y: (Double(t.position.y) * 10).rounded() / 10, state: effectiveState(t).rawValue)
        }
        let live = LiveState(board: myBoard, bags: bags, a: roundA, b: roundB)
        if force || live != lastLiveSent {
            lastLiveSent = live
            sync.sendLive(live)
        }
    }

    private func applyRemote(_ state: GameState) {
        remoteActiveBoard = state.activeBoard
        if isTwoPhone {
            engine.apply(rounds: state.rounds)
            scores = engine.scores
            rounds = engine.rounds
            roundNumber = engine.roundNumber
            if myBoard == 2, state.teams.count == 2, !sentSetup {
                // Adopt the host's team colours so team indices line up on both phones.
                teams = state.teams
                sentSetup = true
                let seeds = state.teams.compactMap { hexToRGB($0.color) }
                pipeline.seedTeams(seeds)
            }
            if state.activeBoard == myBoard, phase == .waitingOtherBoard {
                pipeline.newRound()
                roundActive = false
                lastActivity = Date()
                phase = .ready
            } else if state.activeBoard != myBoard, phase == .ready, !roundActive {
                phase = .waitingOtherBoard
            }
            if let w = state.winner, phase != .finished(winner: w) {
                phase = .finished(winner: w)
                pipeline.pause()
            }
        }
    }

    private func hexToRGB(_ hex: String) -> (Double, Double, Double)? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
    }

    // MARK: - Motion ("phone picked up") detection

    private var motionSamplesMoving = 0

    private func startMotionWatch() {
        guard motion.isDeviceMotionAvailable else { return }
        motionSamplesMoving = 0
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] dm, _ in
            guard let dm else { return }
            let rot = dm.rotationRate
            let acc = dm.userAcceleration
            let moving = hypot(hypot(rot.x, rot.y), rot.z) > 1.2 || hypot(hypot(acc.x, acc.y), acc.z) > 0.5
            Task { @MainActor in
                guard let self, self.phase == .moveToOtherBoard else { return }
                self.motionSamplesMoving = moving ? self.motionSamplesMoving + 1 : max(0, self.motionSamplesMoving - 1)
                if self.motionSamplesMoving >= 4 {
                    self.lastMessage = "Phone moved — finding the other board"
                    self.phoneMoved()
                }
            }
        }
    }

    private func stopMotion() {
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
    }
}
