import SwiftUI

struct LobbyView: View {
    @EnvironmentObject var game: GameViewModel
    @State private var joinCode = ""
    @State private var showJoin = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.06, green: 0.09, blue: 0.14), .black],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            HStack(spacing: 40) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("CORNHOLE\nVISION")
                        .font(.system(size: 44, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Prop the phone up a few feet to the side of the board, a little above board height, with the whole board in view. Then just throw.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: 360, alignment: .leading)
                }
                VStack(spacing: 14) {
                    bigButton("Start a game", subtitle: "One phone — carry it to the other board between rounds", icon: "play.fill") {
                        game.startSolo()
                    }
                    bigButton("Two phones", subtitle: "One phone per board — the second phone joins with a code", icon: "iphone.gen3.radiowaves.left.and.right") {
                        game.hostTwoPhone()
                    }
                    if showJoin {
                        HStack {
                            TextField("CODE", text: $joinCode)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .font(.system(size: 24, weight: .bold, design: .monospaced))
                                .padding(10)
                                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                .frame(width: 150)
                            Button("Join") { game.join(code: joinCode) }
                                .buttonStyle(.borderedProminent)
                                .disabled(joinCode.trimmingCharacters(in: .whitespaces).count != 4)
                        }
                    } else {
                        Button("Join as the second board") { showJoin = true }
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(width: 340)
            }
            .padding(32)
        }
    }

    private func bigButton(_ title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
        }
    }
}
