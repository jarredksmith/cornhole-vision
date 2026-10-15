import SwiftUI

struct ScoreboardView: View {
    @EnvironmentObject var game: GameViewModel
    @State private var editingTeam: Int? = nil
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            teamCard(0, counts: game.roundA)
            VStack(spacing: 4) {
                Text("ROUND \(game.roundNumber)")
                    .font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.7))
                Text(game.gameCode)
                    .font(.system(size: 22, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                HStack(spacing: 4) {
                    Circle().fill(syncColor).frame(width: 7, height: 7)
                    Text(syncText).font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            teamCard(1, counts: game.roundB)
            Spacer()
            if game.showDebug {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.0f fps", game.fps))
                    Text("\(game.detectionCount) blobs")
                    Text(game.modelLoaded ? "ML + colour" : "colour only")
                    Text(game.lastMessage).lineLimit(1)
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                .padding(8).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .alert("Team name", isPresented: Binding(get: { editingTeam != nil }, set: { if !$0 { editingTeam = nil } })) {
            TextField("Name", text: $draft)
            Button("Save") {
                if let i = editingTeam { game.renameTeam(i, to: draft.isEmpty ? game.teams[i].name : draft) }
                editingTeam = nil
            }
            Button("Cancel", role: .cancel) { editingTeam = nil }
        }
    }

    private func teamCard(_ i: Int, counts: RoundCounts) -> some View {
        let team = game.teams[i]
        let leading = game.scores[i] > game.scores[1 - i]
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(Color(hex: team.color)).frame(width: 14, height: 44)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.5), lineWidth: 1))
            VStack(alignment: .leading, spacing: 0) {
                Text(team.name.uppercased())
                    .font(.caption.weight(.heavy)).foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(game.scores[i])")
                        .font(.system(size: 40, weight: .black, design: .rounded))
                        .foregroundStyle(leading ? .yellow : .white)
                        .contentTransition(.numericText())
                    if counts.on + counts.inHole > 0 {
                        Text("\(counts.inHole) in · \(counts.on) on")
                            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                    }
                }
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .onLongPressGesture { draft = team.name; editingTeam = i }
        .animation(.spring(duration: 0.3), value: game.scores[i])
    }

    private var syncColor: Color {
        switch game.syncStatus {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .red
        case .off: return .gray
        }
    }

    private var syncText: String {
        switch game.syncStatus {
        case .connected: return "live"
        case .connecting: return "connecting"
        case .disconnected: return "reconnecting"
        case .off: return "offline"
        }
    }
}
