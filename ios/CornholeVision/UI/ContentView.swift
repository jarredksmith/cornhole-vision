import SwiftUI
import AVFoundation

struct ContentView: View {
    @EnvironmentObject var game: GameViewModel

    var body: some View {
        ZStack {
            CameraPreviewView(camera: game.camera) { layer in
                game.previewLayer = layer
            }
            .ignoresSafeArea()

            OverlayView()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ScoreboardView()
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                Spacer()
                StatusBanner()
                    .padding(.bottom, 6)
                ControlsView()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            if game.showDebug, let map = game.debugMap {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(decorative: map, scale: 1, orientation: .up)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: 110, height: 220)
                            .border(.white.opacity(0.6))
                            .padding(.trailing, 12).padding(.bottom, 70)
                    }
                }
            }

            if game.phase == .cameraDenied {
                deniedView
            }
        }
        .background(Color.black)
    }

    private var deniedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text("Camera access is needed to see the board.").font(.headline)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
            Button("Back") { game.newGame() }
        }
        .padding(30)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// One line that always tells the players what the app is doing.
struct StatusBanner: View {
    @EnvironmentObject var game: GameViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.headline)
            Text(text).font(.headline)
            if countdown > 0 {
                Text("auto-ending in \(Int(countdown.rounded(.up)))s")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.black.opacity(0.6), in: Capsule())
        .foregroundStyle(.white)
        .transaction { $0.animation = nil }
    }

    private var countdown: Double {
        guard game.phase == .ready, game.quietSeconds > 0 else { return 0 }
        let remaining = AppConfig.autoEndQuietSeconds - game.quietSeconds
        return remaining <= 5 ? max(0, remaining) : 0
    }

    private var icon: String {
        switch game.phase {
        case .findingBoard: return "viewfinder"
        case .ready: return game.liveTracks.isEmpty ? "checkmark.circle.fill" : "target"
        case .roundOver: return "flag.checkered"
        case .moveToOtherBoard: return "arrow.left.arrow.right"
        case .waitingOtherBoard: return "hourglass"
        case .finished: return "trophy.fill"
        default: return "circle"
        }
    }

    private var text: String {
        switch game.phase {
        case .lobby, .cameraDenied: return ""
        case .findingBoard:
            return game.searchMessage
        case .ready:
            if game.liveTracks.isEmpty { return "Board locked — throw!" }
            return "Round \(game.roundNumber): \(game.teams[0].name) \(game.roundA.points) · \(game.teams[1].name) \(game.roundB.points)"
        case .roundOver(let r):
            if r.pointsA == 0 && r.pointsB == 0 { return "Round \(r.number): wash" }
            let team = r.pointsA > 0 ? game.teams[0].name : game.teams[1].name
            return "Round \(r.number): \(team) +\(max(r.pointsA, r.pointsB))"
        case .moveToOtherBoard:
            return "Carry the phone to the other board and prop it up"
        case .waitingOtherBoard:
            return "Other board is up — waiting for round \(game.roundNumber)"
        case .finished:
            return "\(game.winnerName ?? "") wins!"
        }
    }
}
