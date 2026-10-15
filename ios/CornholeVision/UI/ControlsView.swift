import SwiftUI

struct ControlsView: View {
    @EnvironmentObject var game: GameViewModel
    @State private var confirmNewGame = false

    var body: some View {
        HStack(spacing: 10) {
            switch game.phase {
            case .ready:
                pill("End round", icon: "flag.fill", prominent: !game.liveTracks.isEmpty) { game.endRoundNow() }
                pill("Undo", icon: "arrow.uturn.backward", enabled: !game.rounds.isEmpty) { game.undo() }
            case .roundOver:
                pill("Undo", icon: "arrow.uturn.backward") { game.undo() }
            case .moveToOtherBoard:
                pill("Phone is in place", icon: "checkmark", prominent: true) { game.phoneMoved() }
            case .findingBoard:
                if game.manualMode {
                    pill("Undo tap", icon: "arrow.uturn.backward", enabled: !game.manualCorners.isEmpty) { game.undoManualCorner() }
                    pill("Cancel", icon: "xmark") { game.cancelManualCorners() }
                } else {
                    pill("Tap corners", icon: "hand.tap", prominent: game.searchSeconds > 6) { game.startManualCorners() }
                }
            case .waitingOtherBoard:
                pill("Undo", icon: "arrow.uturn.backward", enabled: !game.rounds.isEmpty) { game.undo() }
            case .finished:
                pill("Undo last round", icon: "arrow.uturn.backward") { game.undo() }
            default:
                EmptyView()
            }

            Spacer()

            if let url = game.shareURL {
                ShareLink(item: url) {
                    Label("Share live link", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                }
            }

            if game.boardQuad != nil {
                pill("Re-lock board", icon: "viewfinder") { game.relockBoard() }
            }
            Menu {
                Toggle("Debug info", isOn: $game.showDebug)
                Button("Tap corners (set board by hand)") { game.startManualCorners() }
                Button("New game", role: .destructive) { confirmNewGame = true }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.title2)
                    .padding(6)
                    .background(.black.opacity(0.6), in: Circle())
                    .foregroundStyle(.white)
            }
        }
        .confirmationDialog("Start a new game?", isPresented: $confirmNewGame, titleVisibility: .visible) {
            Button("New game", role: .destructive) { game.newGame() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func pill(_ title: String, icon: String, prominent: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(prominent ? Color.accentColor : .black.opacity(0.6), in: Capsule())
                .foregroundStyle(.white)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
