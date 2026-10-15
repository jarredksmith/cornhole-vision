import SwiftUI

@main
struct CornholeVisionApp: App {
    @StateObject private var game = GameViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(game)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var game: GameViewModel

    var body: some View {
        Group {
            if game.phase == .lobby {
                LobbyView()
            } else {
                ContentView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: game.phase == .lobby)
    }
}
